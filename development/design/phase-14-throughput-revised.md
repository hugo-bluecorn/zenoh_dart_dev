# Phase 14: Throughput Benchmarks — Revised Design Spec

**Status:** DRAFT
**Author:** CA (Riker)
**Date:** 2026-03-30
**Source of truth:** `development/phases/phase-14-throughput.md`
**Predecessor:** Phase 13 (SHM Ping, PR #27)

---

## Goal

Throughput benchmarks measuring maximum message rate. The publisher sends
data as fast as possible in a tight loop, the subscriber counts messages
and reports throughput in `msg/s` per round.

Three CLI examples matching zenoh-c:
- `z_pub_thr` — heap-based tight-loop publisher
- `z_sub_thr` — background subscriber counting messages per round
- `z_pub_shm_thr` — SHM zero-copy tight-loop publisher

## Scope Summary

| Metric | Before | After | Delta |
|--------|--------|-------|-------|
| C shim functions | 92 | 92 | 0 |
| Dart API classes | 27 | 27 | 0 |
| CLI examples | 19 | 22 | +3 |
| Integration tests | 382 | ~394 | ~+12 |

This is a **composition phase** — no new C shim functions, no new Dart
API surface. All functionality composes from existing primitives:

- `Session.declarePublisher(congestionControl:, priority:, isExpress:)` (Phase 3/12)
- `Publisher.putBytes()` (Phase 3)
- `ZBytes.fromUint8List()` / `ZBytes.clone()` (Phase 1/12)
- `Session.declareBackgroundSubscriber()` (Phase 12)
- `ShmProvider.allocGcDefragBlocking()` (Phase 4)
- `ShmMutBuffer.data` / `.toBytes()` (Phase 4)

## Why No New C Shim Functions

The original Phase 14 spec proposes three C shim setter functions:
`zd_publisher_options_set_congestion_control`, `zd_publisher_options_set_priority`,
and `zd_publisher_options_set_express`. These are unnecessary.

Phase 3 already implemented `CongestionControl` and `Priority` enums
and `declarePublisher()` accepts all three parameters (`congestionControl`,
`priority`, `isExpress`) via the flattened C shim pattern — sentinel values
(-1 for default enums, 0/1 for bool) passed directly to `zd_declare_publisher()`.

The original spec was written before Phase 3 delivered these features.

## Why No New Dart API Surface

The original spec proposes adding `CongestionControl` and `Priority` enums
and extending `declarePublisher` with new parameters. All three already exist:

| What | File | Phase |
|------|------|-------|
| `CongestionControl` enum (drop, block) | `package/lib/src/congestion_control.dart` | 3 |
| `Priority` enum (realTime..background) | `package/lib/src/priority.dart` | 3 |
| `declarePublisher(congestionControl:)` | `package/lib/src/session.dart:229` | 3 |
| `declarePublisher(priority:)` | `package/lib/src/session.dart:230` | 3 |
| `declarePublisher(isExpress:)` | `package/lib/src/session.dart:231` | 12 |

## C Shim Functions

**None.** All required functions exist:

| Function | Phase | Purpose |
|----------|-------|---------|
| `zd_declare_publisher` | 3/12 | Declare with congestionControl, priority, isExpress |
| `zd_publisher_put` | 3 | Publish bytes |
| `zd_bytes_from_uint8list` | 1 | Create ZBytes from Uint8List |
| `zd_bytes_clone` | 12 | Shallow ref-counted clone |
| `zd_declare_background_subscriber` | 12 | Fire-and-forget subscriber |
| `zd_shm_provider_new` | 4 | Create SHM provider |
| `zd_shm_provider_alloc_gc_defrag_blocking` | 4 | Allocate mutable buffer |
| `zd_shm_mut_data_mut` | 4 | Get writable pointer |
| `zd_bytes_from_shm_mut` | 4 | Convert mut buffer to ZBytes |

## Dart API Surface

**No new classes or methods.**

### z_pub_thr Pattern (Heap)

```dart
// Declare publisher with BLOCK congestion control (backpressure)
final publisher = session.declarePublisher(
  'test/thr',
  congestionControl: CongestionControl.block,
  priority: priority,
  isExpress: express,
);

// Build payload once, clone in tight loop
final zbytes = ZBytes.fromUint8List(payload);
while (running) {
  publisher.putBytes(zbytes.clone());
}
```

### z_sub_thr Pattern (Counter)

```dart
// Background subscriber — fire-and-forget, lives until session closes
final stream = session.declareBackgroundSubscriber('test/thr');

// Count messages, report throughput per round
var count = 0;
Stopwatch? roundWatch;

stream.listen((_) {
  if (count == 0) {
    roundWatch = Stopwatch()..start();
    count++;
  } else if (count < messagesPerRound) {
    count++;
  } else {
    final elapsed = roundWatch!.elapsedMicroseconds;
    final throughput = (messagesPerRound * 1000000.0) / elapsed;
    print('${throughput.toStringAsFixed(1)} msg/s');
    count = 0;
    finishedRounds++;
    if (finishedRounds >= maxRounds) exit(0);
  }
});
```

### z_pub_shm_thr Pattern (SHM Zero-Copy)

```dart
// Declare publisher with BLOCK congestion control
final publisher = session.declarePublisher(
  'test/thr',
  congestionControl: CongestionControl.block,
);

// Allocate SHM buffer once
final provider = ShmProvider(size: shmSizeMb * 1024 * 1024);
final mutBuf = provider.allocGcDefragBlocking(payloadSize)!;
// Fill with pattern
final data = mutBuf.data;
for (var i = 0; i < payloadSize; i++) {
  data[i] = 1;  // matches C reference (memset to 1)
}
final shmBytes = mutBuf.toBytes();

// Clone in tight loop — near-zero-cost per publish
while (running) {
  publisher.putBytes(shmBytes.clone());
}
```

## CLI Examples

All examples live in `package/example/`. Build hooks resolve native
libraries automatically — no `LD_LIBRARY_PATH` needed.

### `package/example/z_pub_thr.dart`

Mirrors `extern/zenoh-c/examples/z_pub_thr.c`.

```
Usage: z_pub_thr <PAYLOAD_SIZE> [OPTIONS]

Arguments:
    <PAYLOAD_SIZE>  (required): Size of the payload to publish in bytes

Options:
    -p, --priority <PRIORITY>   Priority level 1-7 (default: 5 = data)
    --express                   Enable express mode (disable batching)
    -e, --connect <ENDPOINT>    Connect endpoint(s)
    -l, --listen <ENDPOINT>     Listen endpoint(s)
```

**Behavior:**
1. Open session with optional connect/listen endpoints
2. Declare publisher on `test/thr` with `congestionControl: CongestionControl.block`,
   configurable priority and express mode
3. Create payload of given size, fill with `i % 10` pattern
4. Convert to `ZBytes` once via `ZBytes.fromUint8List(payload)`
5. Tight loop: `publisher.putBytes(zbytes.clone())` until SIGINT
6. Cleanup: close publisher, close session

**Key difference from z_pub.dart:** No timer, no key expression or payload
flags. Pure throughput — tight loop, block congestion control, clone-in-loop.

**Priority CLI mapping:** The C reference accepts integers 1-7 on the
command line, mapping directly to `z_priority_t` values. The Dart `Priority`
enum uses zero-based indices (0-6), so the conversion is
`Priority.values[cliValue - 1]`. The implementer must validate the CLI value
is in range 1-7 and subtract 1 for the enum index.

**zenoh-c flag mapping:**
| C flag | Dart flag | Notes |
|--------|-----------|-------|
| positional `<PAYLOAD_SIZE>` | positional `<PAYLOAD_SIZE>` | Required |
| `-p`/`--priority` | `-p`/`--priority` | Integer 1-7, map to `Priority.values[n-1]` |
| `--express` | `--express` | Flag, default off |
| common `-e`/`-l` | `-e`/`--connect`, `-l`/`--listen` | Multi-option |

**Note on `-p` semantic shift:** In existing CLIs (`z_put`, `z_pub`,
`z_pub_shm`), `-p` means `--payload`. In `z_pub_thr`, `-p` means
`--priority`. This correctly mirrors the C reference — `z_pub_thr.c` has
no payload flag because payload is the positional size argument.

### `package/example/z_sub_thr.dart`

Mirrors `extern/zenoh-c/examples/z_sub_thr.c`.

```
Usage: z_sub_thr [OPTIONS]

Options:
    -s, --samples <NUM>     Number of throughput measurements (default: 10)
    -n, --number <NUM>      Messages per measurement round (default: 1000000)
    -e, --connect <ENDPOINT>  Connect endpoint(s)
    -l, --listen <ENDPOINT>   Listen endpoint(s)
```

**Behavior:**
1. Open session with optional connect/listen endpoints
2. Declare background subscriber on `test/thr`
3. For each round: count `number` messages, measure elapsed time, print
   `<throughput> msg/s`
4. Exit when `finishedRounds > samples` (strictly greater-than, matching C
   behavior). This means `samples + 1` measurement rounds are printed before
   exit. The C reference uses `finished_rounds > max_rounds` — the Dart
   implementation must use `>` not `>=` to match.
5. Summary line on exit: `sent N messages over X seconds (Y msg/s)`

**zenoh-c flag mapping:**
| C flag | Dart flag | Notes |
|--------|-----------|-------|
| `-s`/`--samples` | `-s`/`--samples` | Measurements/rounds |
| `-n`/`--number` | `-n`/`--number` | Messages per round |
| common `-e`/`-l` | `-e`/`--connect`, `-l`/`--listen` | Multi-option |

**Note:** The C reference enables SHM in the subscriber config
(`Z_CONFIG_SHARED_MEMORY_KEY = "true"`) when `Z_FEATURE_SHARED_MEMORY` is
defined. This allows SHM-optimized receive when paired with `z_pub_shm_thr`.
Our subscriber should do the same via `config.insertJson5('transport/shared_memory/enabled', 'true')`.
Verified: `Z_CONFIG_SHARED_MEMORY_KEY` resolves to `"transport/shared_memory/enabled"`
(`extern/zenoh-c/include/zenoh_constants.h:34`).

### `package/example/z_pub_shm_thr.dart`

Mirrors `extern/zenoh-c/examples/z_pub_shm_thr.c`.

```
Usage: z_pub_shm_thr <PAYLOAD_SIZE> [OPTIONS]

Arguments:
    <PAYLOAD_SIZE>  (required): Size of the SHM payload to publish in bytes

Options:
    -s, --shared-memory <SIZE_MB>  SHM pool size in MBytes (default: 32)
    -e, --connect <ENDPOINT>       Connect endpoint(s)
    -l, --listen <ENDPOINT>        Listen endpoint(s)
```

**Behavior:**
1. Open session with optional connect/listen endpoints
2. Declare publisher on `test/thr` with `congestionControl: CongestionControl.block`
3. Create SHM provider with pool size = `shmSizeMb * 1024 * 1024`
4. Allocate SHM buffer via `allocGcDefragBlocking(payloadSize)`, fill with `1`
   (matches C reference `memset(data, 1, size)`)
5. Convert: `mutBuf.toBytes()` -> `shmBytes`
6. Tight loop: `publisher.putBytes(shmBytes.clone())` until SIGINT
7. Cleanup: dispose shmBytes, close provider, close publisher, close session

**Key differences from z_pub_thr.dart:**
| Aspect | z_pub_thr (heap) | z_pub_shm_thr (SHM) |
|--------|-----------------|---------------------|
| Allocation | `ZBytes.fromUint8List(payload)` | `ShmProvider.allocGcDefragBlocking()` + `toBytes()` |
| Per-publish cost | `zbytes.clone()` — shallow copy | `shmBytes.clone()` — shallow ref-counted copy |
| No priority/express | Accepts priority + express flags | No priority/express (matches C) |
| SHM pool | N/A | Configurable via `-s` flag |

**Key differences from z_pub_shm.dart (Phase 4):**
| Aspect | z_pub_shm (Phase 4) | z_pub_shm_thr (this phase) |
|--------|---------------------|---------------------------|
| Allocation | Per-publish: `alloc()` every iteration | Once: `alloc()` + `toBytes()` before loop |
| Per-publish cost | Full SHM alloc + fill + convert | `clone()` only (ref count increment) |
| Loop timing | 1-second Timer.periodic | Tight loop, no delay |
| Congestion | Default (drop) | Block (backpressure) |

**zenoh-c flag mapping:**
| C flag | Dart flag | Notes |
|--------|-----------|-------|
| positional `<PAYLOAD_SIZE>` | positional `<PAYLOAD_SIZE>` | Required |
| `-s`/`--shared-memory` | `-s`/`--shared-memory` | MBytes, default 32 |
| common `-e`/`-l` | `-e`/`--connect`, `-l`/`--listen` | Multi-option |

## Test Plan

### Group 1: z_pub_thr CLI Tests (in `z_pub_thr_cli_test.dart`)

Tests validate the publisher CLI starts, accepts flags, and runs correctly.
Uses unique TCP ports to avoid collision with other test groups.

TCP ports: **18600-18603**

1. **z_pub_thr requires payload size argument** — Run with no args via
   `Process.run` -> non-zero exit code

2. **z_pub_thr starts and publishes** — Start z_sub_thr with `-s 1 -n 1000`
   listening on port 18600, start z_pub_thr connecting to port 18600 with
   payload size 64 -> z_sub_thr stdout contains `msg/s`

3. **z_pub_thr accepts --priority flag** — Start z_pub_thr with
   `--priority 1 64` connecting to port 18601 -> process starts without error
   (kill after 2s)

4. **z_pub_thr accepts --express flag** — Start z_pub_thr with
   `--express 64` connecting to port 18602 -> process starts without error
   (kill after 2s)

### Group 2: z_sub_thr CLI Tests (in `z_sub_thr_cli_test.dart`)

Tests validate the subscriber CLI's counting and reporting behavior.

TCP ports: **18610-18613**

5. **z_sub_thr reports throughput with z_pub_thr** — Start z_sub_thr with
   `-s 1 -n 1000` listening on port 18610, start z_pub_thr connecting to
   same port with payload size 8 -> z_sub_thr stdout contains `msg/s`

6. **z_sub_thr prints summary on exit** — Same as test 5 but with `-s 2 -n 1000`
   -> z_sub_thr stdout contains `messages over` (from the summary line)

7. **z_sub_thr exits after configured rounds** — Start z_sub_thr with
   `-s 1 -n 100` listening on port 18611, start z_pub_thr on same port
   -> z_sub_thr process exits on its own (exit code 0)

### Group 3: z_pub_shm_thr CLI Tests (in `z_pub_shm_thr_cli_test.dart`)

Tests validate the SHM throughput publisher.

TCP ports: **18620-18623**

8. **z_pub_shm_thr requires payload size argument** — Run with no args
   -> non-zero exit code

9. **z_pub_shm_thr starts and publishes with SHM** — Start z_sub_thr
   listening on port 18620, start z_pub_shm_thr connecting to port 18620
   with payload size 64 -> z_sub_thr stdout contains `msg/s`

10. **z_pub_shm_thr prints SHM startup messages** — Start z_pub_shm_thr
    with payload size 64 -> stdout contains `SHM Provider` and
    `Allocating SHM buffer`

11. **z_pub_shm_thr accepts --shared-memory flag** — Start z_pub_shm_thr
    with `-s 16 64` -> process starts without error, stdout contains
    `SHM Provider` (kill after 2s)

### Group 4: Cross-example Integration (in `throughput_integration_test.dart`)

Validates the throughput pair works together end-to-end.

TCP port: **18630**

12. **Dart pub/sub throughput pair produces measurable results** — Start
    z_sub_thr with `-s 1 -n 500` listening on port 18630, start z_pub_thr
    connecting to same port with payload size 8 -> z_sub_thr reports
    throughput > 0 msg/s and exits cleanly

## Deferred

- **`z_pub_shm_thr` on Android** — SHM features excluded on Android
  (upstream POSIX `shm_open` blocker in Bionic). SHM throughput testing
  is desktop-only.
- **Throughput comparison framework** — No automated comparison between
  heap and SHM throughput. Manual benchmarking only.
- **Publisher `put()` variant in tight loop** — The C reference uses
  `z_publisher_put` with `z_bytes_clone`. Our Dart `putBytes()` takes
  `ZBytes` (consumed). Using `clone()` matches the C pattern exactly.

## Verification Criteria

1. `fvm dart analyze package` — clean
2. All 382 existing tests still pass (regression)
3. ~12 new tests pass (CLI + integration)
4. `z_sub_thr` + `z_pub_thr` produces throughput output (`msg/s`)
5. `z_sub_thr` + `z_pub_shm_thr` produces throughput output (`msg/s`)
6. `z_sub_thr` exits after configured rounds
7. All three CLIs accept the documented flags matching zenoh-c exactly

## Reference

| What | Where |
|------|-------|
| Phase spec (original) | `development/phases/phase-14-throughput.md` |
| C reference: z_pub_thr | `extern/zenoh-c/examples/z_pub_thr.c` |
| C reference: z_sub_thr | `extern/zenoh-c/examples/z_sub_thr.c` |
| C reference: z_pub_shm_thr | `extern/zenoh-c/examples/z_pub_shm_thr.c` |
| Existing z_pub | `package/example/z_pub.dart` |
| Existing z_pub_shm | `package/example/z_pub_shm.dart` |
| Existing z_ping | `package/example/z_ping.dart` |
| Existing z_ping_shm | `package/example/z_ping_shm.dart` |
| Phase 12 spec | `development/design/phase-12-ping-pong-revised.md` |
| Phase 13 spec | `development/design/phase-13-shm-ping-revised.md` |
