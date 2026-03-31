# Planning Archive: Phase 11 — Liveliness

**Feature:** Liveliness tokens, subscribers, and queries — `LivelinessToken`, `Session.declareLivelinessToken`, `Session.declareLivelinessSubscriber`, `Session.livelinessGet`, 3 CLI examples
**Approved:** 2026-03-26T08:49:27Z
**Iterations:** 1 (approved on first pass with CA suggestions applied)

## Overview

Phase 11 adds the liveliness subsystem for zenoh-dart. Liveliness tokens announce entity presence; liveliness subscribers observe appearance (PUT) and disappearance (DELETE); liveliness queries discover currently alive tokens. The implementation heavily reuses existing infrastructure — all C callbacks from Phases 2 and 6 are reused, and the liveliness subscriber returns the existing `Subscriber` class.

## CA Review Notes (applied before writing)

1. **Slice 5 dependency corrected** — `z_liveliness.dart` only needs token (Slice 1), not subscriber/history
2. **Full Given/When/Then** — Added to all test specs (planner had them, initial summary abbreviated)
3. **Acceptance criteria** — Added per-slice checkboxes
4. **Invalid keyexpr test for livelinessGet** — Added as Slice 4 Test 6 (spec gap corrected)

## Plan Summary

- **7 slices**, ~30 new tests (310 → ~340 total)
- **5 new C shim functions** (83 → 88 total)
- **1 new Dart source file** (`liveliness.dart`), 1 modified (`session.dart`)
- **3 new CLI examples** (`z_liveliness.dart`, `z_sub_liveliness.dart`, `z_get_liveliness.dart`)

### Slice Breakdown

| Slice | Description | C Functions | Tests | TCP Port |
|-------|-------------|-------------|-------|----------|
| 1 | Token Lifecycle | 3 | 6 | -- |
| 2 | Subscriber PUT/DELETE | 1 | 7 | 17500 |
| 3 | Subscriber History | 0 | 2 | 17501 |
| 4 | Liveliness Get | 1 | 6 | 17502 |
| 5 | CLI z_liveliness.dart | 0 | 3 | -- |
| 6 | CLI z_sub_liveliness.dart | 0 | 3 | -- |
| 7 | CLI z_get_liveliness.dart | 0 | 3 | -- |

### Key Design Decisions

- **Flat Session methods** — not a `Liveliness` accessor class
- **Reuse all existing callbacks** — sample callbacks for subscriber, reply callbacks for get
- **Reuse `Subscriber` class** — liveliness subscriber returns same type as regular subscriber
- **LivelinessToken keyExpr stored Dart-side** — no zenoh-c accessor function exists
- **NULL options for token** — `z_liveliness_token_options_t` has only `_dummy` field

### Deferred
- `z_liveliness_get_options_t.cancellation_token` (unstable API)
- `z_liveliness_declare_background_subscriber` (not exposed for regular subscriber either)
