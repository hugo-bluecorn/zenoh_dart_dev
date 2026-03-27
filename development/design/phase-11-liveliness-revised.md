# Phase 11: Liveliness — Revised Spec

> **CA revision of `development/phases/phase-11-liveliness.md`**
> Revised 2026-03-26 after cross-referencing zenoh-c v1.7.2 headers, tests,
> and examples; zenoh-cpp `liveliness.hxx` and `session.hxx`; and established
> patterns from Phases 2 (Subscriber), 3 (Publisher), and 6 (Get/Queryable).

## Project Context

`zenoh` is a pure Dart FFI package providing bindings for zenoh-c v1.7.2 via a
C shim layer. See `development/phases/phase-00-bootstrap.md` for full architecture.

## Prior Phases (0-7, 8 skipped, 9-10) — All Complete

- 83 C shim functions, 310 integration tests
- Phase 2: Subscriber (NativePort callback bridge, `_zd_sample_callback`)
- Phase 3: Publisher (declared entity lifecycle, matching listener)
- Phase 6: Session.get() (reply callback via `_zd_reply_callback`)
- Phase 10: Querier (declared entity for repeated queries)

## This Phase's Goal

Implement the **liveliness subsystem** — a mechanism for tracking the presence
of zenoh entities (peers, services) on the network. Liveliness tokens announce
presence; subscribers observe token appearance/disappearance; queries discover
currently alive tokens.

**Behavioral model:**
- Declaring a token sends a **PUT sample** to intersecting liveliness subscribers
- Undeclaring a token (or losing connectivity) sends a **DELETE sample**
- Querying returns replies for all currently alive tokens on intersecting key expressions

**Reference examples:**
- `extern/zenoh-c/examples/z_liveliness.c` — declare token, wait until Ctrl-C
- `extern/zenoh-c/examples/z_sub_liveliness.c` — subscribe to liveliness changes
- `extern/zenoh-c/examples/z_get_liveliness.c` — query alive tokens

---

## Cross-Language Parity Analysis

### Source: zenoh-c (contract boundary)

The zenoh-c header (`extern/zenoh-c/include/zenoh_commons.h`) defines:

| zenoh-c function | Purpose |
|---|---|
| `z_liveliness_declare_token(session, token, keyexpr, options)` | Declare presence |
| `z_liveliness_undeclare_token(moved_token)` | Explicitly undeclare |
| `z_liveliness_token_drop(moved_token)` | Drop (also undeclares) |
| `z_liveliness_token_loan(owned_token)` | Borrow token |
| `z_liveliness_declare_subscriber(session, sub, keyexpr, callback, options)` | Subscribe to changes |
| `z_liveliness_declare_background_subscriber(session, keyexpr, callback, options)` | Background subscriber |
| `z_liveliness_get(session, keyexpr, callback, options)` | Query alive tokens |

**Key zenoh-c contract details:**
- Liveliness subscriber produces `z_loaned_sample_t` — identical to regular subscriber
- Liveliness subscriber uses `z_owned_subscriber_t` — same type as regular subscriber
- Liveliness get uses `z_owned_closure_reply_t` — same closure type as `z_get`
- `z_liveliness_undeclare_token` takes `z_moved_liveliness_token_t*` (move semantics)
- `z_liveliness_token_drop` also undeclares — both notify subscribers with DELETE

### Source: zenoh-c options structs (exposed vs deferred)

#### `z_liveliness_token_options_t`

| Field | Exposed | Deferred | Notes |
|---|---|---|---|
| `_dummy` | -- | -- | Placeholder, no real fields |

**Decision:** Pass NULL options (defaults). Nothing to expose.

#### `z_liveliness_subscriber_options_t`

| Field | Exposed | Deferred | Notes |
|---|---|---|---|
| `history` | Yes | -- | bool, receive existing tokens on subscribe |

**Decision:** Expose `history` as named parameter with default `false`.

#### `z_liveliness_get_options_t`

| Field | Exposed | Deferred | Notes |
|---|---|---|---|
| `timeout_ms` | Yes | -- | 0 = default from session config |
| `cancellation_token` | -- | Yes | Unstable API (`Z_FEATURE_UNSTABLE_API`) |

**Decision:** Expose `timeout_ms` as `Duration?` parameter. Defer cancellation token.

### Source: zenoh-cpp (structural peer)

zenoh-cpp (`extern/zenoh-cpp/include/zenoh/api/session.hxx` lines 1023-1253) places
all liveliness operations as **flat Session methods** with `liveliness_` prefix:

```cpp
Session::liveliness_declare_token(keyexpr, options)        → LivelinessToken
Session::liveliness_declare_subscriber(keyexpr, cb, drop, options) → Subscriber<void>
Session::liveliness_declare_background_subscriber(...)     → void
Session::liveliness_get(keyexpr, cb, drop, options)        → void
Session::liveliness_get(keyexpr, channel, options)         → handler
```

**Structural observations from zenoh-cpp:**
1. **No `Liveliness` accessor class** — operations are Session methods, not a nested object
2. **`LivelinessToken`** is a separate owned class (in `liveliness.hxx`) with `undeclare()`
3. **Return types reuse existing classes** — `Subscriber<void>` for liveliness subscriber, reply handler for get
4. **Options are separate types** — `LivelinessDeclarationOptions`, `LivelinessSubscriberOptions`, `LivelinessGetOptions`
5. **Background subscriber variant** exists but we defer it (not exposed for regular subscriber either)

### Source: zenoh-c tests (behavioral specification)

`extern/zenoh-c/tests/z_api_liveliness.c` defines two test functions:

**`test_liveliness_sub()`** (lines 54-99):
- Two sessions (s1 declares tokens, s2 subscribes)
- Subscriber on wildcard key receives PUT when tokens declared
- Subscriber receives DELETE when each token is individually undeclared
- Order matters: undeclare t1 → only t1 DELETE; then undeclare t2 → t2 DELETE

**`test_liveliness_get()`** (lines 101-147):
- Two sessions (s1 declares token, s2 queries)
- Query returns one reply matching the alive token's key expression
- After dropping the token, query returns zero replies (channel disconnects immediately)
- Uses FIFO channel pattern (same as `z_get`)

### Source: zenoh-cpp tests (structural template)

`extern/zenoh-cpp/tests/universal/network/liveliness.cxx`:
- `test_liveliness_get()` — two sessions, declare token, query via channel, assert reply keyexpr matches, drop token, query again → empty
- `test_liveliness_subscriber()` — two sessions, subscriber with callback tracking put/delete sets, declare two tokens → both in put_tokens, undeclare each → appears in delete_tokens

---

## Architectural Decisions

### Decision 1: Flat Session methods, not Liveliness accessor

The original phase spec proposes a `Liveliness` accessor class (`session.liveliness.declareToken()`).
This is **overridden** in favor of flat Session methods.

**Rationale:**
1. **zenoh-cpp structural peer uses flat methods** — `session.liveliness_declare_token()`, not `session.liveliness().declare_token()`. Our architectural principle says zenoh-cpp is "the best template for API design."
2. **Consistency with existing Dart API** — every other operation is flat on Session: `declarePublisher`, `declareSubscriber`, `declareQueryable`, `declareQuerier`, `get`, `put`.
3. **No cross-file privacy workaround** — a `Liveliness` class in `liveliness.dart` cannot access `Session._ptr` or `Session._closed` (Dart file-level privacy). We'd need internal getters or callback functions — unnecessary complexity.
4. **Not over-engineered** — 3 methods don't justify a wrapper class. Per our guidelines: "Don't create helpers, utilities, or abstractions for one-time operations."

**Dart naming convention (following zenoh-cpp prefix pattern):**

| zenoh-cpp method | Dart method |
|---|---|
| `session.liveliness_declare_token(ke)` | `session.declareLivelinessToken(keyExpr)` |
| `session.liveliness_declare_subscriber(ke, cb, drop, opts)` | `session.declareLivelinessSubscriber(keyExpr, {history})` |
| `session.liveliness_get(ke, cb, drop, opts)` | `session.livelinessGet(keyExpr, {timeout})` |

### Decision 2: Reuse existing Subscriber and Reply types

The zenoh-c contract confirms that liveliness subscriber uses `z_owned_subscriber_t` and produces
`z_loaned_sample_t` — identical to regular subscriber. The zenoh-cpp structural peer confirms this
by returning `Subscriber<void>`.

- `declareLivelinessSubscriber()` returns our existing `Subscriber` class
- `livelinessGet()` returns `Stream<Reply>` (same as `Session.get()`)
- No new wrapper types needed for these

### Decision 3: Reuse existing C shim callbacks

The C shim already has:
- `_zd_sample_callback` / `_zd_sample_drop` — used by `zd_declare_subscriber` (Phase 2)
- `_zd_reply_callback` / `_zd_get_drop` — used by `zd_get` (Phase 6) and `zd_querier_get` (Phase 10)

The liveliness C shim functions will reuse these directly:
- `zd_liveliness_declare_subscriber` → reuses `_zd_sample_callback`, `_zd_sample_drop`
- `zd_liveliness_get` → reuses `_zd_reply_callback`, `_zd_get_drop`

Additionally:
- `zd_subscriber_sizeof` is reused (same `z_owned_subscriber_t`)
- `zd_subscriber_drop` is reused (same drop semantics)

### Decision 4: LivelinessToken is a new minimal class

Following zenoh-cpp's `LivelinessToken` (in `liveliness.hxx`): a simple owned class with
`close()` (Dart equivalent of C++'s `undeclare()`). Lives in `package/lib/src/liveliness.dart`.

Includes a `keyExpr` getter for API consistency — every other declared entity in the Dart API
(`Publisher`, `Subscriber`, `PullSubscriber`, `Queryable`, `Querier`) exposes `keyExpr`.
Although zenoh-c does not provide `z_liveliness_token_keyexpr()`, no C function is needed:
store the key expression string passed at declaration time on the Dart side, following the
same pattern as `Queryable`.

---

## C Shim Functions to Add (5 functions, 83 → 88 total)

### Sizeof

```c
// Size of z_owned_liveliness_token_t for FFI allocation
FFI_PLUGIN_EXPORT size_t zd_liveliness_token_sizeof(void);
```

### Token declaration

```c
// Declare a liveliness token (announces presence on the network).
// Token stays alive until dropped. Subscribers receive PUT sample.
// Returns 0 on success, non-zero on error.
FFI_PLUGIN_EXPORT int zd_liveliness_declare_token(
    const z_loaned_session_t* session,
    z_owned_liveliness_token_t* token,   // output: caller-allocated via sizeof
    const z_loaned_keyexpr_t* keyexpr);
```

Wraps: `z_liveliness_declare_token(session, token, keyexpr, NULL)` (NULL options = defaults, dummy struct).

### Token drop

```c
// Undeclare and drop a liveliness token. Subscribers receive DELETE sample.
FFI_PLUGIN_EXPORT void zd_liveliness_token_drop(z_owned_liveliness_token_t* token);
```

Wraps: `z_liveliness_token_drop(z_liveliness_token_move(token))`.

Note: zenoh-c has both `z_liveliness_undeclare_token` and `z_liveliness_token_drop`.
Both notify subscribers with DELETE. We use `drop` which combines undeclare + free,
matching our existing pattern (e.g., `zd_subscriber_drop`, `zd_publisher_drop`).

### Liveliness subscriber

```c
// Subscribe to liveliness changes. Samples posted to dart_port via NativePort.
// PUT kind (0) = token alive, DELETE kind (1) = token dropped.
// Reuses _zd_sample_callback and _zd_sample_drop from zd_declare_subscriber.
// Returns 0 on success, non-zero on error.
FFI_PLUGIN_EXPORT int zd_liveliness_declare_subscriber(
    const z_loaned_session_t* session,
    z_owned_subscriber_t* subscriber,    // output: caller-allocated via zd_subscriber_sizeof()
    const z_loaned_keyexpr_t* keyexpr,
    int64_t dart_port,
    bool history);                        // if true, receive existing alive tokens as PUT
```

Wraps: `z_liveliness_declare_subscriber(session, subscriber, keyexpr, closure, &options)` with
`z_liveliness_subscriber_options_t.history` set from the `history` parameter.

Reuses `zd_subscriber_sizeof()` for allocation and `zd_subscriber_drop()` for cleanup.

### Liveliness get

```c
// Query currently alive liveliness tokens. Replies posted to dart_port.
// Null sentinel posted when query completes.
// Reuses _zd_reply_callback and _zd_get_drop from zd_get.
// Returns 0 on success, non-zero on error.
//
// Reply format (same as zd_get):
// Ok reply:    [1, keyexpr_string, payload_bytes, kind_int, attachment_or_null, encoding_string]
// Sentinel:    null
FFI_PLUGIN_EXPORT int zd_liveliness_get(
    const z_loaned_session_t* session,
    const z_loaned_keyexpr_t* keyexpr,
    int64_t dart_port,
    uint64_t timeout_ms);                // 0 = default from session config
```

Wraps: `z_liveliness_get(session, keyexpr, closure, &options)` with
`z_liveliness_get_options_t.timeout_ms` set from the parameter.

Note: liveliness get does NOT support parameters, payload, encoding, target, or
consolidation — it is simpler than `Session.get()`. Only keyexpr and timeout.

---

## zenoh-c APIs Wrapped

| C shim function | zenoh-c function(s) |
|---|---|
| `zd_liveliness_token_sizeof` | `sizeof(z_owned_liveliness_token_t)` |
| `zd_liveliness_declare_token` | `z_liveliness_declare_token` |
| `zd_liveliness_token_drop` | `z_liveliness_token_drop` (via `z_liveliness_token_move`) |
| `zd_liveliness_declare_subscriber` | `z_liveliness_declare_subscriber`, `z_liveliness_subscriber_options_default`, `z_closure_sample` |
| `zd_liveliness_get` | `z_liveliness_get`, `z_liveliness_get_options_default`, `z_closure_reply` |

**Reused C shim functions (no changes needed):**

| Existing function | Reused for |
|---|---|
| `zd_subscriber_sizeof` | Allocating liveliness subscriber (same `z_owned_subscriber_t`) |
| `zd_subscriber_drop` | Dropping liveliness subscriber (same type) |
| `_zd_sample_callback` (static) | Sample callback for liveliness subscriber |
| `_zd_sample_drop` (static) | Context cleanup for liveliness subscriber |
| `_zd_reply_callback` (static) | Reply callback for liveliness get |
| `_zd_get_drop` (static) | Context cleanup for liveliness get |

---

## Dart API Surface

### New file: `package/lib/src/liveliness.dart`

```dart
/// A liveliness token that announces presence on the network.
///
/// Wraps `z_owned_liveliness_token_t`. When declared, intersecting liveliness
/// subscribers receive a PUT sample. When closed (or if connectivity is lost),
/// they receive a DELETE sample.
///
/// Call [close] when done to undeclare the token and release native resources.
class LivelinessToken {
  /// The key expression this token was declared on.
  String get keyExpr;

  void close();
}
```

### Modify: `package/lib/src/session.dart`

```dart
class Session {
  /// Declares a liveliness token on the given [keyExpr].
  ///
  /// The token announces presence on the network. Intersecting liveliness
  /// subscribers receive a PUT sample. Call [LivelinessToken.close] to
  /// undeclare (triggers DELETE sample to subscribers).
  ///
  /// Throws [ZenohException] if the key expression is invalid.
  /// Throws [StateError] if the session has been closed.
  LivelinessToken declareLivelinessToken(String keyExpr);

  /// Declares a liveliness subscriber on the given [keyExpr].
  ///
  /// Returns a [Subscriber] whose stream delivers [Sample]s:
  /// - [SampleKind.put] when a matching liveliness token appears
  /// - [SampleKind.delete] when a matching liveliness token disappears
  ///
  /// If [history] is true, the subscriber receives PUT samples for
  /// all currently alive tokens at subscription time.
  ///
  /// Throws [ZenohException] if the key expression is invalid.
  /// Throws [StateError] if the session has been closed.
  Subscriber declareLivelinessSubscriber(String keyExpr, {bool history = false});

  /// Queries currently alive liveliness tokens matching the given [keyExpr].
  ///
  /// Returns a [Stream<Reply>] that completes when all replies are received
  /// or the timeout expires. Each reply's [Sample] contains the key expression
  /// of an alive token.
  ///
  /// Throws [StateError] if the session has been closed.
  Stream<Reply> livelinessGet(String keyExpr, {Duration? timeout});
}
```

### Modify: `package/lib/zenoh.dart`

Add export: `export 'src/liveliness.dart';`

---

## CLI Examples to Create

All in `package/example/` (corrected from original spec's `package/bin/`).

### `package/example/z_liveliness.dart`

Mirrors `extern/zenoh-c/examples/z_liveliness.c`.

```
Usage: fvm dart run example/z_liveliness.dart [OPTIONS]

Options:
    -k, --key <KEYEXPR>    (default: 'group1/zenoh-dart')
    -e, --connect <ENDPOINT>
    -l, --listen <ENDPOINT>
```

Behavior: declare liveliness token, print "Liveliness token declared", run until Ctrl-C, close.

### `package/example/z_sub_liveliness.dart`

Mirrors `extern/zenoh-c/examples/z_sub_liveliness.c`.

```
Usage: fvm dart run example/z_sub_liveliness.dart [OPTIONS]

Options:
    -k, --key <KEYEXPR>    (default: 'group1/**')
    --history              (flag: receive currently alive tokens)
    -e, --connect <ENDPOINT>
    -l, --listen <ENDPOINT>
```

Behavior: declare liveliness subscriber, print "New alive token" / "Dropped token" events, run until Ctrl-C.

### `package/example/z_get_liveliness.dart`

Mirrors `extern/zenoh-c/examples/z_get_liveliness.c`.

```
Usage: fvm dart run example/z_get_liveliness.dart [OPTIONS]

Options:
    -k, --key <KEYEXPR>    (default: 'group1/**')
    -o, --timeout <MS>     (default: 10000)
    -e, --connect <ENDPOINT>
    -l, --listen <ENDPOINT>
```

Behavior: query alive tokens, print "Alive token" for each reply, exit when stream completes.

---

## Verification Criteria

1. `fvm dart analyze package` — no errors
2. **Token lifecycle test**: declare token → close → no crash, idempotent close
3. **Subscriber PUT test**: two sessions; declare subscriber on session B; declare token on session A → subscriber receives PUT sample with matching keyexpr
4. **Subscriber DELETE test**: undeclare token → subscriber receives DELETE sample
5. **Subscriber history test**: declare token first; then declare subscriber with `history: true` → subscriber receives PUT for existing token
6. **Get query test**: declare token; query from another session → reply with token's keyexpr
7. **Get empty test**: no tokens declared; query → stream completes with zero replies
8. **Get after drop test**: declare token; drop token; query → zero replies
9. **Multiple tokens test**: declare 2 tokens → subscriber sees 2 PUTs; drop first → subscriber sees 1 DELETE (second still alive). Mirrors `test_liveliness_sub()` from `z_api_liveliness.c`.
10. **History false negative test**: declare token first; then subscribe with `history: false` → no initial PUT received (only subsequent changes)
11. **Closed session tests**: all three methods throw StateError on closed session
12. **Invalid keyexpr tests**: declareLivelinessToken and declareLivelinessSubscriber throw ZenohException on empty key expression

---

## Corrections From Original Spec

| Issue | Original | Revised |
|---|---|---|
| Missing sizeof | 4 C shim functions | 5 (added `zd_liveliness_token_sizeof`) |
| CLI example location | `package/bin/` | `package/example/` (project convention) |
| API shape | `Liveliness` accessor class | Flat Session methods (matches zenoh-cpp structural peer) |
| Missing connect/listen flags | Only `-k` and `--history`/`-o` | Added `-e/--connect`, `-l/--listen` (zenoh-c standard) |
| Reuse not documented | Implicit | Explicit: reuses 6 existing C shim callbacks/functions |
