# Phase 17: In-Memory Storage — Revised Design Spec

**Status:** DRAFT
**Author:** CA (Riker)
**Date:** 2026-03-30
**Source of truth:** `development/phases/phase-17-storage.md`
**Predecessor:** Phase 16 (Bytes Serialization, PR #29)

---

## Goal

In-memory storage combining a subscriber and a queryable in a single
application. The subscriber stores incoming PUT/DELETE samples in a Dart
`Map`, and the queryable responds to queries by looking up matching entries
using zenoh key expression intersection.

This is a **composite example** — it proves that subscriber and queryable
primitives compose correctly in a real application pattern. The only new
API surface is key expression matching (`intersects` / `includes`) on
`KeyExpr`.

**Reference example:** `extern/zenoh-c/examples/z_storage.c`

## Scope Summary

| Metric | Before | After | Delta |
|--------|--------|-------|-------|
| C shim functions | 141 | 144 | +3 |
| Dart API classes | 30 | 30 | 0 |
| CLI examples | 23 | 24 | +1 |
| Integration tests | 455 | ~473 | ~+18 |

This is a **light feature phase** — 2 new C shim functions for key
expression matching, plus a composition CLI example.

## Why `zd_sample_clone` Is Unnecessary

The original spec proposes `zd_sample_clone`. This is not needed because
our `Sample` class is a pure Dart object — the subscriber's NativePort
callback converts all fields (keyExpr, payload, payloadBytes, kind,
attachment, encoding) to Dart values immediately. The storage stores Dart
`Sample` objects (or their string fields) in a `Map<String, Sample>`, not
native `z_owned_sample_t` handles. No native cloning required.

## C Shim Functions

### Key Expression Matching (3)

| Function | zenoh-c API | Purpose |
|----------|-------------|---------|
| `zd_keyexpr_intersects` | `z_keyexpr_intersects(z_loan(a), z_loan(b))` | Check if two key expressions intersect (FFI barrier #2: loan macros) |
| `zd_keyexpr_includes` | `z_keyexpr_includes(z_loan(a), z_loan(b))` | Check if key expression A includes B (FFI barrier #2: loan macros) |
| `zd_keyexpr_equals` | `z_keyexpr_equals(z_loan(a), z_loan(b))` | Check if two key expressions are identical (FFI barrier #2: loan macros) |

Both take two `z_view_keyexpr_t*` (view) parameters and loan them
internally via `zd_view_keyexpr_loan()` before calling the zenoh-c
function. Return `bool`.

**Semantics (from zenoh-c docs):**
- **intersects:** Returns true if there exists at least one key that is
  matched by both expressions. E.g., `demo/**` intersects `demo/example/test`.
- **includes:** Returns true if all keys matched by B are also matched by A.
  E.g., `demo/**` includes `demo/example/test`, but not vice versa.
  `includes` implies `intersects` but not the reverse.

**Total: 3 new C shim functions** (141 → 144)

## Dart API Surface

### Modified: `KeyExpr` (`package/lib/src/keyexpr.dart`)

```dart
class KeyExpr {
  // Existing: KeyExpr(String), value, nativePtr, dispose

  /// Returns true if this key expression intersects [other].
  ///
  /// Two key expressions intersect if there exists at least one key
  /// that matches both. E.g., `demo/**` intersects `demo/example/test`.
  ///
  /// Throws [StateError] if either KeyExpr has been disposed.
  bool intersects(KeyExpr other);

  /// Returns true if this key expression includes [other].
  ///
  /// A includes B if every key matched by B is also matched by A.
  /// E.g., `demo/**` includes `demo/example/test`.
  ///
  /// Throws [StateError] if either KeyExpr has been disposed.
  bool includes(KeyExpr other);

  /// Returns true if this key expression is identical to [other].
  ///
  /// Throws [StateError] if either KeyExpr has been disposed.
  bool equals(KeyExpr other);
}
```

No new classes. No modifications to other existing classes.

**Implementation note:** `Query.keyExpr` and `Sample.keyExpr` return
`String`, not `KeyExpr`. The storage query handler must construct temporary
`KeyExpr` objects from these strings for intersection matching:

```dart
final queryKe = KeyExpr(query.keyExpr);
try {
  for (final entry in store.entries) {
    final entryKe = KeyExpr(entry.key);
    try {
      if (queryKe.intersects(entryKe)) {
        query.reply(entry.key, entry.value.payload);
      }
    } finally {
      entryKe.dispose();
    }
  }
} finally {
  queryKe.dispose();
}
```

This is adequate for a CLI example with modest store sizes. The `KeyExpr`
construction cost is minimal (view creation + validation).

## CLI Example

### `package/example/z_storage.dart`

Mirrors `extern/zenoh-c/examples/z_storage.c`.

```
Usage: z_storage [OPTIONS]

Options:
    -k, --key <KEYEXPR>     Key expression to store (default: 'demo/example/**')
    --complete              Declare the storage as complete w.r.t. the key expression
    -e, --connect <EP>      Connect endpoint(s)
    -l, --listen <EP>       Listen endpoint(s)
```

**Behavior:**
1. Open session with optional connect/listen endpoints
2. Create in-memory store: `Map<String, Sample>`
3. Declare subscriber on key expression:
   - On PUT: `store[sample.keyExpr] = sample`; print
     `[Subscriber] Received PUT ('keyexpr': 'value')`
   - On DELETE: `store.remove(sample.keyExpr)`; print
     `[Subscriber] Received DELETE ('keyexpr')`
4. Declare queryable on same key expression (with optional `complete` flag):
   - For each query: iterate store entries, for each entry where
     `queryKeyExpr.intersects(entryKeyExpr)`, reply with the stored
     sample's keyExpr and payload
5. Run until SIGINT
6. Close subscriber, queryable, session

**zenoh-c flag mapping:**
| C flag | Dart flag | Notes |
|--------|-----------|-------|
| `-k`/`--key` | `-k`/`--key` | Default: `demo/example/**` |
| `--complete` | `--complete` | Flag, default off |
| common `-e`/`-l` | `-e`/`--connect`, `-l`/`--listen` | Multi-option |

**Dart simplification over C reference:** The C reference implements a
full hash-map storage with linked lists, mutexes, and manual memory
management (200+ lines of storage code). The Dart version uses
`Map<String, Sample>` (~5 lines). Dart's garbage collector handles cleanup.
No mutex needed — the subscriber and queryable callbacks run on the same
Dart event loop (single-threaded async). This is a key advantage of the
Dart binding.

## Test Plan

### Group 1: KeyExpr.intersects (in `keyexpr_test.dart`)

No network — pure key expression matching.

1. **exact match intersects** — `demo/example/test` intersects `demo/example/test` → true
2. **wildcard intersects** — `demo/**` intersects `demo/example/test` → true
3. **single-level wildcard intersects** — `demo/*/test` intersects `demo/example/test` → true
4. **non-matching does not intersect** — `demo/a` intersects `demo/b` → false
5. **disjoint paths do not intersect** — `demo/example` intersects `other/path` → false

### Group 2: KeyExpr.includes (in `keyexpr_test.dart`)

6. **wildcard includes specific** — `demo/**` includes `demo/example/test` → true
7. **specific does not include wildcard** — `demo/example/test` includes `demo/**` → false
8. **exact includes itself** — `demo/example` includes `demo/example` → true
9. **disjoint does not include** — `demo/a` includes `demo/b` → false

### Group 2b: KeyExpr.equals (in `keyexpr_test.dart`)

10. **identical expressions are equal** — `demo/example` equals `demo/example` → true
11. **different expressions are not equal** — `demo/a` equals `demo/b` → false
12. **wildcard not equal to specific** — `demo/**` equals `demo/example` → false

### Group 3: z_storage CLI Startup (in `z_storage_cli_test.dart`)

TCP ports: **18700-18703**

13. **z_storage starts and prints subscriber/queryable messages** — Start
    z_storage listening on port 18700 → stdout contains `Declaring Subscriber`
    and `Declaring Queryable` (kill after 3s)

14. **z_storage accepts --key flag** — Start z_storage with
    `-k test/storage/** -l tcp/127.0.0.1:18701` → process starts without
    error (kill after 3s)

15. **z_storage accepts --complete flag** — Start z_storage with
    `--complete -l tcp/127.0.0.1:18702` → process starts without error
    (kill after 3s)

### Group 4: z_storage End-to-End Integration (in `z_storage_cli_test.dart`)

TCP ports: **18710-18713**

16. **put then query returns stored value** — Start z_storage on port 18710,
    run z_put with `-k demo/example/key1 -p value1` connecting to same port,
    then run z_get with `-s demo/example/**` connecting to same port →
    z_get stdout contains `value1`

17. **delete removes from storage** — Start z_storage on port 18711, put
    key1 and key2, delete key1, wait for z_storage stdout to show the DELETE
    was processed, then query → z_get returns key2 but not key1

    **Timing note:** The delete event propagates asynchronously via the
    subscriber stream. The test must allow sufficient delay (or check
    z_storage stdout for the DELETE log line) between z_delete and z_get
    to ensure the storage has processed the removal.

18. **query with non-matching key returns nothing** — Start z_storage on
    port 18712, put on `demo/example/key1`, query with `other/**` →
    z_get returns no results (timeout or empty)

## Deferred

- **Persistence** — The storage is in-memory only. Persistent storage
  (file-backed, database) is out of scope.
- **Queryable `complete` option as API parameter** — Already supported
  (`Session.declareQueryable(complete: true)` exists since Phase 6).
  No new API needed.
- **Storage as a reusable class** — The storage is a CLI example, not a
  library class. A reusable `Storage` class could be built on top of
  the primitives but is out of scope for this phase.

## Verification Criteria

1. `fvm dart analyze package` — clean
2. All 455 existing tests still pass (regression)
3. ~18 new tests pass (keyexpr matching + CLI + integration)
4. `z_storage.dart` starts and responds to put/get/delete
5. Key expression wildcard matching works correctly via zenoh-c
6. C shim rebuild required: `cmake --preset linux-x64-shim-only && cmake --build --preset linux-x64-shim-only --target install`

## Reference

| What | Where |
|------|-------|
| Phase spec (original) | `development/phases/phase-17-storage.md` |
| C reference example | `extern/zenoh-c/examples/z_storage.c` |
| C headers (keyexpr matching) | `extern/zenoh-c/include/zenoh_commons.h` lines 3572-3585 |
| Existing KeyExpr | `package/lib/src/keyexpr.dart` |
| Existing Subscriber | `package/lib/src/subscriber.dart` |
| Existing Queryable | `package/lib/src/queryable.dart` |
| Existing z_put | `package/example/z_put.dart` |
| Existing z_get | `package/example/z_get.dart` |
| Existing z_delete | `package/example/z_delete.dart` |
