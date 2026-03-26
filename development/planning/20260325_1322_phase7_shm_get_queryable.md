# Planning Archive: Phase 7 — SHM Get/Queryable

**Feature:** SHM-backed payloads for query/reply pattern — widen `Session.get()` and `Query.replyBytes()` to accept `ZBytes`, add `ZBytes.isShmBacked`, 2 SHM CLI examples
**Approved:** 2026-03-25T13:22:49Z
**Iterations:** 1 (approved on first pass)

## Overview

Phase 7 extends the Phase 6 get/queryable path to support shared memory payloads. The core changes are signature widening (`Uint8List` → `ZBytes`) on `Session.get()` and `Query.replyBytes()`, plus a new `ZBytes.isShmBacked` property and two SHM CLI examples. This enables zero-copy SHM payloads in queries and replies, matching the SHM publisher path from Phase 4.

## Plan Summary

- **7 slices**, ~27 new tests (~237 → ~264 total)
- **1 new C shim function** (`zd_bytes_is_shm`), 2 modified (`zd_get`, `zd_query_reply`)
- **73 total C shim functions** (72 + 1)
- **2 new CLI examples** (`z_get_shm.dart`, `z_queryable_shm.dart`)
- **1 new test file** (`shm_get_queryable_test.dart`), 2 new CLI test files

### Slice Breakdown

| Slice | Description | C Functions | Tests |
|-------|-------------|-------------|-------|
| 1 | Widen zd_get → ZBytes | 1 modified | 4 |
| 2 | Widen zd_query_reply → ZBytes | 1 modified | 3 |
| 3 | ZBytes.fromBytes + SHM get E2E | 0 | 4 |
| 4 | SHM reply E2E | 0 | 4 |
| 5 | ZBytes.isShmBacked | 1 new | 5 |
| 6 | z_get_shm.dart CLI | 0 | 4 |
| 7 | z_queryable_shm.dart CLI | 0 | 3 |

### Key Design Decisions

- Widen C shim signatures to accept `z_owned_bytes_t*` instead of raw buffers — enables both SHM and non-SHM ZBytes
- `ZBytes.fromBytes` factory as convenience alias (delegates to existing `fromUint8List` pattern)
- `zd_bytes_is_shm()` feature-guarded with `Z_FEATURE_SHARED_MEMORY` + `Z_FEATURE_UNSTABLE_API`
- Breaking signature changes require Phase 6 test migration in Slices 1-2

### Deferred

- QoS options (congestion_control, priority, is_express) on get/reply
- Attachments on get/reply
- Locality filtering
- Unstable API fields
