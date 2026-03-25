# Phase 3: z_pub (Declared Publisher) -- REVISED

> **This spec supersedes `development/phases/phase-03-pub.md`.** It incorporates
> patterns established in Phases 0-2 and cross-cutting decisions from
> `development/design/cross-cutting-patterns.md`.

## Project Context

`zenoh` is a pure Dart FFI package providing bindings for zenoh-c v1.7.2 via a
C shim layer. See `development/phases/phase-00-bootstrap.md` for full architecture.

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
- CLI: `package/bin/z_sub.dart`

## This Phase's Goal

Implement a declared publisher -- a long-lived entity that efficiently publishes
multiple messages to the same key expression with configurable QoS (encoding,
congestion control, priority). Also adds publisher delete (sending DELETE
messages through the publisher), the optional matching status listener, a
one-shot matching status query, and the `Encoding`, `CongestionControl`, and
`Priority` types that will be reused by Phases 6+.

**Reference**: `extern/zenoh-c/examples/z_pub.c`,
`extern/zenoh-cpp/include/zenoh/api/publisher.hxx`

## C Shim Functions to Add

### Publisher lifecycle

```c
// Returns sizeof(z_owned_publisher_t) for Dart FFI allocation.
FFI_PLUGIN_EXPORT size_t zd_publisher_sizeof(void);

// Declare a publisher on a key expression with flattened options.
//
// encoding:           MIME string (e.g., "text/plain") or NULL for default.
//                     Internally calls z_encoding_from_str() if non-NULL.
// congestion_control: 0 = block, 1 = drop, -1 = default (block).
// priority:           1-7 per z_priority_t, -1 = default (5 = DATA).
//
// Internally: fills z_publisher_options_t and calls z_declare_publisher.
FFI_PLUGIN_EXPORT int zd_declare_publisher(
    const z_loaned_session_t* session,
    z_owned_publisher_t* publisher,
    const z_loaned_keyexpr_t* keyexpr,
    const char* encoding,
    int congestion_control,
    int priority);

// Get a loaned reference to the publisher.
FFI_PLUGIN_EXPORT const z_loaned_publisher_t* zd_publisher_loan(
    const z_owned_publisher_t* publisher);

// Drop (undeclare and free) a publisher.
// Also auto-cleans any background matching listener.
FFI_PLUGIN_EXPORT void zd_publisher_drop(z_owned_publisher_t* publisher);
```

### Publisher operations

```c
// Publish data through a declared publisher.
//
// payload:    consumed (moved) by this call.
// encoding:   MIME string for per-put encoding override, or NULL for
//             publisher default. Internally calls z_encoding_from_str().
// attachment: consumed (moved) if non-NULL, or NULL for no attachment.
//
// Internally: fills z_publisher_put_options_t, calls z_publisher_put.
FFI_PLUGIN_EXPORT int zd_publisher_put(
    const z_loaned_publisher_t* publisher,
    z_owned_bytes_t* payload,
    const char* encoding,
    z_owned_bytes_t* attachment);

// Send a DELETE message through a declared publisher.
//
// Internally: calls z_publisher_delete with default options (NULL).
FFI_PLUGIN_EXPORT int zd_publisher_delete(
    const z_loaned_publisher_t* publisher);
```

### Publisher key expression

```c
// Get the key expression this publisher is bound to.
// Returns a loaned keyexpr that borrows from the publisher.
FFI_PLUGIN_EXPORT const z_loaned_keyexpr_t* zd_publisher_keyexpr(
    const z_loaned_publisher_t* publisher);
```

### Matching status

```c
// Declare a background matching listener on a publisher.
// Matching status changes are posted to dart_port as Int64
// (1 = matching, 0 = not matching).
// Listener auto-cleans when publisher is dropped.
//
// Internally: heap-allocates context with dart_port, creates
// z_owned_closure_matching_status_t, calls
// z_publisher_declare_background_matching_listener.
FFI_PLUGIN_EXPORT int zd_publisher_declare_background_matching_listener(
    const z_loaned_publisher_t* publisher,
    int64_t dart_port);

// One-shot query: does this publisher have matching subscribers?
// Returns 0 on success, fills *matching with 1 (yes) or 0 (no).
// Returns negative on failure.
FFI_PLUGIN_EXPORT int zd_publisher_get_matching_status(
    const z_loaned_publisher_t* publisher,
    int* matching);
```

### Sample encoding extraction (subscriber callback update)

```c
// No new function needed. The existing _zd_sample_callback in zenoh_dart.c
// must be updated to extract encoding from z_sample_encoding() via
// z_encoding_to_string() and include it as a 5th element in the
// Dart_CObject array:
//
// [keyexpr(String), payload(Uint8List), kind(Int64),
//  attachment(Null|Uint8List), encoding(Null|String)]
```

**Total: 8 new C shim functions + 1 internal callback update**

## zenoh-c APIs Wrapped

| C shim function | zenoh-c function(s) |
|----------------|---------------------|
| `zd_publisher_sizeof` | `sizeof(z_owned_publisher_t)` |
| `zd_declare_publisher` | `z_declare_publisher` + `z_publisher_options_default` + `z_encoding_from_str` |
| `zd_publisher_loan` | `z_publisher_loan` (macro flattened) |
| `zd_publisher_drop` | `z_publisher_drop` + `z_publisher_move` |
| `zd_publisher_put` | `z_publisher_put` + `z_publisher_put_options_default` + `z_encoding_from_str` + `z_bytes_move` |
| `zd_publisher_delete` | `z_publisher_delete` + `z_publisher_delete_options_default` |
| `zd_publisher_keyexpr` | `z_publisher_keyexpr` |
| `zd_publisher_declare_background_matching_listener` | `z_publisher_declare_background_matching_listener` + `z_closure_matching_status` |
| `zd_publisher_get_matching_status` | `z_publisher_get_matching_status` |
| (internal: sample callback update) | `z_sample_encoding` + `z_encoding_to_string` |

## Dart API Surface

### New file: `package/lib/src/encoding.dart`

See `development/design/cross-cutting-patterns.md` Section 2.2 for the full class.
Pure Dart, no FFI. `static const` values for common MIME types plus a
constructor for custom encodings.

### New file: `package/lib/src/congestion_control.dart`

See `development/design/cross-cutting-patterns.md` Section 3.1.

### New file: `package/lib/src/priority.dart`

See `development/design/cross-cutting-patterns.md` Section 3.2.

### New file: `package/lib/src/publisher.dart`

```dart
/// A declared zenoh publisher for efficient repeated publishing.
///
/// Wraps `z_owned_publisher_t`. Use [Session.declarePublisher] to create.
/// Call [close] when done to undeclare and release native resources.
class Publisher {
  /// The key expression this publisher is bound to.
  String get keyExpr;

  /// Publish a string value.
  ///
  /// Optionally override the publisher's default [encoding].
  /// Optionally attach metadata via [attachment] (consumed).
  void put(String value, {Encoding? encoding, ZBytes? attachment});

  /// Publish raw bytes.
  ///
  /// The [payload] is consumed by this call and must not be reused.
  void putBytes(ZBytes payload, {Encoding? encoding, ZBytes? attachment});

  /// Send a DELETE message on this publisher's key expression.
  void deleteResource();

  /// Stream of matching status changes (true = subscribers matching,
  /// false = no matching subscribers).
  /// Null if matching listener was not requested at declaration time.
  Stream<bool>? get matchingStatus;

  /// One-shot query: are there currently matching subscribers?
  /// Throws StateError if publisher is closed.
  bool hasMatchingSubscribers();

  /// Undeclare and close the publisher.
  ///
  /// Safe to call multiple times -- subsequent calls are no-ops.
  /// Also cleans up any background matching listener.
  void close();
}
```

### Modify `package/lib/src/sample.dart`

Add `encoding` field:

```dart
class Sample {
  final String keyExpr;
  final String payload;
  final SampleKind kind;
  final String? attachment;
  final String? encoding;    // NEW: MIME type string, null = default encoding

  const Sample({
    required this.keyExpr,
    required this.payload,
    required this.kind,
    this.attachment,
    this.encoding,           // NEW: optional, non-breaking
  });
}
```

### Modify `package/lib/src/subscriber.dart`

Update the ReceivePort listener to extract the 5th element (encoding) from
the Dart_CObject array.

### Modify `package/lib/src/session.dart`

Add method:

```dart
/// Declare a publisher on a key expression.
///
/// Optional parameters:
/// - [encoding]: Default encoding for published messages.
/// - [congestionControl]: Block or drop when queue full (default: block).
/// - [priority]: Message priority (default: data).
/// - [enableMatchingListener]: If true, [Publisher.matchingStatus] is available.
Publisher declarePublisher(
  String keyExpr, {
  Encoding? encoding,
  CongestionControl congestionControl = CongestionControl.block,
  Priority priority = Priority.data,
  bool enableMatchingListener = false,
});
```

### Modify `package/lib/zenoh.dart`

Add exports for `Publisher`, `Encoding`, `CongestionControl`, `Priority`.

## CLI Example to Create

### `package/bin/z_pub.dart`

Mirrors `extern/zenoh-c/examples/z_pub.c`:

```
Usage: fvm dart run -C package bin/z_pub.dart [OPTIONS]

Options:
    -k, --key <KEYEXPR>           (default: 'demo/example/zenoh-dart-pub')
    -p, --payload <VALUE>         (default: 'Pub from Dart!')
    -a, --attach <ATTACHMENT>     (optional)
    -e, --connect <ENDPOINT>      (optional, repeatable)
    -l, --listen <ENDPOINT>       (optional, repeatable)
    --add-matching-listener       (optional, enables matching status)
```

Behavior:
1. Parse args (matching zenoh-c z_pub.c flags)
2. `Zenoh.initLog('error')`
3. Open session (with connect/listen endpoints if provided)
4. Declare publisher (with matching listener if flag set)
5. Loop: publish `"[<idx>] <value>"` every second
6. If matching listener: print matching status changes
7. Run until SIGINT
8. Close publisher and session

## Deferred Options

The following fields exist in zenoh-c v1.7.2 but are **not** exposed in Phase 3.
See `development/design/cross-cutting-patterns.md` Section 3.4 for rationale.

| Field | Struct | Default | Future Phase |
|-------|--------|---------|--------------|
| `is_express` | `z_publisher_options_t` | false | Phase 9+ |
| `reliability` | `z_publisher_options_t` | best_effort | TBD (unstable) |
| `allowed_destination` | `z_publisher_options_t` | any | TBD (feature-gated) |
| `timestamp` | `z_publisher_put_options_t` | NULL | Phase 9+ |
| `timestamp` | `z_publisher_delete_options_t` | NULL | Phase 9+ |
| `source_info` | `z_publisher_put_options_t` | NULL | TBD (unstable) |

## Verification

1. `cmake --build build` -- C shim compiles with 8 new functions
2. `cd package && fvm dart run ffigen --config ffigen.yaml` -- regenerate bindings
3. `fvm dart analyze package` -- no errors
4. **Unit tests:**
   - Declare publisher, put once, close -- no crash
   - Publisher.put with encoding option succeeds
   - Publisher.putBytes consumes ZBytes correctly
   - Publisher.deleteResource completes without error
   - Publisher with CongestionControl and Priority options
   - Publisher.keyExpr returns correct key expression
   - Publisher.close is idempotent (double-close safe)
   - Publisher on closed session throws StateError
   - Publisher operations after close throw StateError
   - Publisher.hasMatchingSubscribers returns bool
   - Sample.encoding is non-null when encoding was set
5. **Integration tests (two sessions):**
   - Publisher.put received by subscriber as PUT sample
   - Publisher.deleteResource received by subscriber as DELETE sample
   - Publisher.put with attachment -- subscriber receives attachment
   - Publisher.put with encoding -- subscriber Sample has encoding field
   - Matching listener fires true when subscriber appears
   - Matching listener fires false when subscriber disappears
   - Multiple publishers on different keys, each received by correct subscriber
6. **CLI integration:**
   - `z_pub.dart` publishes, `z_sub.dart` receives periodic messages
   - `z_pub.dart --add-matching-listener` prints matching status when sub starts/stops
   - `z_pub.dart -a metadata` sends attachment receivable by subscriber
   - `z_pub.dart -e tcp/localhost:7447` connects to specified endpoint
