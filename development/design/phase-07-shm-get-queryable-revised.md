# Phase 7: SHM Get/Queryable — Revised Spec

> **CA revision of `development/phases/phase-07-shm-get-queryable.md`**
> Revised 2026-03-25 after cross-referencing zenoh-c v1.7.2 examples
> (`z_get_shm.c`, `z_queryable_shm.c`), zenoh-cpp wrappers, and
> established patterns from Phases 0–6. CA2 review incorporated.

## Project Context

`zenoh` is a pure Dart FFI package providing bindings for zenoh-c v1.7.2 via a
C shim layer. See `development/phases/phase-00-bootstrap.md` for full architecture.

## Prior Phases (0–6) — All Complete

- Phase 0–3: Session/config/keyexpr/bytes, put/delete, subscriber, publisher
- Phase 4: SHM provider, alloc, buffers, zero-copy publish
- Phase 5: Scout, session info (ZenohId, Hello)
- Phase 6: Get/Queryable — query/reply via clone-and-post
- 72 C shim functions, 237 integration tests

## This Phase's Goal

Extend the query/reply path to support SHM-backed payloads — the same
transparency that Phase 4 achieved for put/publish. **No new send/reply
functions** — zenoh-c uses the same `z_get()` and `z_query_reply()` for
both SHM and non-SHM payloads. The difference is only in how the
`z_owned_bytes_t` payload is constructed.

**Key architectural insight (confirmed by CA2 from zenoh-c source):**

```
// NON-SHM: z_bytes_from_static_str(&payload, value);
// SHM:     z_bytes_from_shm_mut(&payload, z_move(buf));
// SAME:    z_get(session, keyexpr, params, z_move(closure), &opts);  // identical call
```

There is no `z_get_shm()` in zenoh-c. There is no `z_query_reply_shm()`.
`z_owned_bytes_t` is the universal container that abstracts backing storage.

**Reference examples:**
- `extern/zenoh-c/examples/z_get_shm.c` — constructs SHM payload, passes to same `z_get()`
- `extern/zenoh-c/examples/z_queryable_shm.c` — constructs SHM reply, passes to same `z_query_reply()`
- `extern/zenoh-cpp/examples/zenohc/z_get_shm.cxx` — C++ equivalent
- `extern/zenoh-cpp/examples/zenohc/z_queryable_shm.cxx` — C++ equivalent

## Core Change: Widen Payload Types

Phase 6's `zd_get()` and `zd_query_reply()` accept raw `uint8_t*` payloads,
which copy data into a temporary `z_owned_bytes_t` internally. This loses
SHM backing. Phase 4's `zd_put()` and `zd_publisher_put()` already accept
`z_owned_bytes_t*` — the correct universal type.

Phase 7 aligns get/reply with put/publisher by widening the payload type:

| Function | Phase 6 (current) | Phase 7 (widened) |
|---|---|---|
| `zd_get()` | `uint8_t* payload, int32_t payload_len` | `z_owned_bytes_t* payload` (nullable, consumed) |
| `zd_query_reply()` | `uint8_t* payload, int32_t payload_len` | `z_owned_bytes_t* payload` (consumed) |
| `zd_put()` | `z_owned_bytes_t* payload` | unchanged |
| `zd_publisher_put()` | `z_owned_bytes_t* payload` | unchanged |

This follows the CLAUDE.md principle: **"Never two functions for same operation."**

## C Shim Changes

### Modified: `zd_get()` (signature change)

```c
// Send a query. Replies are posted to dart_port as NativePort messages.
// A null sentinel is posted when all replies have been received (or timeout).
// Returns 0 on success, negative on error.
//
// payload is nullable (NULL = no payload). If non-NULL, consumed via z_bytes_move().
// payload can be SHM-backed (from zd_bytes_from_shm_mut) or heap-backed
// (from zd_bytes_from_buf) — z_get treats them identically.
FFI_PLUGIN_EXPORT int zd_get(
    const z_loaned_session_t* session,
    const z_loaned_keyexpr_t* keyexpr,
    const char* parameters,       // selector parameters after '?' (NULL ok)
    int64_t dart_port,
    uint64_t timeout_ms,          // 0 = default timeout from session config
    int target,                   // z_query_target_t enum value
    int consolidation,            // z_consolidation_mode_t (-1=AUTO)
    z_owned_bytes_t* payload,     // CHANGED: owned bytes (nullable, consumed if non-NULL)
    const char* encoding);        // optional encoding (NULL = default)
```

**Implementation change:** Replace `z_bytes_copy_from_buf()` with
`z_bytes_move(payload)` when payload is non-NULL. Remove `payload_len` parameter.

### Modified: `zd_query_reply()` (signature change)

```c
// Reply to a cloned query with a data payload.
// Multiple replies per query supported (z_query_reply does NOT consume the query).
// Returns 0 on success, negative on error.
//
// payload is consumed via z_bytes_move(). Can be SHM-backed or heap-backed.
FFI_PLUGIN_EXPORT int zd_query_reply(
    z_owned_query_t* query,              // the cloned query (NOT consumed)
    const z_loaned_keyexpr_t* keyexpr,   // reply key expression
    z_owned_bytes_t* payload,            // CHANGED: owned bytes (consumed)
    const char* encoding);               // optional encoding (NULL = default)
```

**Implementation change:** Replace `z_bytes_copy_from_buf()` with
`z_bytes_move(payload)`. Remove `payload_len` parameter.

### New: `zd_bytes_from_buf()`

```c
// Create z_owned_bytes_t from a raw byte buffer (copies the data).
// This is the non-SHM path — enables ZBytes.fromBytes(Uint8List) in Dart.
// Returns 0 on success, negative on error.
FFI_PLUGIN_EXPORT int zd_bytes_from_buf(
    z_owned_bytes_t* bytes,       // output: caller-allocated via zd_bytes_sizeof()
    const uint8_t* data,          // input buffer (copied, not consumed)
    size_t len);                  // input length
```

**Why needed:** With `zd_get()` and `zd_query_reply()` now accepting
`z_owned_bytes_t*`, Dart needs a way to construct ZBytes from regular
`Uint8List` data. This wraps `z_bytes_copy_from_buf()`.

### New: `zd_bytes_is_shm()` (SHM feature-guarded)

```c
#if defined(Z_FEATURE_SHARED_MEMORY) && defined(Z_FEATURE_UNSTABLE_API)
// Check if z_owned_bytes_t is backed by shared memory.
// Returns 0 (Z_OK) if SHM-backed, negative otherwise.
// The C shim loans the owned bytes internally before calling z_bytes_as_loaned_shm().
FFI_PLUGIN_EXPORT int zd_bytes_is_shm(const z_owned_bytes_t* bytes);
#endif
```

**FFI barrier:** `z_bytes_loan()` is a `_Generic` macro (Pattern 2),
and `z_bytes_as_loaned_shm()` requires `Z_FEATURE_UNSTABLE_API`.

## zenoh-c APIs Wrapped

| C shim function | zenoh-c function(s) | Change type |
|---|---|---|
| `zd_get` | `z_get`, `z_bytes_move` | MODIFIED (payload type) |
| `zd_query_reply` | `z_query_reply`, `z_bytes_move` | MODIFIED (payload type) |
| `zd_bytes_from_buf` | `z_bytes_copy_from_buf` | NEW |
| `zd_bytes_is_shm` | `z_bytes_loan`, `z_bytes_as_loaned_shm` | NEW |

**Function count:** 72 existing + 1 new = **73 total** (2 modified in-place, `zd_bytes_from_buf` not needed — `zd_bytes_copy_from_buf` already exists)

## Dart API Changes

### New: `ZBytes.fromBytes()` factory

```dart
/// Create ZBytes from a regular byte buffer.
/// The data is copied into a zenoh-owned buffer.
/// Use [ShmMutBuffer.toBytes] for the zero-copy SHM path.
factory ZBytes.fromBytes(Uint8List data)
```

### New: `ZBytes.isShmBacked` property (SHM feature-guarded)

```dart
/// Whether this ZBytes is backed by shared memory.
/// Returns false on platforms where SHM is unavailable (e.g., Android).
bool get isShmBacked
```

### Modified: `Session.get()` — payload type change

```dart
Stream<Reply> get(
  String selector, {
  String? parameters,
  Duration? timeout,
  QueryTarget target = QueryTarget.bestMatching,
  ConsolidationMode consolidation = ConsolidationMode.auto,
  ZBytes? payload,        // CHANGED from Uint8List? — accepts SHM-backed bytes
  Encoding? encoding,
});
```

**Usage (non-SHM):**
```dart
final payload = ZBytes.fromBytes(utf8.encode('query data'));
final replies = session.get('demo/**', payload: payload);
// payload consumed by get
```

**Usage (SHM):**
```dart
final buf = shmProvider.alloc(1024)!;
buf.data.asTypedList(buf.length).setAll(0, utf8.encode('query data'));
final payload = buf.toBytes();  // zero-copy SHM bytes
final replies = session.get('demo/**', payload: payload);
// payload consumed by get
```

### Modified: `Query.replyBytes()` — payload type change

```dart
/// Reply to this query with owned bytes (can be SHM-backed).
/// [payload] is consumed by this call.
void replyBytes(String keyExpr, ZBytes payload, {Encoding? encoding});
```

**Usage (non-SHM):**
```dart
final reply = ZBytes.fromBytes(utf8.encode('response'));
query.replyBytes('demo/key', reply);
```

**Usage (SHM):**
```dart
final buf = shmProvider.allocGcDefragBlocking(1024)!;
buf.data.asTypedList(buf.length).setAll(0, utf8.encode('response'));
query.replyBytes('demo/key', buf.toBytes());  // zero-copy SHM reply
```

### Unchanged: `Query.reply()`

```dart
/// Reply with a string value. Creates ZBytes internally.
void reply(String keyExpr, String value, {Encoding? encoding});
```

The string convenience method handles ZBytes construction internally —
no API change for callers.

### No new Dart files

All changes are modifications to existing files:
- `package/lib/src/bytes.dart` — `ZBytes.fromBytes()`, `ZBytes.isShmBacked`
- `package/lib/src/session.dart` — `Session.get()` payload type
- `package/lib/src/query.dart` — `Query.replyBytes()` payload type

## CLI Examples

### `package/example/z_get_shm.dart`

Mirrors `extern/zenoh-c/examples/z_get_shm.c`:

```
Usage: fvm dart run example/z_get_shm.dart [OPTIONS]

Options:
    -s, --selector <SELECTOR>  (default: 'demo/example/**')
    -p, --payload <VALUE>      (default: 'Get from Dart (SHM)!')
    -t, --target <TARGET>      (optional: BEST_MATCHING | ALL | ALL_COMPLETE)
    -o, --timeout <MS>         (default: 10000)
    -e, --connect <ENDPOINT>   (optional: router endpoint)
    -l, --listen <ENDPOINT>    (optional: listen endpoint)
```

Behavior:
1. Open session
2. Create SHM provider
3. Allocate buffer, write query payload via `buf.data`
4. Convert to bytes via `buf.toBytes()` (zero-copy)
5. Send query with SHM payload via `session.get(payload: shmBytes)`
6. Print each reply: `>> Received ('keyexpr': 'value')`
7. Close SHM provider and session

### `package/example/z_queryable_shm.dart`

Mirrors `extern/zenoh-c/examples/z_queryable_shm.c`:

```
Usage: fvm dart run example/z_queryable_shm.dart [OPTIONS]

Options:
    -k, --key <KEYEXPR>        (default: 'demo/example/zenoh-dart-queryable')
    -p, --payload <VALUE>      (default: 'Queryable from Dart (SHM)!')
    --complete                 (flag: declare as complete queryable)
    -e, --connect <ENDPOINT>   (optional: router endpoint)
    -l, --listen <ENDPOINT>    (optional: listen endpoint)
```

Behavior:
1. Open session
2. Create SHM provider
3. Declare queryable
4. For each query:
   a. Print query keyexpr + params
   b. If query has payload, print it + whether SHM-backed (`[SHM]` or `[RAW]`)
   c. Allocate SHM buffer, write response value
   d. Reply with SHM bytes via `query.replyBytes(keyExpr, buf.toBytes())`
   e. Dispose query
5. Run until SIGINT
6. Close queryable, SHM provider, and session

## Breaking Changes (Phase 6 → Phase 7)

| Change | Impact | Migration |
|---|---|---|
| `Session.get(payload: Uint8List?)` → `ZBytes?` | Tests passing Uint8List payloads | Use `ZBytes.fromBytes(data)` |
| `Query.replyBytes(keyExpr, Uint8List)` → `ZBytes` | Tests passing Uint8List payloads | Use `ZBytes.fromBytes(data)` |
| `zd_get()` C signature change | Generated bindings change | Rebuild + regenerate |
| `zd_query_reply()` C signature change | Generated bindings change | Rebuild + regenerate |

All breaking changes are internal (pre-1.0 API). Phase 6 tests updated in-place.

## Deferred

| Feature | Reason |
|---|---|
| `ZBytes.isShmBacked` on Android | SHM excluded on Android (Phase 4 decision) — returns false |
| SHM immutable buffer (`ShmBuffer`) | Phase 4.1 deferral |
| SHM aligned alloc | Phase 4.1 deferral |
| Receive-side SHM buffer access | Phase 4.1 deferral (only detection, not buffer access) |

## Verification

1. `cmake --build --preset linux-x64 --target install` — rebuild C shim
2. `cd package && fvm dart run ffigen --config ffigen.yaml` — regenerate bindings
3. `fvm dart analyze package` — no errors
4. **All 237 existing tests pass** after signature migration

### New integration tests (two-session TCP pattern)

5. **ZBytes.fromBytes creates valid bytes**: Construct ZBytes from Uint8List, verify non-null
6. **ZBytes.fromBytes round-trips through get/reply**: Session B sends get with `ZBytes.fromBytes(data)`, queryable replies with `ZBytes.fromBytes(response)`, Session B receives correct payload
7. **SHM get payload**: Session B sends get with SHM-backed ZBytes payload, queryable receives query with correct payload bytes
8. **SHM reply payload**: Queryable replies with SHM-backed ZBytes, Session B receives correct reply payload
9. **SHM get + SHM reply end-to-end**: Both query payload and reply are SHM-backed, data round-trips correctly
10. **ZBytes.isShmBacked returns true for SHM bytes**: Create ZBytes via `ShmMutBuffer.toBytes()`, check `isShmBacked`
11. **ZBytes.isShmBacked returns false for regular bytes**: Create ZBytes via `ZBytes.fromBytes()`, check `!isShmBacked`
12. **SHM queryable receives non-SHM query**: Standard get (non-SHM) to SHM queryable — works transparently
13. **Non-SHM queryable receives SHM query**: SHM get to standard queryable — works transparently
14. **Phase 6 test regression**: All existing get/queryable tests pass with ZBytes migration

### CLI verification

15. Run `z_queryable_shm.dart` + `z_get_shm.dart` — end-to-end SHM query/reply
16. Run `z_queryable_shm.dart` + zenoh-c `z_get` — cross-language
17. Run `z_queryable.dart` (non-SHM) + `z_get_shm.dart` — SHM query to non-SHM queryable

### Expected test count

~15-20 new tests (237 existing + ~15-20 = ~252-257 total)
