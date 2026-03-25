# Phase 5: z_scout + z_info (Discovery & Session Info) -- REVISED

> **This spec supersedes `docs/phases/phase-05-scout-info.md`.** It incorporates
> patterns established in Phases 0-3 and cross-cutting decisions from
> `docs/design/cross-cutting-patterns.md`.

## Project Context

`zenoh` is a pure Dart FFI package providing bindings for zenoh-c v1.7.2 via a
C shim layer. See `docs/phases/phase-00-bootstrap.md` for full architecture.

## Prior Phases

### Phase 0 (Bootstrap) -- completed
- C shim: session/config/keyexpr/bytes management
- Dart: `Config`, `Session`, `KeyExpr`, `ZBytes`, `ZenohException`

### Phase 1 (z_put + z_delete) -- completed
- C shim: `zd_put`, `zd_delete`
- Dart: `Session.put()`, `Session.putBytes()`, `Session.deleteResource()`

### Phase 2 (z_sub) -- completed
- C shim: `zd_declare_subscriber`, `zd_subscriber_drop`, NativePort callback bridge
- Dart: `Sample`, `SampleKind`, `Subscriber` with `Stream<Sample>`

### Phase 3 (z_pub) -- completed
- C shim: `zd_declare_publisher`, `zd_publisher_put`, matching listener
- Dart: `Publisher`, `Encoding`, `CongestionControl`, `Priority`

### Phase 4 (SHM) -- completed
- C shim: SHM provider, allocation, buffer ops, bytes conversion
- Dart: `ShmProvider`, `ShmMutBuffer`

## This Phase's Goal

Implement network discovery (`z_scout`) and session information queries
(`z_info_zid`, `z_info_routers_zid`, `z_info_peers_zid`). These are
standalone features -- no counterpart is needed to test against.

**Reference examples**:
- `extern/zenoh-c/examples/z_scout.c` -- discovers zenoh routers/peers
- `extern/zenoh-c/examples/z_info.c` -- queries session's own ID, routers, peers

### Key Design Decisions

**Synchronous collection vs NativePort**: Both scout and info callbacks are
blocking -- all callbacks fire during the C function call and complete before
it returns. Rather than using the NativePort pattern (which is designed for
long-lived asynchronous callbacks like subscriber), the C shim uses
**synchronous collection**:

- `z_info_zid`: Returns `z_id_t` by value -- C shim writes to output buffer
- `z_info_routers_zid`/`z_info_peers_zid`: C shim collects ZIDs into a
  caller-provided buffer, returns count
- `z_scout`: Uses NativePort because it blocks for `timeout_ms` (default
  1000ms) and the number of results is unbounded. The NativePort messages
  queue during the blocking call and are delivered when control returns to
  the Dart event loop.

## C Shim Functions to Add

### Session Info

```c
// Get the session's own Zenoh ID.
// Writes 16 bytes to out_id.
FFI_PLUGIN_EXPORT void zd_info_zid(
    const z_loaned_session_t* session,
    uint8_t* out_id);

// Get ZIDs of connected routers.
// Writes up to max_count ZIDs (16 bytes each) to out_ids buffer.
// Returns the number of router ZIDs found (may be 0).
// If more routers exist than max_count, only max_count are written.
//
// Internally: creates z_closure_zid_t that copies each z_id_t into the
// buffer, calls z_info_routers_zid. Closure fires synchronously.
FFI_PLUGIN_EXPORT int zd_info_routers_zid(
    const z_loaned_session_t* session,
    uint8_t* out_ids,
    int max_count);

// Get ZIDs of connected peers.
// Same semantics as zd_info_routers_zid.
FFI_PLUGIN_EXPORT int zd_info_peers_zid(
    const z_loaned_session_t* session,
    uint8_t* out_ids,
    int max_count);
```

### ZID Utilities

```c
// Convert a z_id_t to a 16-digit hex string (LSB-first order).
// Writes to an owned string that must be freed with zd_string_drop.
FFI_PLUGIN_EXPORT void zd_id_to_string(
    const uint8_t* id,
    z_owned_string_t* out);

// Convert whatami enum to human-readable string.
// Returns 0 on success, negative if whatami is invalid.
FFI_PLUGIN_EXPORT int zd_whatami_to_view_string(
    int whatami,
    z_view_string_t* out);
```

### Scouting

```c
// Scout for zenoh peers/routers on the network.
//
// config:     Consumed (moved) by this call. Use zd_config_default for defaults.
// dart_port:  Hello messages are posted to this port as arrays:
//             [zid(Uint8List[16]), whatami(Int64), locators(String[])]
//             A null sentinel is posted when scouting completes.
// timeout_ms: Scouting duration in milliseconds, 0 = default (1000ms).
// what:       Entity filter bitmask (1=router, 2=peer, 4=client,
//             3=router+peer, 7=all), -1 = default (3=router+peer).
//
// BLOCKS the calling isolate for timeout_ms. Consider running from
// Isolate.run() if blocking is unacceptable.
//
// Internally: fills z_scout_options_t, creates z_closure_hello_t that
// posts each hello to dart_port, calls z_scout (blocking), then posts
// null sentinel.
//
// Returns 0 on success, negative on failure.
FFI_PLUGIN_EXPORT int zd_scout(
    z_owned_config_t* config,
    int64_t dart_port,
    uint64_t timeout_ms,
    int what);
```

**Total: 6 new C shim functions**

## zenoh-c APIs Wrapped

| C shim function | zenoh-c function(s) |
|----------------|---------------------|
| `zd_info_zid` | `z_info_zid` |
| `zd_info_routers_zid` | `z_info_routers_zid` + `z_closure_zid` |
| `zd_info_peers_zid` | `z_info_peers_zid` + `z_closure_zid` |
| `zd_id_to_string` | `z_id_to_string` |
| `zd_whatami_to_view_string` | `z_whatami_to_view_string` |
| `zd_scout` | `z_scout` + `z_scout_options_default` + `z_closure_hello` + `z_hello_zid` + `z_hello_whatami` + `z_hello_locators` + `z_string_array_len` + `z_string_array_get` |

## Dart_CObject Formats

### Scout Hello (NativePort)

Each discovered entity is posted as a Dart_CObject array:

```
[zid(Uint8List[16]), whatami(Int64), locator_strings(String[])]
```

Where `locator_strings` is a nested array of locator strings extracted from
`z_hello_locators()` → `z_string_array_get()`.

After scouting completes (timeout), a **null** sentinel is posted to signal
completion.

### C Shim Hello Callback Implementation

```c
static void _zd_hello_callback(z_loaned_hello_t* hello, void* ctx) {
    zd_scout_context_t* context = (zd_scout_context_t*)ctx;

    // Extract ZID (16 bytes)
    z_id_t zid = z_hello_zid(hello);

    // Extract whatami
    z_whatami_t whatami = z_hello_whatami(hello);

    // Extract locators
    z_owned_string_array_t locators;
    z_hello_locators(hello, &locators);
    size_t loc_count = z_string_array_len(z_loan(locators));

    // Build Dart_CObject array: [zid_bytes, whatami_int, loc1, loc2, ...]
    // (3 + loc_count elements)
    Dart_CObject** elements = malloc((3 + loc_count) * sizeof(Dart_CObject*));
    // ... fill and post ...

    z_string_array_drop(z_move(locators));
}
```

Note: The locators are flattened into the top-level array starting at index 2,
with a locator_count at index 2 and locator strings following. Alternative:
nest a sub-array. The implementer should choose the simpler option.

## Dart API Surface

### New file: `package/lib/src/id.dart`

```dart
/// A unique 128-bit zenoh node identifier.
///
/// ZIDs are 16-byte LSB-first unsigned integers. They uniquely identify
/// zenoh sessions, routers, and peers.
class ZenohId {
  /// The raw 16-byte identifier.
  final Uint8List bytes;

  const ZenohId(this.bytes);

  /// Format as a hex string (LSB-first, matching zenoh convention).
  ///
  /// Uses the native `z_id_to_string` for consistent formatting.
  String toHexString();

  @override
  bool operator ==(Object other);

  @override
  int get hashCode;

  @override
  String toString() => toHexString();
}
```

### New file: `package/lib/src/whatami.dart`

```dart
/// Type of zenoh entity discovered during scouting.
enum WhatAmI {
  router,  // Z_WHATAMI_ROUTER = 1
  peer,    // Z_WHATAMI_PEER = 2
  client,  // Z_WHATAMI_CLIENT = 4
}
```

Note: The C values are bitmask values (1, 2, 4), not sequential. The Dart
enum maps by value, not by index. Conversion:

```dart
static WhatAmI fromInt(int value) => switch (value) {
  1 => WhatAmI.router,
  2 => WhatAmI.peer,
  4 => WhatAmI.client,
  _ => throw ArgumentError('Unknown whatami: $value'),
};
```

### New file: `package/lib/src/hello.dart`

```dart
/// Information about a discovered zenoh node.
///
/// Received during scouting via [Zenoh.scout].
class Hello {
  /// The Zenoh ID of the discovered entity.
  final ZenohId zid;

  /// The type of entity (router, peer, or client).
  final WhatAmI whatami;

  /// Network locators (endpoints) of the discovered entity.
  /// E.g., `["tcp/192.168.1.1:7447", "udp/192.168.1.1:7447"]`.
  final List<String> locators;

  const Hello({
    required this.zid,
    required this.whatami,
    required this.locators,
  });

  @override
  String toString() =>
      'Hello { zid: $zid, whatami: $whatami, locators: $locators }';
}
```

### Modify `package/lib/src/session.dart`

Add info properties/methods:

```dart
class Session {
  // ... existing methods ...

  /// This session's Zenoh ID.
  ///
  /// Throws [StateError] if session is closed.
  ZenohId get zid;

  /// Get the ZIDs of connected routers.
  ///
  /// Returns an empty list if no routers are connected.
  /// Throws [StateError] if session is closed.
  List<ZenohId> routersZid();

  /// Get the ZIDs of connected peers.
  ///
  /// Returns an empty list if no peers are connected.
  /// Throws [StateError] if session is closed.
  List<ZenohId> peersZid();
}
```

### Modify `package/lib/src/zenoh.dart`

Add scout static method:

```dart
class Zenoh {
  // ... existing methods ...

  /// Scout the network for zenoh routers and peers.
  ///
  /// Returns a list of discovered [Hello] messages. Blocks for
  /// [timeoutMs] milliseconds (default: 1000ms).
  ///
  /// Optional [what] parameter filters entity types:
  /// - `WhatAmI.router` (1) -- routers only
  /// - `WhatAmI.peer` (2) -- peers only
  /// - Combine with bitwise OR for multiple types
  /// - Default: routers + peers (3)
  ///
  /// Optional [config] for custom network configuration.
  /// If null, uses default config.
  ///
  /// Note: This blocks the calling isolate. For non-blocking usage,
  /// call from `Isolate.run()`.
  static Future<List<Hello>> scout({
    Config? config,
    int timeoutMs = 1000,
    int? what,
  });
}
```

Note: `scout` returns a `Future<List<Hello>>` because it uses a ReceivePort
internally to collect results. The C function blocks, but the Dart future
completes when the null sentinel arrives on the port. Since the blocking
call happens synchronously in the FFI call, the ReceivePort messages are
already queued by the time the FFI call returns, so the future resolves
immediately after the blocking call.

### Modify `package/lib/zenoh.dart`

Add exports for `ZenohId`, `WhatAmI`, `Hello`.

## CLI Examples to Create

### `package/bin/z_scout.dart`

Mirrors `extern/zenoh-c/examples/z_scout.c`:

```
Usage: fvm dart run -C package bin/z_scout.dart [OPTIONS]

Options:
    -e, --connect <ENDPOINT>      (optional, repeatable)
    -l, --listen <ENDPOINT>       (optional, repeatable)
```

Behavior:
1. Parse args
2. `Zenoh.initLog('error')`
3. Create config (with connect/listen endpoints if provided)
4. Call `Zenoh.scout(config: config)`
5. Print each discovered Hello: `"Hello { zid: <hex>, whatami: <type>, locators: [<locs>] }"`
6. Print count or "Did not find any zenoh process."
7. Exit

### `package/bin/z_info.dart`

Mirrors `extern/zenoh-c/examples/z_info.c`:

```
Usage: fvm dart run -C package bin/z_info.dart [OPTIONS]

Options:
    -e, --connect <ENDPOINT>      (optional, repeatable)
    -l, --listen <ENDPOINT>       (optional, repeatable)
```

Behavior:
1. Parse args
2. `Zenoh.initLog('error')`
3. Open session (with connect/listen endpoints if provided)
4. Print own ZID: `"own id: <hex>"`
5. Print router ZIDs: `"routers ids:\n<hex1>\n<hex2>\n..."`
6. Print peer ZIDs: `"peers ids:\n<hex1>\n<hex2>\n..."`
7. Close session

## Deferred Features

| Feature | zenoh-c API | Rationale |
|---------|-------------|-----------|
| Scout with custom `what` filter | `z_scout_options_t.what` | Exposed as parameter but combined bitmask values (router+peer+client) are deferred -- simple enum values only |
| Hello clone/drop | `z_hello_clone`, `z_hello_drop` | Hello is extracted in C callback, Dart receives pure data |
| Whatami bitmask combinations | `Z_WHAT_ROUTER_PEER`, etc. | Would need a different API (not simple enum) |

## Verification

1. `cmake --build build` -- C shim compiles with 6 new functions
2. `cd package && fvm dart run ffigen --config ffigen.yaml` -- regenerate bindings
3. `fvm dart analyze package` -- no errors
4. **Unit tests:**
   - ZenohId.toHexString produces valid hex string
   - ZenohId equality and hashCode work correctly
   - ZenohId.toString matches toHexString
   - WhatAmI.fromInt maps correct values (1→router, 2→peer, 4→client)
   - WhatAmI.fromInt throws on invalid value
   - Session.zid returns non-zero ID after open
   - Session.zid throws StateError on closed session
   - Session.routersZid returns list (may be empty in peer mode)
   - Session.peersZid returns list (may be empty)
   - Operations on closed session throw StateError
5. **Integration tests (two sessions):**
   - Session connected to another session sees peer ZID via peersZid()
   - Both sessions have different ZIDs
6. **Scout tests:**
   - Zenoh.scout with default config completes without error
   - Zenoh.scout returns list (may be empty without router)
   - Hello fields (zid, whatami, locators) are populated
7. **CLI integration:**
   - `z_info.dart` prints own ZID and connected router/peer ZIDs
   - `z_scout.dart` discovers running zenoh processes
   - `z_info.dart -e tcp/localhost:7447` connects to specified endpoint
