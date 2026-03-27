# Phase 12: Ping/Pong Latency Benchmark — Revised Spec

> **CA revision of `development/phases/phase-12-ping-pong.md`**
> Revised 2026-03-26 after cross-referencing zenoh-c v1.7.2 `z_ping.c`,
> `z_pong.c`, zenoh-cpp `session.hxx`/`bytes.hxx`, and established patterns
> from Phases 2 (Subscriber), 3 (Publisher), and 11 (Liveliness).

## Project Context

`zenoh` is a pure Dart FFI package providing bindings for zenoh-c v1.7.2 via a
C shim layer. See `development/phases/phase-00-bootstrap.md` for full architecture.

## Prior Phases (0-7, 8 skipped, 9-11) — All Complete

- 88 C shim functions, 340 integration tests
- Phase 2: Subscriber (NativePort callback bridge, `_zd_sample_callback`)
- Phase 3: Publisher (declared entity, `zd_declare_publisher`)
- Phase 11: Liveliness (callback reuse, shared helpers)

## This Phase's Goal

Implement the **ping/pong latency benchmark** — two CLI tools that measure
round-trip time between a publisher and a background subscriber. This phase is
both a benchmark tool and a vehicle for three new API features:

1. **Background subscriber** — fire-and-forget, lives until session closes
2. **Publisher express mode** — disables batching for lower latency
3. **ZBytes read operations** — `clone()` and `toBytes()` complete the ZBytes API

**Benchmark pattern:**
```
z_ping                              z_pong
  |                                   |
  |-- pub "test/ping" payload ------->|
  |                                   |-- background sub receives
  |                                   |-- pub "test/pong" same payload
  |<-- sub "test/pong" payload -------|
  |                                   |
  |  measure RTT                      |
```

**Reference examples:**
- `extern/zenoh-c/examples/z_ping.c` — publishes, measures RTT from pong reply
- `extern/zenoh-c/examples/z_pong.c` — background subscriber echoes payload

---

## Cross-Language Parity Analysis

### Source: zenoh-c (contract boundary)

#### Background Subscriber

```c
z_result_t z_declare_background_subscriber(
    const struct z_loaned_session_t *session,
    const struct z_loaned_keyexpr_t *key_expr,
    struct z_moved_closure_sample_t *callback,
    struct z_subscriber_options_t *options);
```

**Key contract details:**
- No handle returned — fire-and-forget, no `z_owned_subscriber_t` output
- Callback + drop pair consumed via move (same closure pattern as regular subscriber)
- Uses standard `z_subscriber_options_t` (no liveliness-specific options)
- Lives until session closes — subscriber is undeclared automatically
- Drop callback fires on session close (frees context)

#### Publisher Express Mode

`z_publisher_options_t` struct (`zenoh_commons.h`):

| Field | Type | Exposed | Deferred | Notes |
|---|---|---|---|---|
| `encoding` | `z_moved_encoding_t*` | Phase 3 | -- | Already exposed |
| `congestion_control` | `z_congestion_control_t` | Phase 3 | -- | Already exposed |
| `priority` | `z_priority_t` | Phase 3 | -- | Already exposed |
| `is_express` | `bool` | **Phase 12** | -- | Disables batching for latency |
| `reliability` | `z_reliability_t` | -- | Yes | Unstable API |
| `allowed_destination` | `z_locality_t` | -- | Yes | Locality filtering |

In `z_ping.c` and `z_pong.c`: `opts.is_express = !args.no_express;` — express defaults ON
for the benchmark. The `--no-express` flag disables it.

#### Bytes Clone

```c
void z_bytes_clone(struct z_owned_bytes_t *dst,
                   const struct z_loaned_bytes_t *this_);
```

- Shallow reference-counted clone, NOT deep copy
- Both original and clone remain valid and independent
- Used in `z_pong.c` callback to clone loaned sample payload before publishing

#### Bytes Length and Slice Access

```c
size_t z_bytes_len(const struct z_loaned_bytes_t *this_);
z_result_t z_bytes_to_slice(const struct z_loaned_bytes_t *this_,
                            struct z_owned_slice_t *dst);
const uint8_t *z_slice_data(const struct z_loaned_slice_t *this_);
size_t z_slice_len(const struct z_loaned_slice_t *this_);
void z_slice_drop(struct z_moved_slice_t *this_);
```

### Source: zenoh-cpp (structural peer)

#### Background Subscriber (`session.hxx:581-599`)

```cpp
template <class C, class D>
void declare_background_subscriber(
    const KeyExpr& key_expr, C&& on_sample, D&& on_drop,
    SubscriberOptions&& options = SubscriberOptions::create_default(),
    ZResult* err = nullptr) const;
```

- Returns **void** — no handle, consistent with fire-and-forget semantics
- Uses same `SubscriberOptions` as regular subscriber
- Callback signature: `void on_sample(Sample&)`

#### Publisher Express Mode (`session.hxx:741-785`)

```cpp
struct PublisherOptions {
    CongestionControl congestion_control = ...;
    Priority priority = Z_PRIORITY_DEFAULT;
    bool is_express = false;  // default OFF in general API
    // ...
};
```

#### Bytes Clone (`bytes.hxx:120-124`)

```cpp
Bytes clone() const {
    Bytes b;
    ::z_bytes_clone(&b._0, interop::as_loaned_c_ptr(*this));
    return b;
}
```

---

## Architectural Decisions

### Decision 1: Background subscriber returns Stream\<Sample\>

Following zenoh-cpp (returns void, fire-and-forget), the Dart API cannot return
a `Subscriber` object (which has a native handle for undeclare). Instead:

`Session.declareBackgroundSubscriber(keyExpr)` returns `Stream<Sample>`.

The stream is backed by a ReceivePort + StreamController using the existing
`Subscriber.createSampleChannel` shared helper from Phase 11. The background
subscriber lives until the session closes — no explicit close needed or possible.

This matches the C semantics and the benchmark use case (z_pong runs until Ctrl-C).

### Decision 2: Modify existing `zd_declare_publisher` signature

Rather than adding a separate C shim function, add `is_express` as a new
parameter to the existing `zd_declare_publisher`. Uses sentinel `-1` for default
(consistent with `congestion_control` and `priority` sentinels).

This is a breaking C API change, but the only caller is Dart via FFI bindings
which are regenerated each phase.

### Decision 3: Collapse slice API into two convenience functions

The original spec exposes 5 slice functions (`zd_bytes_to_slice`, `zd_slice_data`,
`zd_slice_len`, `zd_slice_drop`, plus `zd_bytes_clone`). This leaks implementation
detail into the Dart API.

Instead, provide two convenience C shim functions:
- `zd_bytes_len(bytes)` — returns content length
- `zd_bytes_to_buf(bytes, out, capacity)` — copies content to caller buffer

These internally use the slice API but don't expose it. The Dart `ZBytes.toBytes()`
method calls both to return a `Uint8List`.

### Decision 4: ZBytes.clone() and toBytes() complete the API

Neither `clone()` nor `toBytes()` is strictly required for the benchmark (Dart's
subscriber callback already extracts payload as `Uint8List`). However:

- **`clone()`** — shallow ref-counted copy, important for SHM scenarios where
  data copy is expensive. Completes parity with zenoh-cpp `Bytes::clone()`.
- **`toBytes()`** — read path for ZBytes content. Currently ZBytes can be created
  from bytes (`fromUint8List`) but cannot be read as bytes (only `toStr()`).
  Completes the symmetry.

---

## C Shim Functions (4 new + 1 modified, 88 → 92 total)

### Background subscriber

```c
// Declare a background subscriber (fire-and-forget, lives until session closes).
// Samples posted to dart_port via NativePort.
// Reuses _zd_sample_callback and _zd_sample_drop from zd_declare_subscriber.
// Returns 0 on success, non-zero on error.
FFI_PLUGIN_EXPORT int zd_declare_background_subscriber(
    const z_loaned_session_t* session,
    const z_loaned_keyexpr_t* keyexpr,
    int64_t dart_port);
```

Wraps: `z_declare_background_subscriber(session, keyexpr, closure, NULL)`.
Reuses `_zd_sample_callback` and `_zd_sample_drop` — same NativePort bridge.

### Bytes clone

```c
// Shallow clone of bytes (reference-counted, no data copy).
// Caller must allocate dst via zd_bytes_sizeof().
// Loans src internally via z_bytes_loan() — Dart passes owned pointer.
FFI_PLUGIN_EXPORT void zd_bytes_clone(
    z_owned_bytes_t* dst,
    const z_owned_bytes_t* src);
```

Wraps: `z_bytes_loan(src)` → `z_bytes_clone(dst, loaned)`.

### Bytes length

```c
// Get the content length of bytes.
// Loans internally via z_bytes_loan() — Dart passes owned pointer.
FFI_PLUGIN_EXPORT size_t zd_bytes_len(const z_owned_bytes_t* bytes);
```

Wraps: `z_bytes_loan(bytes)` → `z_bytes_len(loaned)`.

### Bytes to buffer

```c
// Copy bytes content to a caller-provided buffer.
// Loans internally, then uses z_bytes_to_slice + z_slice_data + memcpy.
// Returns 0 on success, non-zero on error.
// Caller must provide a buffer of at least zd_bytes_len() bytes.
FFI_PLUGIN_EXPORT int zd_bytes_to_buf(
    const z_owned_bytes_t* bytes,
    uint8_t* out,
    size_t capacity);
```

### Modified: Publisher declaration (add is_express)

```c
// MODIFIED: add is_express parameter
FFI_PLUGIN_EXPORT int zd_declare_publisher(
    const z_loaned_session_t* session,
    z_owned_publisher_t* publisher,
    const z_loaned_keyexpr_t* keyexpr,
    const char* encoding,
    int congestion_control,
    int priority,
    int is_express);        // NEW: -1 = default, 0 = false, 1 = true
```

Adds `opts.is_express` setting when `is_express >= 0`.

---

## zenoh-c APIs Wrapped

| C shim function | zenoh-c function(s) |
|---|---|
| `zd_declare_background_subscriber` | `z_declare_background_subscriber`, `z_closure_sample` |
| `zd_bytes_clone` | `z_bytes_loan`, `z_bytes_clone` |
| `zd_bytes_len` | `z_bytes_loan`, `z_bytes_len` |
| `zd_bytes_to_buf` | `z_bytes_loan`, `z_bytes_to_slice`, `z_slice_loan`, `z_slice_data`, `z_slice_len`, `z_slice_drop` |
| `zd_declare_publisher` (modified) | `z_declare_publisher` (now sets `opts.is_express`) |

**Reused C shim callbacks (no changes needed):**

| Existing function | Reused for |
|---|---|
| `_zd_sample_callback` (static) | Background subscriber sample callback |
| `_zd_sample_drop` (static) | Background subscriber context cleanup |

---

## Dart API Surface

### Modify: `package/lib/src/session.dart`

```dart
class Session {
  /// Declares a background subscriber on the given [keyExpr].
  ///
  /// Returns a [Stream<Sample>] that delivers samples until the session closes.
  /// The background subscriber cannot be explicitly undeclared — it lives for
  /// the lifetime of the session.
  ///
  /// Throws [ZenohException] if the key expression is invalid.
  /// Throws [StateError] if the session has been closed.
  Stream<Sample> declareBackgroundSubscriber(String keyExpr);

  /// MODIFIED: add isExpress parameter
  Publisher declarePublisher(
    String keyExpr, {
    Encoding? encoding,
    CongestionControl congestionControl = CongestionControl.block,
    Priority priority = Priority.data,
    bool isExpress = false,            // NEW
    bool enableMatchingListener = false,
  });
}
```

### Modify: `package/lib/src/publisher.dart`

```dart
class Publisher {
  /// MODIFIED: add isExpress parameter
  static Publisher declare(
    Pointer<Void> loanedSession,
    Pointer<Void> loanedKe, {
    Encoding? encoding,
    CongestionControl congestionControl = CongestionControl.block,
    Priority priority = Priority.data,
    bool isExpress = false,            // NEW
    bool enableMatchingListener = false,
  });
}
```

### Modify: `package/lib/src/bytes.dart`

```dart
class ZBytes {
  /// Creates a shallow clone of this payload (reference-counted, no data copy).
  ///
  /// Both the original and the clone remain valid and independent.
  /// The clone must be separately [dispose]d or consumed.
  ///
  /// Throws [StateError] if this ZBytes has been disposed or consumed.
  ZBytes clone();

  /// Copies the payload content to a Dart [Uint8List].
  ///
  /// Throws [StateError] if this ZBytes has been disposed or consumed.
  /// Throws [ZenohException] if the content cannot be read.
  Uint8List toBytes();
}
```

---

## CLI Examples to Create

All in `package/example/` (corrected from original spec's `package/bin/`).

### `package/example/z_pong.dart`

Mirrors `extern/zenoh-c/examples/z_pong.c`.

```
Usage: fvm dart run example/z_pong.dart [OPTIONS]

Options:
    --no-express            (flag: disable message batching)
    -e, --connect <ENDPOINT>
    -l, --listen <ENDPOINT>
```

Behavior:
1. Open session
2. Declare publisher on `test/pong` (express mode by default)
3. Declare background subscriber on `test/ping`
4. On each sample: create `ZBytes.fromUint8List(sample.payloadBytes)`, publish to pong
5. Run until Ctrl-C

### `package/example/z_ping.dart`

Mirrors `extern/zenoh-c/examples/z_ping.c`.

```
Usage: fvm dart run example/z_ping.dart [OPTIONS] <PAYLOAD_SIZE>

Positional:
    <PAYLOAD_SIZE>              (required, int) Size of payload in bytes

Options:
    -n, --samples <NUM>         (default: 100) Number of pings
    -w, --warmup <MS>           (default: 1000) Warmup time in ms
    --no-express                (flag: disable message batching)
    -e, --connect <ENDPOINT>
    -l, --listen <ENDPOINT>
```

Behavior:
1. Open session
2. Declare publisher on `test/ping` (express mode by default)
3. Declare subscriber on `test/pong`
4. Create payload of given size (zeros)
5. Warmup: publish + await pong for warmup duration, discard times
6. Measurement: for each ping, record `Stopwatch`, publish, `await completer.future`, compute RTT
7. Print: `<size> bytes: seq=<i> rtt=<us>us, lat=<us>us`
8. Close

**Dart synchronization pattern** (replaces C mutex/condvar):
```dart
late Completer<void> pongReceived;
sub.stream.listen((_) { pongReceived.complete(); });

for (var i = 0; i < samples; i++) {
  pongReceived = Completer<void>();
  final sw = Stopwatch()..start();
  publisher.putBytes(ZBytes.fromUint8List(data));
  await pongReceived.future;
  final rtt = sw.elapsedMicroseconds;
  print('$payloadSize bytes: seq=$i rtt=${rtt}us, lat=${rtt ~/ 2}us');
}
```

---

## Verification Criteria

1. `fvm dart analyze package` — no errors
2. **Background subscriber receives samples**: two sessions; background subscriber on session B; pub on session A → stream receives Sample
3. **Background subscriber has no close**: stream continues until session closes
4. **Background subscriber on closed session throws StateError**
5. **Background subscriber with invalid keyexpr throws ZenohException**
6. **Publisher isExpress=true creates publisher without error**
7. **Publisher isExpress=false (default) is backward compatible**: all existing publisher tests still pass
8. **ZBytes.clone() produces independent copy**: clone and original both valid after clone
9. **ZBytes.clone() is shallow**: clone of SHM-backed bytes is also SHM-backed
10. **ZBytes.clone() on disposed/consumed throws StateError**
11. **ZBytes.toBytes() returns correct content**: round-trip fromUint8List → toBytes matches
12. **ZBytes.toBytes() on disposed/consumed throws StateError**
13. **ZBytes.toBytes() on empty bytes returns empty Uint8List**
14. **Ping/pong CLI integration**: z_pong + z_ping run together, ping prints latency results

---

## Corrections From Original Spec

| Issue | Original | Revised |
|---|---|---|
| CLI example location | `package/bin/` | `package/example/` (project convention) |
| Slice API exposed | 5 C shim functions for slice | 2 convenience functions (`zd_bytes_len`, `zd_bytes_to_buf`) |
| Missing connect/listen flags | Not mentioned | Added `-e/--connect`, `-l/--listen` (zenoh-c standard) |
| C shim function count | "6 new" implied | 4 new + 1 modified (publisher) |
| Missing is_express sentinel | Not specified | Uses -1 sentinel, consistent with other publisher params |
| Slice sizeof missing | Not mentioned | Not needed — slice is internal to `zd_bytes_to_buf` |
| Bytes functions took loaned pointers | `const z_loaned_bytes_t*` | `const z_owned_bytes_t*` — Dart holds owned, shim loans internally (matches `zd_bytes_is_shm` pattern). Fixed per Data's review. |
| z_pong.dart clone usage | Spec implied clone used in pong | Dart pong uses `ZBytes.fromUint8List(sample.payloadBytes)` — NativePort already extracts bytes. `clone()` tested separately. |
