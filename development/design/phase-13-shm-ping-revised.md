# Phase 13: SHM Ping/Pong Latency Benchmark — Revised Design Spec

**Status:** DRAFT
**Author:** CA (Riker)
**Date:** 2026-03-27
**Source of truth:** `development/phases/phase-13-shm-ping.md`
**Predecessor:** Phase 12 (Ping/Pong Benchmark, PR #26)

---

## Goal

SHM variant of the ping/pong latency benchmark. Demonstrates the
**allocate-once, clone-in-loop** zero-copy pattern — the defining SHM
optimization over heap-based ping.

The pong side is SHM-transparent and reuses the existing `z_pong.dart`
from Phase 12 unchanged.

## Scope Summary

| Metric | Before | After | Delta |
|--------|--------|-------|-------|
| C shim functions | 92 | 92 | 0 |
| Dart API classes | 27 | 27 | 0 |
| CLI examples | 18 | 19 | +1 |
| Integration tests | 372 | ~382 | ~+10 |

This is a **composition phase** — no new C shim functions, no new Dart
API surface. All functionality composes from existing primitives:

- `ShmProvider.allocGcDefragBlocking()` (Phase 4)
- `ShmMutBuffer.data` / `.toBytes()` (Phase 4)
- `ZBytes.clone()` (Phase 12)
- `ZBytes.isShmBacked` (Phase 7)
- `Session.declareBackgroundSubscriber()` (Phase 12)
- `Publisher` with `isExpress` (Phase 12)
- `Publisher.putBytes()` (Phase 3)

## Why No `ShmBuffer` / `toImmutable()`

The phase spec mentions an intermediate `ShmBuffer` class with
`ShmMutBuffer.toImmutable()`. This is unnecessary for our binding:

**C API two-step path:**
```c
z_shm_from_mut(&shm, z_move(alloc.buf));     // mut → immutable z_owned_shm_t
z_bytes_from_shm(&shmbs, z_move(shm));        // immutable → z_owned_bytes_t
```

**Our C shim one-step path (Phase 4):**
```c
// zd_bytes_from_shm_mut calls z_bytes_from_shm_mut internally
zd_bytes_from_shm_mut(bytes, buf);             // mut → z_owned_bytes_t directly
```

Both produce identical SHM-backed `z_owned_bytes_t`. The intermediate
`z_owned_shm_t` type is a C API artifact for explicit type transitions
that Dart doesn't need. Our existing `ShmMutBuffer.toBytes()` already
does the right thing.

Adding `ShmBuffer` would be dead API surface with no consumer. Skipped.

## C Shim Functions

**None.** All required functions exist:

| Function | Phase | Purpose |
|----------|-------|---------|
| `zd_shm_provider_new` | 4 | Create SHM provider |
| `zd_shm_provider_alloc` | 4 | Allocate mutable buffer |
| `zd_shm_mut_data_mut` | 4 | Get writable pointer |
| `zd_bytes_from_shm_mut` | 4 | Convert mut buffer → ZBytes |
| `zd_bytes_clone` | 12 | Shallow ref-counted clone |
| `zd_bytes_is_shm` | 7 | Detect SHM backing |
| `zd_declare_publisher` | 3/12 | Declare with isExpress |
| `zd_publisher_put` | 3 | Publish bytes |
| `zd_declare_background_subscriber` | 12 | Fire-and-forget subscriber |

## Dart API Surface

**No new classes or methods.** The SHM ping pattern composes existing API:

```dart
// 1. Allocate once
final provider = ShmProvider(size: payloadSize * 32);
final mutBuf = provider.allocGcDefragBlocking(payloadSize)!;

// 2. Fill with data pattern
final data = mutBuf.data;
for (var i = 0; i < payloadSize; i++) {
  data[i] = i % 10;
}

// 3. Convert to SHM-backed bytes (consumes mutBuf)
final shmBytes = mutBuf.toBytes();

// 4. In measurement loop: clone (shallow ref) and publish
for (var i = 0; i < samples; i++) {
  publisher.putBytes(shmBytes.clone());   // near-zero-cost copy
  await pongReceived.future;              // wait for echo
  // measure RTT
}

// 5. Cleanup
shmBytes.dispose();
mutBuf.dispose();   // no-op (consumed by toBytes)
provider.close();
```

### Key Difference from z_pub_shm.dart

| Aspect | z_pub_shm (Phase 4) | z_ping_shm (this phase) |
|--------|---------------------|------------------------|
| Allocation | Per-publish: `alloc()` every iteration | Once: `alloc()` → `toBytes()` before loop |
| Per-publish cost | Full SHM alloc + fill + convert | `clone()` only (ref count increment) |
| Pattern | Demonstrate basic SHM publish | Demonstrate zero-copy SHM reuse |

## CLI Example

### `package/example/z_ping_shm.dart`

Mirrors `extern/zenoh-c/examples/z_ping_shm.c`. Identical flags to
`z_ping.dart` — same interface, different payload strategy.

```
Usage: z_ping_shm <PAYLOAD_SIZE> [OPTIONS]

Arguments:
    <PAYLOAD_SIZE>  (required): Size of the SHM payload in bytes

Options:
    -n, --samples <NUM>     Number of pings (default: 100)
    -w, --warmup <MS>       Warmup time in ms (default: 1000)
    --no-express            Disable message batching
    -e, --connect <EP>      Connect endpoint(s)
    -l, --listen <EP>       Listen endpoint(s)
```

**Behavior:**
1. Open session with optional connect/listen endpoints
2. Declare express publisher on `test/ping`
3. Declare background subscriber on `test/pong`
4. Create SHM provider (pool size = `payloadSize * 32`, matching C++ reference
   `buffers_count = 32` for SHM pool headroom)
5. Allocate SHM buffer via `allocGcDefragBlocking(payloadSize)`, fill with `i % 10` pattern
6. Convert: `mutBuf.toBytes()` → `shmBytes`
7. Warmup: publish `shmBytes.clone()` + await pong, repeat for `warmup` ms
8. Measure: for each sample, `shmBytes.clone()` → publish → await pong → record RTT
9. Print: `<size> bytes: seq=<i> rtt=<us>us, lat=<us>us`
10. Cleanup: dispose shmBytes, close provider, close session

**Pong side:** Reuses `z_pong.dart` unchanged. The pong subscriber receives
bytes transparently (SHM or heap), echoes them back via `ZBytes.fromUint8List`.

## Test Plan

### Group 1: SHM Clone Integration (in `shm_provider_test.dart`)

Tests validating the allocate-once-clone-many pattern. These fill a gap —
existing tests cover SHM alloc/publish but not clone semantics on SHM bytes.

Uses the existing TCP sessions from the `SHM Pub/Sub Integration` group
(port 17456).

1. **SHM bytes are SHM-backed after toBytes()** — `provider.allocGcDefragBlocking(N)` → fill →
   `toBytes()` → `isShmBacked == true`

2. **Clone of SHM bytes is SHM-backed** — `shmBytes.clone()` → `isShmBacked == true`

3. **Clone of SHM bytes preserves content** — `shmBytes.toBytes()` and
   `shmBytes.clone().toBytes()` return identical `Uint8List`

4. **Multiple clones from same SHM bytes all publishable** — Allocate once,
   clone 3 times, publish each clone via publisher on session1, subscriber on
   session2 receives all 3 samples with correct payload

5. **Original SHM bytes usable after clones consumed** — After publishing
   3 clones (each consumed by `putBytes`), original `shmBytes` still valid:
   `toStr()` / `toBytes()` / `isShmBacked` all work

6. **Clone of SHM bytes has independent lifetime** — Dispose original, clone
   still returns correct content via `toBytes()`

### Group 2: CLI z_ping_shm (in `z_ping_shm_cli_test.dart`)

Mirrors the z_ping CLI tests from Phase 12, adapted for SHM.

TCP ports: **18580-18585** (above Phase 12's 18570-18575 range)

7. **z_ping_shm requires payload size argument** — Run with no args → non-zero
   exit code

8. **z_ping_shm prints latency results with z_pong** — Start z_pong on port
   18580, run z_ping_shm connecting to same port with payload `8`, `--samples 3`,
   `--warmup 0` → stdout contains `8 bytes: seq=0 rtt=`

9. **z_ping_shm accepts --no-express flag** — Start z_pong on port 18581,
   run z_ping_shm with `--no-express` → completes without error

10. **z_ping_shm prints SHM-related startup messages** — Run and kill after
    3s → stdout contains `SHM Provider` and `Allocating SHM buffer`

## Deferred

- **ShmBuffer class / toImmutable()** — No consumer. If a future phase needs
  the intermediate immutable SHM type, it can be added then.
- **z_pong_shm.dart** — No such example in zenoh-c. Pong is SHM-transparent.
- **SHM on Android** — SHM features excluded on Android (upstream POSIX
  `shm_open` blocker in Bionic). No Android-specific work in this phase.

## Verification Criteria

1. `fvm dart analyze package` — clean
2. All 372 existing tests still pass (regression)
3. ~10 new tests pass (SHM clone integration + CLI)
4. `z_pong.dart` + `z_ping_shm.dart` produces latency output
5. `z_ping_shm.dart` latency comparable to or better than `z_ping.dart`
   (expected: lower per-publish overhead due to clone vs deep copy)

## Reference

| What | Where |
|------|-------|
| Phase spec | `development/phases/phase-13-shm-ping.md` |
| C reference | `extern/zenoh-c/examples/z_ping_shm.c` |
| C++ reference | `extern/zenoh-cpp/examples/zenohc/z_ping_shm.cxx` |
| Existing z_ping | `package/example/z_ping.dart` |
| Existing z_pong | `package/example/z_pong.dart` |
| Existing SHM tests | `package/test/shm_provider_test.dart` |
| Phase 12 spec | `development/design/phase-12-ping-pong-revised.md` |
