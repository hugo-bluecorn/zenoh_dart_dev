# Phase 18 Planning Archive — Advanced Pub/Sub

**Date:** 2026-03-30
**Planner:** CP (Geordi)
**Source:** `development/design/phase-18-advanced-revised.md`

This is a copy of the approved plan. The working copy is `.tdd-progress.md`.

---

## Summary

| Slice | Name | Tests | Depends on | Blocks |
|-------|------|-------|------------|--------|
| 1 | AdvancedPublisher Lifecycle | 7 | none | 2, 3, 4, 5, 6 |
| 2 | AdvancedPublisher Put/Delete/PutBytes | 5 | 1 | 4, 5, 6 |
| 3 | AdvancedPublisher Options and Configuration | 6 | 1 | 5 |
| 4 | AdvancedSubscriber Lifecycle and Stream | 7 | 1 | 5, 6 |
| 5 | Advanced Pub/Sub Integration and History | 5 | 2, 4 | 6 |
| 6 | Miss Listener and Miss Events | 4 | 4 | 7 |
| 7 | CLI Examples | 5 | 5, 6 | none |

**Total: 7 slices, 39 tests**

**Scope:** +12 C shim functions (144→156), +6 Dart types, +2 CLI examples
