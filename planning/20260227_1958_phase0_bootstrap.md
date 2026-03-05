# Planning Archive: Phase 0 -- Bootstrap (Infrastructure)

**Planned:** 2026-02-27T19:58:00Z
**Approved:** 2026-02-27
**Phase:** 0
**Slices:** 5
**Total Tests:** 33

---

## Overview

Phase 0 establishes the foundation for the entire zenoh-dart project: build
system wiring (CMakeLists.txt linking libzenohc.so with three-tier discovery),
C shim functions for session/config/keyexpr/bytes management, ffigen-generated
Dart FFI bindings, and an idiomatic Dart API layer with Config, Session,
KeyExpr, ZBytes, and ZenohException classes. This is the first phase -- no CLI
examples, no pub/sub, no queryables -- just the infrastructure every subsequent
phase depends on. The plan covers 5 slices with 33 tests total, incorporating
15 API corrections discovered by comparing the phase doc against the actual
zenoh-c v1.7.2 headers and a validated working prototype.

---

## Research Summary

### Codebase State at Planning Time

- **Commit:** 0d7f532 (feat: scaffold zenoh-dart monorepo with pure Dart zenoh package)
- **Existing test files:** 1 (`packages/zenoh/test/zenoh_test.dart` -- scaffold placeholder)
- **Test framework:** `test: ^1.25.0` (Dart)
- **FFI binding generator:** `ffigen: ^20.1.1`
- **Dart SDK:** ^3.11.0
- **zenoh-c version:** v1.7.2 (submodule at `extern/zenoh-c/`)

### Files Examined

- `docs/phases/phase-00-bootstrap.md` -- phase specification (source of truth)
- `src/zenoh_dart.h` -- empty C shim header (FFI_PLUGIN_EXPORT macro only)
- `src/zenoh_dart.c` -- empty C shim implementation
- `src/CMakeLists.txt` -- minimal build, no zenoh-c linking
- `packages/zenoh/pubspec.yaml` -- pure Dart FFI package
- `packages/zenoh/ffigen.yaml` -- points at shim header, filters on `zd_.*`
- `packages/zenoh/lib/zenoh.dart` -- empty barrel export
- `packages/zenoh/lib/src/native_lib.dart` -- DynamicLibrary loader
- `packages/zenoh/lib/src/bindings.dart` -- auto-generated (empty)
- `packages/zenoh/analysis_options.yaml` -- excludes bindings.dart from analysis

### zenoh-c Reference Tests Consulted

- `extern/zenoh-c/tests/z_api_session_test.c` -- open/close/drop patterns
- `extern/zenoh-c/tests/z_api_config_test.c` -- JSON5 insert/get
- `extern/zenoh-c/tests/z_api_keyexpr_test.c` -- view creation, string extraction, canonization
- `extern/zenoh-c/tests/z_api_payload_test.c` -- bytes creation, conversion, reader/writer
- `extern/zenoh-c/tests/z_api_double_drop_test.c` -- double-drop safety for all owned types
- `extern/zenoh-c/tests/z_api_null_drop_test.c` -- null/gravestone safety
- `extern/zenoh-c/tests/z_api_keyexpr_drop_test.c` -- keyexpr lifetime in publishers/subscribers
- `extern/zenoh-c/examples/z_put.c` -- end-to-end session/keyexpr/bytes usage
- `extern/zenoh-cpp/tests/universal/network/keyexpr.cxx` -- C++ binding keyexpr patterns

### Working Prototype

A validated working prototype at `/tmp/zenoh_cmake_test/src/` was consulted for:
- Correct CMakeLists.txt with three-tier zenohc discovery
- Dart SDK header layout in `src/dart/`
- C shim function signatures matching actual zenoh-c v1.7.2 API
- Session close pattern (z_close then z_session_drop)
- Config mutable loan pattern (z_config_loan_mut for insert)

---

## Critical API Discrepancies Found (vs Phase Doc)

15 corrections were identified between the phase doc and the actual zenoh-c
v1.7.2 API. All corrections are documented in `.tdd-progress.md` under
"Critical API Corrections Applied" (items 1-15). Key corrections:

1. `zd_config_insert_json5` takes mutable `z_owned_config_t*`, not `const z_loaned_config_t*`
2. `zd_keyexpr_as_view_string` returns void, not int
3. Bytes creation functions return int (z_result_t), not void
4. `zd_close_session` must graceful-close (z_close) before drop
5. `z_view_string_data`/`z_view_string_len` do not exist -- must compose via z_view_string_loan
6. `zd_bytes_from_static_str` dropped (unsafe from Dart FFI)
7. `zd_string_loan` added (required for owned string access)
8. KeyExpr requires dispose() to free Dart-side native allocations
9. Config needs _consumed flag set by Session.open

---

## Slice Decomposition Rationale

| Slice | Name | Tests | Rationale |
|-------|------|-------|-----------|
| 1 | Build system, ffigen, native lib, ZenohException | 5 | Foundation: must work before anything else can compile |
| 2 | Config lifecycle | 5 | Config is needed by Session; self-contained type |
| 3 | Session open/close | 6 | Depends on Config; proves full FFI stack works end-to-end |
| 4 | KeyExpr round-trip | 8 | Independent of Session/Config for creation; adds dispose for memory safety |
| 5 | ZBytes round-trip + barrel | 9 | Independent of Session; finalizes public API surface |

Slices 4 and 5 depend only on Slice 1 (build system + native lib). They can be
implemented in either order after Slice 1. Slice 3 depends on both Slices 1 and
2. This creates a partial ordering: 1 -> {2, 4, 5}, 2 -> 3.

---

## Decisions Made During Planning

1. **Dropped `zd_bytes_from_static_str`**: Dart FFI cannot guarantee static
   lifetime for strings. The `toNativeUtf8()` allocation is on the native heap
   and can be freed at any time. Using `zd_bytes_copy_from_str` (which copies)
   is always safe.

2. **Added `zd_string_loan`**: Not in the phase doc but required because
   `z_string_data`/`z_string_len` take `z_loaned_string_t*`, not
   `z_owned_string_t*`. The bridge function is needed.

3. **KeyExpr gets dispose()**: Even though `z_view_keyexpr_t` does not own
   zenoh memory, the Dart wrapper allocates native memory
   (`calloc<z_view_keyexpr_t>()` and `toNativeUtf8()`) that must be freed.

4. **Config gets _consumed flag**: `Session.open(config: config)` consumes the
   config via `z_config_move`. The Dart wrapper must prevent reuse of the
   consumed Config object.

5. **No invalid-config session test**: In peer mode, `z_open` succeeds even
   with unusual config values. A client-mode test with invalid endpoints would
   hang/timeout. Not suitable for unit tests.

6. **zd_init_dart_api_dl returns intptr_t**: Matches `Dart_InitializeApiDL`
   return type exactly. In Dart FFI, `intptr_t` maps to `int`.

---

## CA Review Feedback Applied

Two issues were identified by the CA (read-only advisor) and incorporated:

1. **[CRITICAL] KeyExpr memory management**: Added `dispose()` to KeyExpr with
   dual-pointer cleanup (`_kePtr` and `_nativeStr`), `_disposed` flag,
   `_ensureNotDisposed()` guard, and construction-failure cleanup. Added 2 tests
   (Tests 7 & 8 in Slice 4).

2. **[SUGGESTION] Consumed Config test**: Added Test 6 to Slice 3 verifying
   that a consumed Config throws `StateError` on reuse. Added `_consumed` flag
   and `_ensureNotConsumed()` guard to Config implementation requirements.

---

## File Inventory

### Source Files (18)
- `src/CMakeLists.txt` (update)
- `src/zenoh_dart.h` (update)
- `src/zenoh_dart.c` (update)
- `src/dart/dart_api_dl.c` (new)
- `src/dart/dart_api_dl.h` (new)
- `src/dart/dart_api.h` (new)
- `src/dart/dart_native_api.h` (new)
- `src/dart/dart_version.h` (new)
- `src/dart/internal/dart_api_dl_impl.h` (new)
- `packages/zenoh/ffigen.yaml` (update)
- `packages/zenoh/lib/zenoh.dart` (update)
- `packages/zenoh/lib/src/bindings.dart` (regenerated)
- `packages/zenoh/lib/src/native_lib.dart` (update)
- `packages/zenoh/lib/src/exceptions.dart` (new)
- `packages/zenoh/lib/src/config.dart` (new)
- `packages/zenoh/lib/src/session.dart` (new)
- `packages/zenoh/lib/src/keyexpr.dart` (new)
- `packages/zenoh/lib/src/bytes.dart` (new)

### Test Files (6)
- `packages/zenoh/test/native_lib_test.dart` (new)
- `packages/zenoh/test/config_test.dart` (new)
- `packages/zenoh/test/session_test.dart` (new)
- `packages/zenoh/test/keyexpr_test.dart` (new)
- `packages/zenoh/test/bytes_test.dart` (new)
- `packages/zenoh/test/zenoh_test.dart` (delete)

### Commit Convention
- Slice 1: `test(native-lib): ...` / `feat(native-lib): ...`
- Slice 2: `test(config): ...` / `feat(config): ...`
- Slice 3: `test(session): ...` / `feat(session): ...`
- Slice 4: `test(keyexpr): ...` / `feat(keyexpr): ...`
- Slice 5: `test(bytes): ...` / `feat(bytes): ...`
