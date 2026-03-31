# Phase 14 Planning: Throughput Benchmarks

**Date:** 2026-03-30
**Status:** pending (awaiting approval)
**Source:** `development/design/phase-14-throughput-revised.md`
**Progress:** `.tdd-progress.md`

## Plan Summary

- 4 slices, 12 tests
- 0 new C shim functions (92 total), 0 new API classes (27 total)
- 3 new CLI examples: z_pub_thr, z_sub_thr, z_pub_shm_thr
- Composition phase -- all primitives exist from Phases 3, 4, 12

## CA Review Applied

1. [CRITICAL] Swapped Slice 1 and Slice 2 -- z_pub_thr is now Slice 1 (standalone tests), z_sub_thr is Slice 2 (depends on z_pub_thr)
2. [CRITICAL] Moved "z_pub_thr starts and publishes" to Slice 4 (Integration) since it validates pub paired with sub
3. [SUGGESTION] Added `-s 1 -n 1000` to Test 8 (z_pub_shm_thr + z_sub_thr) for fast test execution

## Slice Map

| Slice | Example | Tests | Count | Depends |
|-------|---------|-------|-------|---------|
| 1 | z_pub_thr | 1, 2, 3 | 3 | none |
| 2 | z_sub_thr | 4, 5, 6 | 3 | Slice 1 |
| 3 | z_pub_shm_thr | 7, 8, 9, 10 | 4 | Slice 1 |
| 4 | Integration | 11, 12 | 2 | Slices 1-3 |
