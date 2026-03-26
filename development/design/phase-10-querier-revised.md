# Phase 10: Declared Querier — Revised Spec

> **CA revision of `development/phases/phase-10-querier.md`**
> Revised 2026-03-26 after cross-referencing zenoh-c v1.7.2 `z_querier.c`,
> zenoh-cpp `querier.hxx`, and established Publisher pattern from Phase 3.

## Project Context

`zenoh` is a pure Dart FFI package providing bindings for zenoh-c v1.7.2 via a
C shim layer. See `development/phases/phase-00-bootstrap.md` for full architecture.

## Prior Phases (0–7, 8 skipped, 9) — All Complete

- 77 C shim functions, 282 integration tests
- Phase 6: Session.get() (one-shot query) — query/reply via clone-and-post
- Phase 3: Publisher (declared entity for repeated puts) — the pattern template

## This Phase's Goal

Implement a **declared querier** — a long-lived entity for sending repeated
queries to the same key expression. Querier is to `Session.get()` as Publisher
is to `Session.put()`.

**Pattern mapping:**

| Publisher (Phase 3) | Querier (Phase 10) |
|---|---|
| `Session.declarePublisher(keyExpr)` | `Session.declareQuerier(keyExpr)` |
| `publisher.put(value)` | `querier.get()` → `Stream<Reply>` |
| `publisher.matchingStatus` | `querier.matchingStatus` |
| `publisher.close()` | `querier.close()` |

**Reference examples:**
- `extern/zenoh-c/examples/z_querier.c` — declares querier, queries in a loop
- `extern/zenoh-cpp/examples/universal/z_querier.cxx` — C++ equivalent

## C Shim Functions to Add (6 functions)

### Sizeof

```c
// Size of z_owned_querier_t for FFI allocation
FFI_PLUGIN_EXPORT size_t zd_querier_sizeof(void);
```

### Declaration

```c
// Declare a querier on a key expression with options.
// Returns 0 on success, negative on error.
//
// Declaration-time options: target, consolidation, timeout.
// Per-query options (payload, encoding) are passed to zd_querier_get().
FFI_PLUGIN_EXPORT int zd_declare_querier(
    const z_loaned_session_t* session,
    z_owned_querier_t* querier,          // output: caller-allocated via zd_querier_sizeof()
    const z_loaned_keyexpr_t* keyexpr,
    int target,                           // z_query_target_t (0=BEST_MATCHING default)
    int consolidation,                    // z_consolidation_mode_t (-1=AUTO default)
    uint64_t timeout_ms);                 // 0 = default from session config
```

**Deferred declaration options:**
- `congestion_control` — advanced QoS, defer
- `is_express` — advanced QoS, defer
- `priority` — advanced QoS, defer
- `allowed_destination` — locality, defer
- `accept_replies` — unstable API

### Query operation

```c
// Issue a query through the querier. Replies posted to dart_port.
// Null sentinel posted when all replies received (or timeout).
// Returns 0 on success, negative on error.
//
// Uses the same NativePort reply callback as zd_get():
// Ok reply:    [1, keyexpr_string, payload_bytes, kind_int, attachment_or_null, encoding_string]
// Error reply: [0, error_payload_bytes, error_encoding_string]
// Sentinel:    null
FFI_PLUGIN_EXPORT int zd_querier_get(
    const z_loaned_querier_t* querier,
    const char* parameters,               // selector parameters (NULL ok)
    int64_t dart_port,
    z_owned_bytes_t* payload,             // optional query payload (nullable, consumed)
    const char* encoding);                // optional encoding (NULL = default)
```

**Implementation:** Creates `z_owned_closure_reply_t` with same reply callback
as `zd_get()`. Sets `z_querier_get_options_t` payload + encoding. Calls
`z_querier_get()`.

**Deferred per-query options:**
- `attachment` — defer
- `source_info` — unstable API
- `cancellation_token` — unstable API

### Matching listener

```c
// Declare a background matching listener on the querier.
// Posts int64 (1=matching, 0=not matching) to dart_port when status changes.
// Lives until querier is dropped.
// Returns 0 on success, negative on error.
//
// Same NativePort callback pattern as Publisher's matching listener (Phase 3).
FFI_PLUGIN_EXPORT int zd_querier_declare_background_matching_listener(
    const z_loaned_querier_t* querier,
    int64_t dart_port);

// Get current matching status synchronously.
// Returns 0 on success, negative on error.
// *matching is set to 1 if matching queryables exist, 0 otherwise.
FFI_PLUGIN_EXPORT int zd_querier_get_matching_status(
    const z_loaned_querier_t* querier,
    int* matching);
```

### Cleanup

```c
// Drop (undeclare) the querier. Idempotent.
FFI_PLUGIN_EXPORT void zd_querier_drop(z_owned_querier_t* querier);
```

## zenoh-c APIs Wrapped

| C shim function | zenoh-c function(s) | FFI barrier |
|---|---|---|
| `zd_querier_sizeof` | `sizeof(z_owned_querier_t)` | Pattern 4: sizeof |
| `zd_declare_querier` | `z_declare_querier`, `z_querier_options_default` | Pattern 3: options init |
| `zd_querier_get` | `z_querier_get`, `z_querier_get_options_default`, `z_closure_reply` | Pattern 5: NativePort closure |
| `zd_querier_declare_background_matching_listener` | `z_querier_declare_background_matching_listener`, `z_closure_matching_status` | Pattern 5: NativePort closure |
| `zd_querier_get_matching_status` | `z_querier_loan`, `z_querier_get_matching_status` | Pattern 2: loan `_Generic` macro |
| `zd_querier_drop` | `z_querier_drop` | Pattern 1: move `static inline` |

**Function count:** 77 existing + 6 new = **83 total**

## Dart API Surface

### New file: `package/lib/src/querier.dart`

```dart
/// A declared querier for repeated queries to the same key expression.
///
/// Querier is to [Session.get] as [Publisher] is to [Session.put].
/// Declaration-time options (target, consolidation, timeout) are fixed;
/// per-query options (payload, encoding) vary per [get] call.
class Querier {
  /// The key expression this querier is declared on.
  String get keyExpr;

  /// Issue a query. Returns a finite stream of replies that completes
  /// when all replies are received or the declaration-time timeout expires.
  ///
  /// [parameters] is the optional selector parameters (after '?').
  /// [payload] is optional data to attach to the query (can be SHM-backed).
  /// [encoding] is the optional encoding of the payload.
  Stream<Reply> get({
    String? parameters,
    ZBytes? payload,
    Encoding? encoding,
  });

  /// Whether matching queryables currently exist.
  /// Throws [StateError] if the querier has been closed.
  bool hasMatchingQueryables();

  /// Stream of matching status changes (queryables appearing/disappearing).
  /// Non-null only if [enableMatchingListener] was true at declaration.
  Stream<bool>? get matchingStatus;

  /// Close the querier. Idempotent.
  void close();
}
```

### Modify: `package/lib/src/session.dart`

```dart
class Session {
  // ... existing methods ...

  /// Declare a querier on a key expression.
  ///
  /// [target] selects which queryables to route to.
  /// [consolidation] controls reply deduplication strategy.
  /// [timeout] is the query timeout (null = session default).
  /// [enableMatchingListener] enables the [Querier.matchingStatus] stream.
  Querier declareQuerier(
    String keyExpr, {
    QueryTarget target = QueryTarget.bestMatching,
    ConsolidationMode consolidation = ConsolidationMode.auto,
    Duration? timeout,
    bool enableMatchingListener = false,
  });
}
```

### Modify: `package/lib/zenoh.dart`

Add export:
```dart
export 'src/querier.dart';
```

## CLI Example

### `package/example/z_querier.dart`

Mirrors `extern/zenoh-c/examples/z_querier.c`:

```
Usage: fvm dart run example/z_querier.dart [OPTIONS]

Options:
    -s, --selector <SELECTOR>      (default: 'demo/example/**')
    -p, --payload <VALUE>          (optional: payload to send with each query)
    -t, --target <TARGET>          (optional: BEST_MATCHING | ALL | ALL_COMPLETE)
    -o, --timeout <MS>             (default: 10000)
    --add-matching-listener        (flag: enable matching status listener)
    -e, --connect <ENDPOINT>       (optional: router endpoint)
    -l, --listen <ENDPOINT>        (optional: listen endpoint)
```

Behavior:
1. Open session
2. Declare querier (with matching listener if flag set)
3. Loop every 1 second: issue query, print each reply
4. Print: `>> Received ('keyexpr': 'value')`
5. If matching listener: print `Matching status: has matching queryables` / `NO MORE matching queryables`
6. Run until SIGINT
7. Close querier and session

## Deferred

| Feature | Reason |
|---|---|
| `congestion_control` on declaration | Advanced QoS, defer |
| `priority` on declaration | Advanced QoS, defer |
| `is_express` on declaration | Advanced QoS, defer |
| `allowed_destination` | Locality filtering, defer |
| `accept_replies` | Unstable API |
| `attachment` on per-query | Defer with other attachment support |
| `cancellation_token` | Unstable API |
| `source_info` | Unstable API |

## Verification

1. `cmake --build --preset linux-x64 --target install` — rebuild C shim
2. `cd package && fvm dart run ffigen --config ffigen.yaml` — regenerate bindings
3. `fvm dart analyze package` — no errors

### Integration tests (two-session TCP pattern)

4. **Declare querier returns Querier instance**
5. **Querier.keyExpr returns declared key expression**
6. **Basic querier get receives reply from queryable**: Session A declares queryable, Session B declares querier, querier.get() receives reply
7. **Querier get with parameters**: parameters passed through to queryable
8. **Querier get with ZBytes payload**: SHM-capable payload delivered to queryable
9. **Querier get with encoding**: encoding round-trips
10. **Querier get timeout with no queryable**: stream completes empty
11. **Querier repeated gets**: multiple get() calls in sequence, each returns correct replies
12. **Querier.close is idempotent**
13. **Querier get after close throws StateError**
14. **declareQuerier on closed session throws StateError**
15. **Matching listener fires when queryable appears**: declare querier with listener → declare queryable → matchingStatus emits true
16. **Matching listener fires when queryable disappears**: close queryable → matchingStatus emits false
17. **hasMatchingQueryables returns correct value**

### CLI verification

18. Run `z_queryable.dart` + `z_querier.dart` — querier prints periodic replies
19. Cross-language: zenoh-c `z_queryable` + Dart `z_querier.dart`

### Expected test count

~18-22 new tests (282 existing + ~18-22 = ~300-304 total)
