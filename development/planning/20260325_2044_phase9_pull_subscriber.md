# Planning Archive: Phase 9 — Pull Subscriber (Ring Buffer)

**Feature:** Pull-based subscriber with C-side ring buffer — `PullSubscriber`, `Session.declarePullSubscriber`, `tryRecv()`, `z_pull.dart` CLI
**Approved:** 2026-03-25T20:44:17Z
**Iterations:** 1 (approved on first pass)

## Overview

Phase 9 adds a pull-based subscriber backed by zenoh-c's ring channel. Unlike the Phase 2 callback subscriber which pushes every sample via NativePort, the pull subscriber stores samples in a lossy ring buffer on the C side. The Dart application polls explicitly via `tryRecv()`, receiving either a Sample or null (empty buffer). When the buffer is full, the oldest samples are dropped. This is the "latest value" pattern for sensor telemetry.

## Plan Summary

- **4 slices**, ~18 new tests (262 → ~280 total)
- **4 new C shim functions** (73 → 77 total)
- **1 new Dart source file** (`pull_subscriber.dart`), 1 modified (`session.dart`)
- **1 new CLI example** (`z_pull.dart`)

### Slice Breakdown

| Slice | Description | C Functions | Tests | TCP Port |
|-------|-------------|-------------|-------|----------|
| 1 | Declare + Basic tryRecv | 4 (all) | 6 | 17480 |
| 2 | Ring Buffer Lossy Behavior | 0 | 3 | 17481 |
| 3 | Lifecycle and Error Handling | 0 | 5 | 17482 |
| 4 | CLI z_pull.dart | 0 | 4 | 18571 |

### Key Design Decisions

- **Fat tryRecv pattern:** Single FFI call extracts all sample fields. Sample created, extracted, and dropped within C. Dart never holds a sample handle.
- **Positive return codes:** `try_recv` returns 0=sample, 1=closed, 2=empty (NOT the usual non-zero=error pattern).
- **Reuses z_owned_subscriber_t:** Same type as Phase 2 callback subscriber. Difference is ring channel closure vs NativePort closure.
- **Cleanup order:** subscriber drop → handler drop → session drop (matches z_pull.c).

### Deferred
- `z_subscriber_options_t` additional fields (none in v1.7.2)
- `recv()` blocking variant (Dart async doesn't need it)
- Ring channel for queryable
