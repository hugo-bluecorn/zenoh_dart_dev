# Phase 6: Get/Queryable — Revised Spec

> **CA revision of `development/phases/phase-06-get-queryable.md`**
> Revised 2026-03-25 after cross-referencing zenoh-c v1.7.2 headers,
> zenoh-cpp wrappers, integration tests, and established Dart patterns
> from Phases 0–5.

## Project Context

`zenoh` is a pure Dart FFI package providing bindings for zenoh-c v1.7.2 via a
C shim layer. See `development/phases/phase-00-bootstrap.md` for full architecture.

## Prior Phases (0–5) — All Complete

- Phase 0–3: Session/config/keyexpr/bytes, put/delete, subscriber (NativePort), publisher
- Phase 4: SHM provider, alloc, buffers, zero-copy publish
- Phase 5: Scout, session info (ZenohId, Hello)
- 62 C shim functions, 193 integration tests

## This Phase's Goal

Implement the **query/reply pattern** — the most architecturally complex phase.
A "get" sends a query, and a "queryable" declares a handler that receives
queries and sends replies.

**Reference examples:**
- `extern/zenoh-c/examples/z_get.c` — sends a query, receives replies
- `extern/zenoh-c/examples/z_queryable.c` — handles queries with callback, sends replies

**Reference tests:**
- `extern/zenoh-c/tests/z_int_queryable_test.c` — basic query/reply flow
- `extern/zenoh-c/tests/z_int_queryable_attachment_test.c` — attachment round-trip
- `extern/zenoh-cpp/tests/universal/network/queryable_get.cxx` — two-session in-process pattern

## Key Design Challenge: Query Lifecycle

Unlike subscribers (fire-and-forget callbacks), queryables must **reply** to
queries. The query is only valid during the callback in zenoh-c.

**Chosen: Clone-and-post**
1. C callback receives `z_loaned_query_t`
2. Calls `z_query_clone()` to create an owned `z_owned_query_t` on the heap
3. Posts a pointer/handle + extracted fields to Dart via NativePort
4. Dart processes the query, calls back to C: `zd_query_reply(handle, ...)`
5. Dart calls `zd_query_drop(handle)` when done (via `Query.dispose()`)

This decouples the callback thread from Dart's event loop while keeping the
query alive for as long as needed.

## C Shim Functions to Add (10 functions)

### Opaque type sizes

```c
// Size of z_owned_queryable_t for FFI allocation
FFI_PLUGIN_EXPORT size_t zd_queryable_sizeof(void);

// Size of z_owned_query_t for FFI allocation (cloned query handle)
FFI_PLUGIN_EXPORT size_t zd_query_sizeof(void);
```

### Query (get) side

```c
// Send a query. Replies are posted to dart_port as NativePort messages.
// A null sentinel is posted when all replies have been received (or timeout).
// Returns 0 on success, negative on error.
//
// z_get() is non-blocking — returns immediately. Replies arrive
// asynchronously via the callback. The closure drop function posts
// the null sentinel when all replies are received or timeout expires.
FFI_PLUGIN_EXPORT int zd_get(
    const z_loaned_session_t* session,
    const z_loaned_keyexpr_t* keyexpr,
    const char* parameters,       // selector parameters after '?' (NULL ok)
    int64_t dart_port,
    uint64_t timeout_ms,          // 0 = default timeout from session config
    int target,                   // z_query_target_t enum value (-1 sentinel not needed; 0=BEST_MATCHING is default)
    int consolidation,            // z_consolidation_mode_t (-1=AUTO, 0=NONE, 1=MONOTONIC, 2=LATEST)
    const uint8_t* payload,       // optional query payload (NULL = no payload)
    size_t payload_len,           // length of payload (ignored if payload is NULL)
    const char* encoding);        // optional encoding of payload (NULL = default)
```

**Reply NativePort format posted to dart_port:**

For ok (data) replies:
```
[1, keyexpr_string, payload_bytes(Uint8List), kind_int, attachment_bytes_or_null, encoding_string]
```

For error replies:
```
[0, error_payload_bytes(Uint8List), error_encoding_string]
```

Sentinel (completion):
```
null
```

**Implementation notes:**
- Creates `z_owned_closure_reply_t` with call + drop functions
- Call function: for each reply, checks `z_reply_is_ok()`
  - Ok: extracts sample via `z_reply_ok()` → keyexpr, payload, kind, attachment, encoding
  - Error: extracts error via `z_reply_err()` → `z_loaned_reply_err_t*` → `z_reply_err_payload(err)` + `z_reply_err_encoding(err)`
  - Posts array to dart_port
- Drop function: posts null sentinel to dart_port, frees context
- Initializes `z_get_options_t` with `z_get_options_default()`, sets target, consolidation,
  timeout_ms, and optionally payload + encoding

### Queryable side

```c
// Declare a queryable. Incoming queries are posted to dart_port as handles.
// Returns 0 on success, negative on error.
FFI_PLUGIN_EXPORT int zd_declare_queryable(
    const z_loaned_session_t* session,
    z_owned_queryable_t* queryable,      // output: caller-allocated via zd_queryable_sizeof()
    const z_loaned_keyexpr_t* keyexpr,
    int64_t dart_port,
    bool complete);                       // queryable completeness flag

// Reply to a cloned query with a data payload.
// The C shim loans the owned query internally before calling z_query_reply().
// Multiple replies per query are supported — z_query_reply() does not consume
// the query (it takes const z_loaned_query_t*). Call zd_query_drop() when done.
// Returns 0 on success, negative on error.
FFI_PLUGIN_EXPORT int zd_query_reply(
    z_owned_query_t* query,              // the cloned query (NOT consumed — caller still owns)
    const z_loaned_keyexpr_t* keyexpr,   // reply key expression
    const uint8_t* payload,              // reply payload bytes
    size_t payload_len,
    const char* encoding);               // optional encoding (NULL = default)

// Drop a cloned query. Must be called after reply (or if skipping reply).
// Idempotent (safe to call on gravestone).
FFI_PLUGIN_EXPORT void zd_query_drop(z_owned_query_t* query);

// Get the key expression string from a cloned query.
// Returns malloc'd null-terminated string. Caller must free().
FFI_PLUGIN_EXPORT const char* zd_query_keyexpr(const z_owned_query_t* query);

// Get the parameters string from a cloned query.
// Returns malloc'd null-terminated string. Caller must free().
// Returns empty string "" if no parameters.
FFI_PLUGIN_EXPORT const char* zd_query_parameters(const z_owned_query_t* query);

// Get the payload from a cloned query.
// Returns payload length via out parameter. Returns NULL if no payload.
// The returned pointer is borrowed from the owned query's internal buffer —
// it is valid only until zd_query_drop() is called. Dart must copy the
// bytes before disposing the query.
FFI_PLUGIN_EXPORT const uint8_t* zd_query_payload(
    const z_owned_query_t* query,
    size_t* out_len);                    // output: payload length

// Drop (undeclare) a queryable. Idempotent.
FFI_PLUGIN_EXPORT void zd_queryable_drop(z_owned_queryable_t* queryable);
```

**Query NativePort format posted to dart_port:**

```
[query_ptr(int64), keyexpr_string, params_string, payload_bytes_or_null]
```

Where `query_ptr` is the address of the heap-allocated `z_owned_query_t` clone,
cast to int64. Dart stores this and passes it back to `zd_query_reply()` and
`zd_query_drop()`.

**Implementation notes for `_zd_query_callback`:**
1. Receives `z_loaned_query_t*` from zenoh
2. Allocates `z_owned_query_t` on heap via `malloc(sizeof(z_owned_query_t))`
3. Calls `z_query_clone(&owned_query, query)` to create owned copy (callback receives loaned pointer directly)
4. Extracts keyexpr → `z_keyexpr_as_view_string()` → copy to malloc'd buffer
5. Extracts parameters → `z_query_parameters()` → `z_string_data()` → copy
6. Extracts payload → `z_query_payload()` → may be NULL
7. Posts `[query_ptr, keyexpr, params, payload_or_null]` to dart_port

## zenoh-c APIs Wrapped

| C shim function | zenoh-c function(s) |
|----------------|---------------------|
| `zd_queryable_sizeof` | `sizeof(z_owned_queryable_t)` |
| `zd_query_sizeof` | `sizeof(z_owned_query_t)` |
| `zd_get` | `z_get`, `z_get_options_default`, `z_closure_reply`, `z_reply_is_ok`, `z_reply_ok`, `z_reply_err`, `z_sample_keyexpr`, `z_sample_payload`, `z_sample_kind`, `z_sample_encoding`, `z_sample_attachment`, `z_reply_err_payload`, `z_reply_err_encoding` |
| `zd_declare_queryable` | `z_declare_queryable`, `z_queryable_options_default`, `z_closure_query`, `z_query_clone` |
| `zd_query_reply` | `z_query_loan`, `z_query_reply`, `z_query_reply_options_default`, `z_bytes_from_buf` |
| `zd_query_drop` | `z_query_drop` |
| `zd_query_keyexpr` | `z_query_keyexpr`, `z_keyexpr_as_view_string`, `z_string_data` |
| `zd_query_parameters` | `z_query_parameters`, `z_string_data` |
| `zd_query_payload` | `z_query_payload`, `z_bytes_to_slice` |
| `zd_queryable_drop` | `z_queryable_drop` |

**Total: 10 C shim functions** (62 existing + 10 = 72 total)

## Dart API Surface

### New file: `package/lib/src/query.dart`

```dart
/// A query received by a queryable.
///
/// Queries hold a cloned native handle that must be disposed after use.
/// Multiple replies per query are supported — call reply()/replyBytes()
/// as many times as needed, then call dispose().
/// The typical pattern is: inspect query → reply (one or more) → dispose.
class Query {
  /// The key expression of the query.
  String get keyExpr;

  /// The query parameters (selector part after '?').
  /// Empty string if no parameters.
  String get parameters;

  /// Optional payload attached to the query.
  /// Returns null if the query carries no payload.
  Uint8List? get payloadBytes;

  /// Reply to this query with a string value.
  /// [keyExpr] is the reply key expression.
  /// [value] is UTF-8 encoded into the reply payload.
  /// [encoding] optionally specifies the payload encoding.
  void reply(String keyExpr, String value, {Encoding? encoding});

  /// Reply to this query with raw bytes.
  /// [keyExpr] is the reply key expression.
  /// [payload] is the raw reply payload.
  /// [encoding] optionally specifies the payload encoding.
  void replyBytes(String keyExpr, Uint8List payload, {Encoding? encoding});

  /// Release the native query handle.
  /// Must be called after replying or if skipping reply.
  /// Idempotent — safe to call multiple times.
  void dispose();
}
```

### New file: `package/lib/src/reply.dart`

```dart
/// A reply received from a get query.
class Reply {
  /// Whether this reply contains a successful sample.
  bool get isOk;

  /// The sample from a successful reply.
  /// Throws [StateError] if [isOk] is false.
  Sample get ok;

  /// The error from a failed reply.
  /// Throws [StateError] if [isOk] is true.
  ReplyError get error;
}

/// Error information from a failed reply.
class ReplyError {
  /// Raw error payload bytes.
  final Uint8List payloadBytes;

  /// Error payload as UTF-8 string.
  final String payload;

  /// Encoding of the error payload.
  final String? encoding;
}
```

### New file: `package/lib/src/queryable.dart`

```dart
/// A queryable that handles incoming queries on a key expression.
class Queryable {
  /// Stream of incoming queries. Single-subscription.
  /// The stream stays open until [close] is called.
  Stream<Query> get stream;

  /// The key expression this queryable is declared on.
  /// Stored from declaration (no FFI call needed).
  String get keyExpr;

  /// Undeclare and close the queryable.
  /// Idempotent — safe to call multiple times.
  /// After close, the stream is closed and no more queries arrive.
  void close();
}
```

### New file: `package/lib/src/query_target.dart`

```dart
/// Target for query routing.
enum QueryTarget {
  /// Query the nearest complete queryable, or all matching if none is complete.
  bestMatching,  // Z_QUERY_TARGET_BEST_MATCHING = 0

  /// Query all matching queryables.
  all,           // Z_QUERY_TARGET_ALL = 1

  /// Query only complete queryables.
  allComplete,   // Z_QUERY_TARGET_ALL_COMPLETE = 2
}
```

### New file: `package/lib/src/consolidation_mode.dart`

```dart
/// Reply consolidation strategy for get queries.
enum ConsolidationMode {
  /// Let zenoh decide based on the selector (default).
  auto,          // Z_CONSOLIDATION_MODE_AUTO = -1

  /// No consolidation — raw replies, may contain duplicates.
  none,          // Z_CONSOLIDATION_MODE_NONE = 0

  /// Monotonic timestamps per key expression. Optimizes latency.
  monotonic,     // Z_CONSOLIDATION_MODE_MONOTONIC = 1

  /// One reply per key expression, newest wins. Optimizes bandwidth.
  latest,        // Z_CONSOLIDATION_MODE_LATEST = 2
}
```

### Modify: `package/lib/src/session.dart`

```dart
class Session {
  // ... existing methods ...

  /// Send a query and receive replies as a finite stream.
  ///
  /// The stream completes when all replies have been received or
  /// the timeout expires. z_get() is non-blocking — replies arrive
  /// asynchronously via NativePort.
  ///
  /// [selector] is the key expression to query.
  /// [parameters] is the optional selector parameters (after '?').
  /// [timeout] is the query timeout (null = session default).
  /// [target] selects which queryables to route to.
  /// [consolidation] controls reply deduplication strategy.
  /// [payload] is optional data to attach to the query.
  /// [encoding] is the optional encoding of the payload.
  Stream<Reply> get(
    String selector, {
    String? parameters,
    Duration? timeout,
    QueryTarget target = QueryTarget.bestMatching,
    ConsolidationMode consolidation = ConsolidationMode.auto,
    Uint8List? payload,
    Encoding? encoding,
  });

  /// Declare a queryable on a key expression.
  ///
  /// Returns a [Queryable] whose [stream] delivers incoming [Query] objects.
  /// Each query must be replied to and disposed.
  ///
  /// [complete] indicates whether this queryable answers all queries
  /// for its key expression (affects routing optimization).
  Queryable declareQueryable(
    String keyExpr, {
    bool complete = false,
  });
}
```

### Modify: `package/lib/zenoh.dart`

Add exports:
```dart
export 'src/consolidation_mode.dart';
export 'src/query.dart';
export 'src/query_target.dart';
export 'src/queryable.dart';
export 'src/reply.dart';
```

## CLI Examples

### `package/example/z_get.dart`

Mirrors `extern/zenoh-c/examples/z_get.c`:

```
Usage: fvm dart run example/z_get.dart [OPTIONS]

Options:
    -s, --selector <SELECTOR>  (default: 'demo/example/**')
    -p, --payload <VALUE>      (optional: payload to send with query)
    -t, --target <TARGET>      (optional: BEST_MATCHING | ALL | ALL_COMPLETE)
    -o, --timeout <MS>         (default: 10000)
    -e, --connect <ENDPOINT>   (optional: router endpoint)
    -l, --listen <ENDPOINT>    (optional: listen endpoint)
```

Behavior:
1. Open session
2. Send query with options
3. Print each reply: `>> Received ('keyexpr': 'value')`
4. Print errors: `>> Received (ERROR: 'payload')`
5. Close session when stream completes

### `package/example/z_queryable.dart`

Mirrors `extern/zenoh-c/examples/z_queryable.c`:

```
Usage: fvm dart run example/z_queryable.dart [OPTIONS]

Options:
    -k, --key <KEYEXPR>        (default: 'demo/example/zenoh-dart-queryable')
    -p, --payload <VALUE>      (default: 'Queryable from Dart!')
    --complete                 (flag: declare as complete queryable)
    -e, --connect <ENDPOINT>   (optional: router endpoint)
    -l, --listen <ENDPOINT>    (optional: listen endpoint)
```

Behavior:
1. Open session
2. Declare queryable on key expression
3. For each query: print keyexpr + params, reply with payload value
4. Dispose each query after replying
5. Run until SIGINT
6. Close queryable and session

## Deferred to Later Phases

| Feature | Reason |
|---------|--------|
| `Query.encoding` accessor | Not needed for core flow; add when query payload handling matures |
| `Query.attachment` accessor | Attachment support deferred (Phase 7+) |
| `Query.replyErr()` | Error reply from queryable; defer to Phase 6.1 |
| `Query.replyDel()` | Delete reply from queryable; defer to Phase 6.1 |
| Reply attachment | `z_query_reply_options_t.attachment`; defer to Phase 7+ |
| Reply priority/congestion | Advanced QoS options; defer to Phase 7+ |
| Get attachment | `z_get_options_t.attachment`; defer to Phase 7+ |
| Get priority/congestion/is_express | Advanced QoS; defer to Phase 7+ |
| Locality filtering | `allowed_destination`/`allowed_origin`; defer to Phase 7+ |
| Cancellation token | Unstable API |
| Source info | Unstable API |

## Verification

1. `cmake --build --preset linux-x64 --target install` — rebuild C shim
2. `cd package && fvm dart run ffigen --config ffigen.yaml` — regenerate bindings
3. `fvm dart analyze package` — no errors

### Integration tests (two-session TCP pattern)

4. **Basic get/queryable**: Session A declares queryable, Session B sends get → receives reply with correct keyexpr and payload
5. **Get with parameters**: Query with `?param=value` → queryable receives correct parameters string
6. **Get with payload**: Query with payload bytes → queryable receives correct payload
7. **Empty parameters**: Query with no `?` part → queryable receives empty string for parameters
8. **Multiple replies (multiple queryables)**: Multiple queryables on overlapping keyexprs → get receives multiple replies (target=ALL)
9. **Multiple replies (single queryable)**: Single queryable sends 3 replies to one query → get receives all 3 (zenoh-c supports multi-reply per query)
10. **Get timeout**: Get with short timeout and no queryable → stream completes empty (no replies)
11. **Queryable close**: Close queryable → subsequent gets receive no replies (timeout)
12. **Queryable stream closes on undeclare**: After queryable.close(), the stream completes (done event, no more queries)
13. **Query dispose without reply**: Queryable receives query, disposes without replying → get times out cleanly
14. **Query dispose after reply**: Verify query handle is freed after dispose (no leak, idempotent)
15. **Error reply handling**: If zenoh returns error reply → Reply.isOk == false, Reply.error populated
16. **Encoding round-trip**: Reply with encoding → get receives correct encoding in Sample
17. **Consolidation LATEST**: Two queryables reply to same keyexpr → with LATEST, only one reply received

### CLI verification

18. Run `z_queryable.dart` in terminal 1, `z_get.dart` in terminal 2 → get prints reply
19. Cross-language: zenoh-c `z_queryable` + Dart `z_get.dart` (and vice versa)

### Expected test count

~25-30 new integration tests (193 existing + ~25-30 = ~218-223 total)
