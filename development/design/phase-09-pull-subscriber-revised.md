# Phase 9: Pull Subscriber (Ring Buffer) — Revised Spec

> **CA revision of `development/phases/phase-09-pull.md`**
> Revised 2026-03-25 after cross-referencing zenoh-c v1.7.2 `z_pull.c`,
> zenoh-cpp channels.hxx, zenoh-kotlin Handler pattern, and Phase 8 skip
> analysis. Data's freshness analysis incorporated (C-side ring, Option A).

## Project Context

`zenoh` is a pure Dart FFI package providing bindings for zenoh-c v1.7.2 via a
C shim layer. See `development/phases/phase-00-bootstrap.md` for full architecture.

## Prior Phases (0–7, 8 skipped) — All Complete

- Phase 0–3: Session/config/keyexpr/bytes, put/delete, subscriber, publisher
- Phase 4: SHM provider, alloc, buffers, zero-copy publish
- Phase 5: Scout, session info
- Phase 6: Get/Queryable — query/reply via clone-and-post
- Phase 7: SHM Get/Queryable — widened payload types to z_owned_bytes_t*
- Phase 8: SKIPPED — Dart Streams subsume C's channel pattern
- 73 C shim functions, 262 integration tests

## This Phase's Goal

Implement a **pull-based subscriber** backed by a **C-side ring buffer**.
Unlike the callback subscriber (Phase 2) which pushes every sample via
NativePort, the pull subscriber stores samples in a lossy ring buffer
and the application explicitly polls for them.

**Key semantics (from zenoh-cpp docs):**
> "When the buffer is full, the older entries will be removed to provide
> room for the new ones."

This is **intentionally lossy** — designed for "latest value" / sensor
telemetry patterns where freshness matters more than completeness.

**Why C-side ring buffer (not Dart-side):**
Data's freshness analysis (2026-03-25): If Dart's event loop stalls (GC pause,
Flutter frame render), a Dart-side ring buffer contains samples that were
"recent" when posted from C but are stale by the time Dart processes them.
A C-side ring buffer ensures the surviving samples are the most recent ones
zenoh produced, regardless of Dart-side latency.

**Reference example:**
- `extern/zenoh-c/examples/z_pull.c` — ring buffer subscriber with polling
- No C++ equivalent exists (C++ doesn't expose a pull example)

## Architecture: Pull vs Push

| Aspect | Callback Subscriber (Phase 2) | Pull Subscriber (Phase 9) |
|---|---|---|
| Buffer location | Dart StreamController | C-side ring buffer |
| Delivery | NativePort push | Dart polls via FFI |
| Lossy? | No — unbounded Stream buffer | Yes — ring drops oldest when full |
| Sample extraction | C callback extracts + posts | C tryRecv extracts + returns |
| Consumer timing | Dart async event loop | Consumer controls poll interval |
| Use case | Real-time streams | Sensor sampling, latest-value |

## C Shim Functions to Add (4 functions)

### Sizeof for allocation

```c
// Size of z_owned_ring_handler_sample_t for FFI allocation
FFI_PLUGIN_EXPORT size_t zd_ring_handler_sample_sizeof(void);
```

### Constructor: declare pull subscriber

```c
// Declare a subscriber backed by a ring buffer channel.
// The ring buffer drops oldest samples when full (lossy).
// Returns 0 on success, negative on error.
//
// The closure and handler are created internally via z_ring_channel_sample_new().
// The closure is moved into z_declare_subscriber(). The handler is stored in
// the caller-allocated buffer for subsequent tryRecv calls.
//
// Reuses the existing z_owned_subscriber_t from Phase 2 — same drop function.
FFI_PLUGIN_EXPORT int zd_declare_pull_subscriber(
    const z_loaned_session_t* session,
    z_owned_subscriber_t* subscriber,     // output: caller-allocated via zd_subscriber_sizeof()
    z_owned_ring_handler_sample_t* handler, // output: caller-allocated via zd_ring_handler_sample_sizeof()
    const z_loaned_keyexpr_t* keyexpr,
    size_t capacity);                      // ring buffer capacity (z_pull.c default: 3)
```

**FFI barriers:**
- `z_ring_channel_sample_new()` — closure creation (Pattern 5)
- `z_declare_subscriber()` — closure move (Pattern 1)
- Combined into one call (consistent with "never two functions for same operation")

### Pull: try_recv with full extraction

```c
// Non-blocking receive from ring buffer with full sample extraction.
// On success (returns 0): all output parameters are populated.
//   Caller must free() out_keyexpr, out_payload, out_encoding, out_attachment.
// On empty (returns Z_CHANNEL_NODATA = 1): outputs untouched.
// On closed (returns Z_CHANNEL_DISCONNECTED = 2): outputs untouched.
//
// NOTE: NODATA and DISCONNECTED are POSITIVE return codes (1, 2), not negative.
// Dart must NOT use the usual "!= 0 means error" pattern here.
//
// This function does: try_recv → loan sample → extract all fields → drop sample.
// One FFI call per poll, consistent with how the subscriber callback extracts
// all fields in one NativePort message.
FFI_PLUGIN_EXPORT int zd_pull_subscriber_try_recv(
    const z_owned_ring_handler_sample_t* handler,
    char** out_keyexpr,            // malloc'd null-terminated string
    uint8_t** out_payload,         // malloc'd byte array
    size_t* out_payload_len,
    int32_t* out_kind,             // 0=PUT, 1=DELETE
    char** out_encoding,           // malloc'd string or NULL if no encoding
    uint8_t** out_attachment,      // malloc'd bytes or NULL if no attachment
    size_t* out_attachment_len);
```

**Why "fat tryRecv" instead of individual accessors:**
The original spec proposed 4 separate accessor functions (keyexpr, payload,
kind, drop). Our subscriber callback already extracts all fields in one
operation. The pull tryRecv does the same — one FFI call, all data returned.
The owned sample is created, extracted, and dropped entirely within the C shim.
Dart never holds a sample handle.

**FFI barriers:**
- `z_ring_handler_sample_try_recv()` is exported, but accessed via
  `z_try_recv()` which is a `_Generic` macro (Pattern 2)
- `z_sample_loan()` is exported, but `z_loan()` is `_Generic` (Pattern 2)
- String/bytes conversion chain involves macros

### Cleanup: drop ring handler

```c
// Drop the ring handler. Call after subscriber is dropped.
// The subscriber itself uses the existing zd_subscriber_drop() from Phase 2.
FFI_PLUGIN_EXPORT void zd_ring_handler_sample_drop(
    z_owned_ring_handler_sample_t* handler);
```

**FFI barrier:** `z_move()` is `static inline` (Pattern 1)

## zenoh-c APIs Wrapped

| C shim function | zenoh-c function(s) | Type |
|---|---|---|
| `zd_ring_handler_sample_sizeof` | `sizeof(z_owned_ring_handler_sample_t)` | NEW |
| `zd_declare_pull_subscriber` | `z_ring_channel_sample_new`, `z_declare_subscriber` | NEW |
| `zd_pull_subscriber_try_recv` | `z_ring_handler_sample_try_recv`, `z_sample_loan`, `z_sample_keyexpr`, `z_sample_payload`, `z_sample_kind`, `z_sample_encoding`, `z_sample_attachment`, `z_sample_drop` | NEW |
| `zd_ring_handler_sample_drop` | `z_ring_handler_sample_drop` | NEW |
| `zd_subscriber_drop` | (existing from Phase 2) | REUSED |

**Function count:** 73 existing + 4 new = **77 total**

## Dart API Surface

### New file: `package/lib/src/pull_subscriber.dart`

```dart
/// A pull-based subscriber backed by a C-side ring buffer.
///
/// Unlike [Subscriber] which pushes samples via a Stream, PullSubscriber
/// stores samples in a lossy ring buffer. The application polls via [tryRecv].
/// When the buffer is full, the oldest samples are dropped — the surviving
/// samples are always the most recent ones zenoh produced.
///
/// Typical usage: sensor telemetry with "latest N readings" semantics.
class PullSubscriber {
  /// The key expression this subscriber is declared on.
  String get keyExpr;

  /// Non-blocking receive of the latest available sample.
  /// Returns null if the ring buffer is empty.
  /// Throws [StateError] if the subscriber has been closed.
  Sample? tryRecv();

  /// Close the subscriber and its ring buffer.
  /// Idempotent — safe to call multiple times.
  void close();
}
```

### Modify: `package/lib/src/session.dart`

```dart
class Session {
  // ... existing methods ...

  /// Declare a pull-based subscriber with a ring buffer.
  ///
  /// Samples are stored in a lossy ring buffer of [capacity] entries.
  /// When the buffer is full, the oldest samples are dropped.
  /// Call [PullSubscriber.tryRecv] to poll for the latest sample.
  ///
  /// [capacity] is the ring buffer size (default: 3, matching z_pull.c).
  PullSubscriber declarePullSubscriber(
    String keyExpr, {
    int capacity = 3,
  });
}
```

### Modify: `package/lib/zenoh.dart`

Add export:
```dart
export 'src/pull_subscriber.dart';
```

## CLI Example

### `package/example/z_pull.dart`

Mirrors `extern/zenoh-c/examples/z_pull.c`:

```
Usage: fvm dart run example/z_pull.dart [OPTIONS]

Options:
    -k, --key <KEYEXPR>         (default: 'demo/example/**')
    -s, --size <RING_SIZE>      (default: 3)
    -e, --connect <ENDPOINT>    (optional: router endpoint)
    -l, --listen <ENDPOINT>     (optional: listen endpoint)
```

Behavior:
1. Open session
2. Declare pull subscriber with ring buffer of specified capacity
3. Print "Press ENTER to pull data or 'q' to quit..."
4. Loop: `stdin.readLineSync()` — on ENTER call `tryRecv()`, print sample if available
5. Print: `>> [Subscriber] Received PUT ('keyexpr': 'value')`
6. On 'q': close pull subscriber and session

Mirrors z_pull.c's `getchar()` interactive polling pattern exactly.

## Deferred

| Feature | Reason |
|---|---|
| `recv()` (blocking) | Dart async model doesn't need blocking receive |
| FIFO channel subscriber | Phase 8 skipped — Streams cover this |
| Ring channel for queryable | Not in z_pull.c scope; add if needed |
| Custom ring capacity validation | Simple int parameter, no validation needed |

## Verification

1. `cmake --build --preset linux-x64 --target install` — rebuild C shim
2. `cd package && fvm dart run ffigen --config ffigen.yaml` — regenerate bindings
3. `fvm dart analyze package` — no errors

### Integration tests (two-session TCP pattern)

4. **Basic pull receives sample**: Session A publishes, Session B's pull subscriber receives via tryRecv()
5. **tryRecv returns null when empty**: Pull subscriber with no publisher, tryRecv() returns null
6. **Ring buffer drops oldest**: Publish 10 samples rapidly into capacity=3 ring, tryRecv() yields at most 3
7. **Pull subscriber close is idempotent**: Close twice without error
8. **tryRecv after close throws StateError**: Closed pull subscriber, tryRecv() throws
9. **declarePullSubscriber on closed session throws StateError**
10. **declarePullSubscriber with invalid keyexpr throws ZenohException**
11. **PullSubscriber.keyExpr returns declared key expression**
12. **Sample fields correct**: keyExpr, payload, payloadBytes, kind all match published data
13. **Encoding preserved**: Publisher sends with encoding, pull subscriber receives correct encoding
14. **Multiple tryRecv drains buffer**: Publish 3 samples into capacity=3, call tryRecv() 3 times → 3 samples, 4th returns null

### CLI verification

15. Run `z_pull.dart` + `z_pub.dart` — pull subscriber prints received samples at poll interval
16. Cross-language: zenoh-c `z_pub` + Dart `z_pull.dart`

### Expected test count

~15-18 new tests (262 existing + ~15-18 = ~277-280 total)
