# Proposal: Product / Workshop Repository Split

**Date:** 2026-03-24
**Author:** CA (Code Architect)
**Status:** Proposal — awaiting human review
**Depends on:** CMake superbuild proposal (must complete first)

---

## Problem

The current `zenoh_dart` repository conflates two concerns:

| Concern | Examples | Consumer |
|---------|----------|----------|
| **Product** | Dart API, C shim, prebuilt libraries, build hooks, examples, tests | GitHub visitors, pub.dev users, Flutter developers, contributors |
| **Workshop** | Phase specs, design docs, experiments, audits, proposals, dev roles, LaTeX papers, 7 submodules | Developer + Claude sessions |

Someone cloning `zenoh_dart` today gets 166MB of CMake source reference, hooks experiments, C shim audit LaTeX, phase specs for completed work, and a monorepo structure wrapping a single package. None of this is needed to build, use, or contribute to the package.

Additionally:
- **Melos is vestigial** — declared as a dev_dependency but no `melos.yaml` exists. With one package and no `zenoh_flutter` planned, Melos adds nothing. Dart Workspaces (`resolution: workspace`) handles dependency resolution natively.
- **The monorepo `packages/zenoh/` indirection is unnecessary** — there's only one package. Every path reference adds `packages/zenoh/` for no structural benefit.

---

## Proposal

Split into two repositories:

### `zenoh_dart` — the product

A flat, single-package repository. Root-level `pubspec.yaml`. `dart pub publish` from root. One submodule (`extern/zenoh-c/`). Clean README focused on usage and building.

### `zenoh_dart_dev` — the workshop

The current repository, renamed. Retains full git history, all development scaffolding, all 7 submodules, all documentation. Continues to serve as the CA/CP/CI/CB workspace for ongoing development.

---

## Product Repository Structure

```
zenoh_dart/                   # Fresh repo — clean git history
  lib/                        # Dart API (from packages/zenoh/lib/)
    zenoh.dart                #   barrel export
    src/
      bindings.dart           #   auto-generated FFI bindings
      native_lib.dart         #   DynamicLibrary.open() loading
      session.dart            #   Session class
      config.dart             #   Config class
      key_expr.dart           #   KeyExpr class
      z_bytes.dart            #   ZBytes class
      publisher.dart          #   Publisher class
      subscriber.dart         #   Subscriber class
      sample.dart             #   Sample, SampleKind
      encoding.dart           #   Encoding class
      congestion_control.dart #   CongestionControl enum
      priority.dart           #   Priority enum
      shm_provider.dart       #   ShmProvider class
      shm_mut_buffer.dart     #   ShmMutBuffer class
      zenoh_id.dart           #   ZenohId class
      what_am_i.dart          #   WhatAmI enum
      hello.dart              #   Hello class
      zenoh_exception.dart    #   ZenohException class
  src/                        # C shim source
    zenoh_dart.h
    zenoh_dart.c
    CMakeLists.txt            # C shim build (refactored for flat layout)
    dart/                     # Dart API DL headers
      dart_api.h
      dart_api_dl.h
      dart_api_dl.c
      dart_native_api.h
  hook/                       # Dart build hooks
    build.dart
  native/                     # Prebuilt shared libraries
    linux/x86_64/
      libzenoh_dart.so
      libzenohc.so
    android/arm64-v8a/
      libzenoh_dart.so
      libzenohc.so
    android/x86_64/
      libzenoh_dart.so
      libzenohc.so
  example/                    # CLI examples
    z_put.dart
    z_delete.dart
    z_sub.dart
    z_pub.dart
    z_pub_shm.dart
    z_info.dart
    z_scout.dart
  test/                       # Integration tests (193 tests)
    session_test.dart
    key_expr_test.dart
    z_bytes_test.dart
    put_test.dart
    subscriber_test.dart
    publisher_test.dart
    shm_provider_test.dart
    info_test.dart
    scout_test.dart
    interprocess_test.dart
  extern/
    zenoh-c/                  # ONLY submodule — pinned at v1.7.2
  scripts/
    build_zenoh_android.sh    # Android cross-compilation
  CMakeLists.txt              # Root superbuild (from superbuild proposal)
  CMakePresets.json           # Platform presets
  pubspec.yaml                # Flat — no workspace, no melos
  ffigen.yaml                 # FFI code generator config
  analysis_options.yaml       # Linting config
  CLAUDE.md                   # Simplified — build, use, contribute
  README.md                   # User-facing — what, why, how
  CHANGELOG.md
  LICENSE                     # Apache 2.0
  .gitignore
  .gitmodules                 # Single entry: extern/zenoh-c
```

**What's NOT in the product repo:**
- `docs/` — phase specs, design docs, reviews, audits, research
- `development/` — proposals
- `experiments/` — hooks bundling experiments
- `.claude/skills/`, `.claude/settings.json` — dev session configuration
- `extern/zenoh-cpp/`, `extern/zenoh-kotlin/`, `extern/zenoh-demos/` — reference submodules
- `extern/cargo-ndk/`, `extern/zenoh/`, `extern/cmake/` — dev tools and reference
- Dev role docs (`docs/dev-roles/`)
- LaTeX source (`docs/c-shim/latex/`)
- Melos dependency
- Workspace indirection (`packages/zenoh/`)

---

## Workshop Repository Structure

```
zenoh_dart_dev/               # Current repo, renamed
  packages/zenoh/             # Original monorepo structure (historical reference)
  src/                        # C shim source (canonical — product repo copies from here)
  extern/                     # All 7 submodules
    zenoh-c/                  #   v1.7.2 — primary dependency
    zenoh-cpp/                #   API design reference
    zenoh-kotlin/             #   Cross-language reference
    zenoh-demos/              #   Demo reference
    cargo-ndk/                #   Android cross-compilation tool
    zenoh/                    #   Rust core (zenohd router)
    cmake/                    #   CMake RTFM reference
  docs/                       # All documentation
    phases/                   #   Phase specifications (source of truth)
    design/                   #   Design documents
    reviews/                  #   Audit documents
    c-shim/                   #   C shim audit + LaTeX
    build/                    #   Build guides
    dev-roles/                #   Session role definitions
    research/                 #   Research notes
  development/                # Proposals
  experiments/                # Hooks bundling experiments
  .claude/                    # Skills, roles, settings
  CLAUDE.md                   # Full development guidance (TDD, phases, conventions)
  README.md                   # Development-focused
  ...full git history...
```

---

## Path Rewrites Required

Flattening from `packages/zenoh/` to root changes path assumptions in several files:

### `ffigen.yaml`

| Field | Current | New |
|-------|---------|-----|
| `entry-points.include` | `../../src/zenoh_dart.h` | `src/zenoh_dart.h` |
| `compiler-opts` | `-I../../extern/zenoh-c/include` | `-Iextern/zenoh-c/include` |
| `output.bindings` | `lib/src/bindings.dart` | `lib/src/bindings.dart` (unchanged) |

### `src/CMakeLists.txt`

| Reference | Current | New |
|-----------|---------|-----|
| `PACKAGE_ROOT` | `"${CMAKE_CURRENT_SOURCE_DIR}/.."` resolves to monorepo root | Same — resolves to product repo root (correct) |
| zenoh-c headers | `${PACKAGE_ROOT}/extern/zenoh-c/include` | Same (unchanged) |
| Android jniLibs | `${PACKAGE_ROOT}/android/src/main/jniLibs/` | Needs new path or removal (see below) |
| Linux prebuilt | `${PACKAGE_ROOT}/native/linux/...` | `${PACKAGE_ROOT}/native/linux/...` (unchanged — `native/` moves up from `packages/zenoh/native/` to root `native/`) |

### `native_lib.dart`

| Logic | Current | New |
|-------|---------|-----|
| Package URI resolution | Resolves `package:zenoh/` → `packages/zenoh/lib/` → walks up to find `native/` | Resolves `package:zenoh/` → `lib/` → walks up to find `native/` at repo root |
| Relative probing | Checks `packages/zenoh/native/linux/x86_64/` | Checks `native/linux/x86_64/` |

This is the most delicate rewrite — the path resolution logic in `_resolveLibraryPath()` must be verified against the new directory structure. The package URI resolution via `Isolate.resolvePackageUriSync()` returns the physical path to `lib/`, and the code walks up to find `native/`. With a flat layout, walking up one level from `lib/` reaches the repo root where `native/` lives. Currently it walks up from `packages/zenoh/lib/` past `packages/zenoh/` to the monorepo root — but `native/` is at `packages/zenoh/native/`, so the code has special handling. The flat layout is actually simpler.

### `hook/build.dart`

| Logic | Current | New |
|-------|---------|-----|
| `_nativeDir()` | Relative to `packages/zenoh/` package root | Relative to repo root (same thing in flat layout) |

The hook runs from the package root. In flat layout, package root = repo root. Paths to `native/` remain the same relative to package root.

### `scripts/build_zenoh_android.sh`

| Variable | Current | New |
|----------|---------|-----|
| `NATIVE_ANDROID_DIR` | `${PROJECT_ROOT}/packages/zenoh/native/android` | `${PROJECT_ROOT}/native/android` |
| `JNILIBS_DIR` | `${PROJECT_ROOT}/android/src/main/jniLibs` | Remove or keep as build intermediate |

### Root `CMakeLists.txt` (superbuild)

| Reference | Current (from superbuild proposal) | New |
|-----------|-----|-----|
| `NATIVE_DIR` | `${CMAKE_CURRENT_SOURCE_DIR}/packages/zenoh/native` | `${CMAKE_CURRENT_SOURCE_DIR}/native` |

### `pubspec.yaml`

| Field | Current | New |
|-------|---------|-----|
| `name` | `zenoh` | `zenoh` (unchanged — this is the Dart package name) |
| `resolution` | `workspace` | Remove (no workspace) |
| Root pubspec | Exists with `workspace:` and `melos` dev_dep | Deleted — single pubspec at root |

---

## Android jniLibs Path

The current layout has `android/src/main/jniLibs/<abi>/` as an intermediate build output for Gradle. In the product repo, this path is only used by:
1. `build_zenoh_android.sh` — as cargo-ndk output directory
2. `src/CMakeLists.txt` — Tier 1 Android discovery

**Decision needed:** Keep `android/src/main/jniLibs/` as a build intermediate, or change cargo-ndk to output directly to `native/android/<abi>/`?

**Recommendation:** Output directly to `native/android/<abi>/`. The jniLibs path was a Gradle convention from when we considered a Flutter plugin structure. With build hooks handling APK placement, jniLibs is unnecessary indirection. The C shim's Tier 1 Android discovery can point to `native/android/<abi>/` instead.

This simplifies the Android flow:
```
cargo-ndk → native/android/<abi>/libzenohc.so     (direct)
cmake     → native/android/<abi>/libzenoh_dart.so  (via install target)
```

No intermediate directory, no copy step between jniLibs and native/.

---

## CLAUDE.md for Product Repo

The product repo gets a focused CLAUDE.md covering only:

1. **Project overview** — What zenoh_dart is (pure Dart FFI, zenoh-c v1.7.2)
2. **Build commands** — cmake presets (Linux, Android), ffigen, dart test
3. **Architecture** — Three-layer FFI (C shim → bindings → Dart API)
4. **Key conventions** — `zd_` prefix, DynamicLibrary.open(), entity lifecycle
5. **API reference** — Available classes with one-line descriptions
6. **CLI examples** — How to run each example
7. **Contributing** — How to add a C shim function, regenerate bindings, run tests

**Not included:**
- TDD workflow plugin docs
- Phase specifications
- Session directives (CA/CP/CI/CB)
- Cross-language parity checklists
- Documentation finalization guide
- Design document references

---

## What Happens to Development Workflow

After the split, the four-session workflow (CA/CP/CI/CB) operates in `zenoh_dart_dev`. When a feature is ready for release:

1. **CI implements and tests** in `zenoh_dart_dev` (monorepo structure)
2. **CI copies changed files** to `zenoh_dart` (flat structure) with path adjustments
3. **CI runs tests** in `zenoh_dart` to verify (193+ tests pass)
4. **CI publishes** from `zenoh_dart`

Alternatively, development could move entirely to `zenoh_dart` (the product repo) and `zenoh_dart_dev` becomes a frozen archive. This depends on whether the workshop scaffolding (CLAUDE.md, phase docs, TDD plugin) can live alongside the clean product structure. Given that `.claude/` and `docs/` can be gitignored or kept in a separate branch, this is feasible.

**Recommendation:** Develop in `zenoh_dart` (product repo) with a minimal development CLAUDE.md. Keep `zenoh_dart_dev` as a frozen archive of the development history. The workshop docs (phase specs, design docs) are historical — future phases can reference them from the archive but don't need them in the active repo.

---

## Risks and Mitigations

| # | Risk | Mitigation |
|---|------|------------|
| 1 | **Path rewrites break native_lib.dart resolution** | This is the highest-risk change. The `_resolveLibraryPath()` function has specific path probing logic. Write a test that verifies library resolution from the new layout before committing. |
| 2 | **ffigen paths break** | Run `fvm dart run ffigen --config ffigen.yaml` after path changes and verify `bindings.dart` regenerates correctly. |
| 3 | **Build hooks can't find native/** | Run `fvm dart test` — hooks fire during test and will fail immediately if paths are wrong. |
| 4 | **Android build script paths wrong** | Run `./scripts/build_zenoh_android.sh --abi arm64-v8a` after changes (requires NDK). |
| 5 | **GitHub repo rename breaks existing clones** | GitHub auto-redirects the old URL. Document the rename in both repos' READMEs. Existing clones need `git remote set-url origin`. |
| 6 | **pub.dev package name conflict** | The Dart package name stays `zenoh` (in pubspec.yaml). The GitHub repo name (`zenoh_dart`) is separate from the package name. No conflict. |
| 7 | **Loss of git blame for moved files** | Fresh repo = no history. Acceptable — `zenoh_dart_dev` retains full history. For any file's provenance, check the dev repo. |
| 8 | **Two repos drift apart** | If development continues in `zenoh_dart_dev`, files must sync to `zenoh_dart`. Mitigated by the recommendation to develop directly in `zenoh_dart` and freeze `zenoh_dart_dev`. |

---

## Execution Sequence

This split depends on the CMake superbuild proposal being completed first. The superbuild changes the same files (CMakeLists.txt, paths, build scripts), and doing both simultaneously doubles the path-rewriting work.

1. **Complete CMake superbuild** in current repo — root CMakeLists.txt, presets, dual-mode src/CMakeLists.txt
2. **Verify** 193 tests pass with new build system
3. **Rename** current GitHub repo from `zenoh_dart` to `zenoh_dart_dev`
4. **Create** fresh `zenoh_dart` repo on GitHub
5. **Copy files** from `zenoh_dart_dev` to `zenoh_dart` with flat structure
6. **Rewrite paths** — ffigen.yaml, native_lib.dart, CMakeLists.txt, hook/build.dart, build_zenoh_android.sh, pubspec.yaml
7. **Remove jniLibs intermediate** — cargo-ndk outputs directly to `native/android/<abi>/`
8. **Drop Melos** — remove workspace pubspec, use flat single-package pubspec
9. **Write product CLAUDE.md** — focused on build/use/contribute
10. **Write product README.md** — user-facing, clean
11. **Verify** 193 tests pass in `zenoh_dart`
12. **Update memory** — new repo locations, updated project structure
13. **Freeze `zenoh_dart_dev`** — add prominent README note pointing to `zenoh_dart`
