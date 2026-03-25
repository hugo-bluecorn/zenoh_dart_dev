# Hooks Experiment Progress

**Date**: 2026-03-10
**Execution model**: Sequential single-cohort (A1→A2→B1→B2). One CP plans, one CI implements. Each experiment gets its own branch + PR via /tdd-release targeting main.
**Git model**: Plain branches, no worktrees. Branch names in each spec header. CI creates branches via /tdd-release.

## Experiment Status

| Exp | Package | Spec | Impl | Branch | PR | Result |
|-----|---------|------|------|--------|----|--------|
| A1 | `exp_hooks_prebuilt_dlopen` | DONE | DONE | merged | PR #13 | **NEGATIVE** — DynamicLibrary.open() incompatible with hooks |
| A2 | `exp_hooks_prebuilt_native` | DONE | DONE | merged | PR #14 | **POSITIVE** — @Native + @DefaultAsset works, no LD_LIBRARY_PATH needed |
| B1 | `exp_hooks_cbuilder_dlopen` | DONE | DONE | merged | PR #15 | **NEGATIVE** — DynamicLibrary.open() fails regardless of build strategy |
| B2 | `exp_hooks_cbuilder_native` | DONE | DONE | merged | PR #16 | **POSITIVE** — CBuilder + @Native works, no LD_LIBRARY_PATH needed |

## Consumer Test (methodology verification)

**Spec**: `experiments/hooks-bundling/spec-consumer-test.md` (pushed to main, 8c57f9d)
**Status**: DONE — PASS. PR #17 merged.
**Purpose**: Prove A2's hooks mechanism works when consumed as a **dependency** from an external `dart create` project (not just within-package tests). Closes the methodology gap — experiments A1-B2 only tested from within each package.
**Approach**: `fvm dart create -t console consumer_test` → add path dep on `exp_hooks_prebuilt_native` → run without LD_LIBRARY_PATH.
**Branch**: `experiment/consumer-test`
**Only tests A2**: @Native is the sole determinant (proven by 2x2 matrix), so one consumer test suffices.

## A2 Results (2026-03-10)

**Key finding**: `@Native` + `@DefaultAsset` with prebuilt libs + build hooks **works correctly**. Both `dart test` and `dart run` resolve without LD_LIBRARY_PATH.

**All 6 criteria**: Hook build PASS, libs bundled PASS, @Native resolves PASS, DT_NEEDED PASS (RUNPATH=$ORIGIN), dart test PASS (9/9), dart run PASS.

**Important gotchas discovered**:
- CodeAsset `name` must use **bare relative paths** (e.g., `src/bindings.dart`), NOT full `package:` URIs. Constructor auto-prefixes `package:<pkgName>/`.
- RUNPATH must be patched to `$ORIGIN` via patchelf before bundling prebuilt .so files.
- Post-test SEGV during VM teardown is cosmetic (zenoh cleanup ordering), all tests pass before it.
- Two CodeAsset entries required even though only one has @Native symbols (libzenohc.so needed for DT_NEEDED).

**Migration path clear**: packages/zenoh/ needs @Native in bindings.dart (ffigen supports this), hook/build.dart, and patchelf'd prebuilts.

## A1 Results (2026-03-10)

**Key finding**: `DynamicLibrary.open('libzenoh_dart.so')` does NOT find hook-bundled assets. The hook runs and registers metadata in `.dart_tool/hooks_runner/`, but `DynamicLibrary.open()` delegates to ld.so which doesn't read hook metadata. Only `@Native` annotation resolution reads it.

**Verification criteria**:
1. Hook build succeeds: **PASS**
2. Native libs bundled: **PARTIAL** (metadata only, no copy to linker-visible dir)
3. DynamicLibrary.open() finds libs: **FAIL** — `cannot open shared object file: No such file or directory`
4. FFI calls work: **FAIL** (blocked by #3; works with LD_LIBRARY_PATH)
5. dart test finds libs: **FAIL** (5 smoke tests skipped, 2 scaffold pass)
6. dart run finds libs: **FAIL** (same error)

**Unexpected findings**:
- RUNPATH in prebuilt libzenoh_dart.so has absolute build-machine path (not $ORIGIN). Need `patchelf --set-rpath '$ORIGIN'` for A2.
- Hook metadata records source paths, not output paths (no copy/symlink step).
- Build hooks run twice per invocation (cosmetic).

**Recommendations for A2**: Use `@Native` + `@DefaultAsset` annotations. Fix RPATH before bundling. Test DT_NEEDED resolution when @Native loads the primary lib.

## Key Inputs for All Specs

### Prebuilt library locations (already built)
- `libzenohc.so`: `extern/zenoh-c/target/release/libzenohc.so`
- `libzenoh_dart.so`: `build/libzenoh_dart.so`

### Monorepo workspace
- Root `pubspec.yaml` uses `workspace: [packages/*]` — new packages auto-discovered
- Each package needs `resolution: workspace` in its pubspec.yaml

### Minimal FFI proof of concept
- Each package calls `zd_init_dart_api_dl()` — simplest function, proves both libs loaded
- Also calls `zd_init_log("error")` — proves a function that calls into libzenohc.so works (validates DT_NEEDED)

### What varies per spec

| Dimension | A1/A2 (prebuilt) | B1/B2 (CBuilder) |
|-----------|-------------------|-------------------|
| hook/build.dart | Two CodeAsset(DynamicLoadingBundled) | CBuilder.library() + one CodeAsset |
| Dependencies | hooks, code_assets | hooks, code_assets, native_toolchain_c |
| Prebuilt dir | `native/linux/x86_64/` with both .so | `native/linux/x86_64/` with libzenohc.so only |
| C source | Not needed | Must include src/zenoh_dart.c + headers |

| Dimension | A1/B1 (dlopen) | A2/B2 (@Native) |
|-----------|-----------------|-------------------|
| Dart loading | `DynamicLibrary.open('libzenoh_dart.so')` | `@Native` annotations + `@DefaultAsset` |
| bindings.dart | ffigen-generated with DynamicLibrary ctor | ffigen-generated with @Native output |
| CodeAsset name | arbitrary (lib not resolved by asset ID) | must match Dart library URI |

### Verification criteria (same for all 4)
1. `fvm dart run` finds bundled libs (no LD_LIBRARY_PATH)
2. `fvm dart test` finds bundled libs (no LD_LIBRARY_PATH)
3. `fvm flutter run` finds bundled libs (test Flutter app)
4. DT_NEEDED dependency resolves (zd_init_log calls into libzenohc.so)
5. Hook build succeeds on Linux x86_64
6. Error reporting when something fails

### Current code reference
- `packages/zenoh/lib/src/native_lib.dart` — current DynamicLibrary.open() pattern
- `packages/zenoh/pubspec.yaml` — current deps (no hooks)
- `src/zenoh_dart.h` — C shim header (zd_init_dart_api_dl, zd_init_log)
- Root `pubspec.yaml` — workspace config with `packages/*` glob
