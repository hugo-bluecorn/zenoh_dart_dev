# Proposal: Product / Workshop Repository Split

**Date:** 2026-03-24 (revised 2026-03-24, pass 3)
**Author:** CA (Code Architect)
**Reviewed by:** CA2 (independent review session)
**Status:** Proposal — awaiting human review
**Recommended sequence:** Complete CMake superbuild first (avoids double path-rewriting), but not a hard dependency — the split works with the existing standalone build system if the superbuild is deferred.

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
- **The monorepo `package/` indirection is unnecessary** — there's only one package. Every path reference adds `package/` for no structural benefit.

---

## Proposal

Split into two repositories:

### `zenoh_dart` — the product

A single-package repository with structural publish safety. The Dart package lives in `package/` — `dart pub publish` runs from there and only publishes what's inside. Build infrastructure (CMake, C shim source, submodules, scripts) lives at the repo root, outside the publish boundary. No `.pubignore` needed.

### `zenoh_dart_dev` — the workshop

The current repository, renamed. Retains full git history, all development scaffolding, all 7 submodules, all documentation. Frozen as a historical archive.

---

## Why `package/` Instead of Flat Root

An earlier draft proposed a flat layout with all Dart files at the repo root. This requires `.pubignore` to exclude build infrastructure (`src/`, `extern/`, `scripts/`, `CMakeLists.txt`, etc.) from `dart pub publish`. `.pubignore` is a **deny-list** — you must remember to exclude every new file. Forgetting means accidental publish of build artifacts.

The `package/` layout is an **allow-list** — only what's inside `package/` gets published. The boundary is structural, not a filter file.

| Approach | Publish safety | Maintenance burden |
|----------|---------------|-------------------|
| Flat root + `.pubignore` | Deny-list — must exclude every new build file | Must update `.pubignore` whenever adding build infrastructure |
| `package/` directory | Allow-list — only `package/` contents published | Zero maintenance — new build files at root are automatically excluded |

Compared to current `package/`:
- `package/` (singular) is honest about there being one package
- One level of indirection instead of two (`../src/` vs `../../src/`)
- No workspace, no Melos

---

## Product Repository Structure

```
zenoh_dart/                     # Fresh repo — clean git history
  package/                      # PUBLISH BOUNDARY — dart pub publish runs here
    lib/                        #   Dart API
      zenoh.dart                #     barrel export
      src/
        bindings.dart           #     auto-generated FFI bindings
        native_lib.dart         #     DynamicLibrary.open() loading
        session.dart            #     Session class
        config.dart             #     Config class
        key_expr.dart           #     KeyExpr class
        z_bytes.dart            #     ZBytes class
        publisher.dart          #     Publisher class
        subscriber.dart         #     Subscriber class
        sample.dart             #     Sample, SampleKind
        encoding.dart           #     Encoding class
        congestion_control.dart #     CongestionControl enum
        priority.dart           #     Priority enum
        shm_provider.dart       #     ShmProvider class
        shm_mut_buffer.dart     #     ShmMutBuffer class
        zenoh_id.dart           #     ZenohId class
        what_am_i.dart          #     WhatAmI enum
        hello.dart              #     Hello class
        zenoh_exception.dart    #     ZenohException class
    hook/                       #   Dart build hooks
      build.dart
    native/                     #   Prebuilt shared libraries
      linux/x86_64/
        libzenoh_dart.so
        libzenohc.so
      android/arm64-v8a/
        libzenoh_dart.so
        libzenohc.so
      android/x86_64/
        libzenoh_dart.so
        libzenohc.so
    example/                    #   CLI examples
      z_put.dart
      z_delete.dart
      z_sub.dart
      z_pub.dart
      z_pub_shm.dart
      z_info.dart
      z_scout.dart
    test/                       #   Integration tests (193 tests)
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
    pubspec.yaml                #   Package manifest — no workspace, no melos
    ffigen.yaml                 #   FFI code generator config
    analysis_options.yaml       #   Linting config
    README.md                   #   User-facing — what, why, how
    CHANGELOG.md
    LICENSE                     #   Apache 2.0
  src/                          # C shim source (OUTSIDE publish boundary)
    zenoh_dart.h
    zenoh_dart.c
    CMakeLists.txt              #   C shim build
    dart/                       #   Dart API DL headers
      dart_api.h
      dart_api_dl.h
      dart_api_dl.c
      dart_native_api.h
  extern/
    zenoh-c/                    # ONLY submodule — pinned at v1.7.2
  scripts/
    build_zenoh_android.sh      # Android cross-compilation
  CMakeLists.txt                # Root superbuild (from superbuild proposal)
  CMakePresets.json             # Platform presets
  CLAUDE.md                     # Simplified — build, use, contribute
  README.md                     # Repo-level — layout, building, points to package/README.md
  .gitignore
  .gitmodules                   # Single entry: extern/zenoh-c
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
- `.pubignore` — not needed, publish boundary is structural

---

## Workshop Repository Structure

```
zenoh_dart_dev/               # Current repo, renamed — frozen archive
  package/             # Original monorepo structure (historical reference)
  src/                        # C shim source (canonical copy)
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
  README.md                   # Points to zenoh_dart as the active repo
  ...full git history...
```

---

## Path Rewrites Required

The `package/` layout changes path references from `package/` (two levels) to `package/` (one level). Paths from `package/` to repo-root resources use `../` instead of `../../`.

### `ffigen.yaml` (inside `package/`)

| Field | Current | New |
|-------|---------|-----|
| `entry-points.include` | `../../src/zenoh_dart.h` | `../src/zenoh_dart.h` |
| `compiler-opts` | `-I../../extern/zenoh-c/include` | `-I../extern/zenoh-c/include` |
| `output.bindings` | `lib/src/bindings.dart` | `lib/src/bindings.dart` (unchanged) |

### `src/CMakeLists.txt`

| Reference | Current | New |
|-----------|---------|-----|
| `PACKAGE_ROOT` | `"${CMAKE_CURRENT_SOURCE_DIR}/.."` → monorepo root | `"${CMAKE_CURRENT_SOURCE_DIR}/.."` → product repo root (same semantics) |
| zenoh-c headers | `${PACKAGE_ROOT}/extern/zenoh-c/include` | Same (unchanged) |
| Android discovery | `${PACKAGE_ROOT}/android/src/main/jniLibs/` | `${PACKAGE_ROOT}/package/native/android/${ANDROID_ABI}/` (direct, no jniLibs) |
| Linux prebuilt | `${PACKAGE_ROOT}/native/linux/...` | `${PACKAGE_ROOT}/package/native/linux/...` |
| Developer fallback | `${PACKAGE_ROOT}/extern/zenoh-c/target/release/` | Same (unchanged) |

Note: prebuilt discovery paths now include `package/` because `native/` lives inside the publish boundary (it ships with the package).

### `native_lib.dart` (inside `package/lib/src/`)

| Logic | Current | New |
|-------|---------|-----|
| Package URI resolution | `package:zenoh/` → `package/lib/` → walks up to `package/` → finds `native/` | `package:zenoh/` → `package/lib/` → walks up to `package/` → finds `native/` |
| Relative probing | Checks `package/native/linux/x86_64/` | Checks `package/native/linux/x86_64/` (but from inside `package/`, just `native/linux/x86_64/` relative) |

The path resolution is actually simpler. `Isolate.resolvePackageUriSync('package:zenoh/')` returns the physical path to `package/lib/`. Walking up one directory reaches `package/` where `native/` lives. Currently the code walks up from `package/lib/` to `package/` — same depth, cleaner name.

**Dead code cleanup:** The CWD fallback candidates list (current `native_lib.dart` lines ~57-62) includes monorepo-specific paths:
```dart
'package/native/linux/x86_64/$libraryName',     // ← remove
'package/.dart_tool/lib/$libraryName',           // ← remove
```
These are harmless (won't match in the product repo) but contradict the purpose of the split. Remove them during the path rewrite step.

### `hook/build.dart` (inside `package/hook/`)

| Logic | Current | New |
|-------|---------|-----|
| `_nativeDir()` | Relative to `package/` package root | Relative to `package/` (package root = `package/` in new layout) |

The hook runs from the package root. In the new layout, package root = `package/`. Paths to `native/` remain the same relative to package root.

### `scripts/build_zenoh_android.sh`

| Variable | Current | New |
|----------|---------|-----|
| `NATIVE_ANDROID_DIR` | `${PROJECT_ROOT}/package/native/android` | `${PROJECT_ROOT}/package/native/android` |
| `JNILIBS_DIR` | `${PROJECT_ROOT}/android/src/main/jniLibs` | Removed — cargo-ndk outputs directly to `native/android/<abi>/` |

### Root `CMakeLists.txt` (superbuild)

| Reference | Current (from superbuild proposal) | New |
|-----------|-----|-----|
| `NATIVE_DIR` | `${CMAKE_CURRENT_SOURCE_DIR}/package/native` | `${CMAKE_CURRENT_SOURCE_DIR}/package/native` |

### `pubspec.yaml` (inside `package/`)

| Field | Current | New |
|-------|---------|-----|
| `name` | `zenoh` | `zenoh` (unchanged — Dart package name) |
| `resolution` | `workspace` | Remove (no workspace) |
| Root pubspec | Exists with `workspace:` and `melos` dev_dep | Deleted — only `package/pubspec.yaml` exists |

---

## Android jniLibs Path

The current layout has `android/src/main/jniLibs/<abi>/` as an intermediate build output for Gradle. In the product repo, this path is only used by:
1. `build_zenoh_android.sh` — as cargo-ndk output directory
2. `src/CMakeLists.txt` — Tier 1 Android discovery

**Decision: Eliminate the intermediate.** The jniLibs path was a Gradle convention from when we considered a Flutter plugin structure. With build hooks handling APK placement, jniLibs is unnecessary indirection.

New Android flow:
```
cargo-ndk → package/native/android/<abi>/libzenohc.so     (direct)
cmake     → package/native/android/<abi>/libzenoh_dart.so  (via install target)
```

No intermediate directory, no copy step. The C shim's Android discovery tier points directly to `package/native/android/<abi>/`.

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

After the split, `zenoh_dart_dev` is frozen as a historical archive. Active development moves to `zenoh_dart`.

The four-session workflow (CA/CP/CI/CB) adapts to the product repo:
- **CLAUDE.md** stays focused on build/use/contribute
- **`.claude/`** directory can hold dev session configuration (gitignored, not in `package/`, never published)
- **Phase docs** live in the developer's memory or in `.claude/` — not in the repo tree
- **TDD plugin** works from any repo — it reads `.tdd-progress.md` at the project root

The workshop scaffolding that made `zenoh_dart_dev` heavy was mostly historical documentation (completed phases, design docs, experiments, audits). Future phases don't need those files in the working tree — they're reference material accessible in the archived dev repo.

---

## Risks and Mitigations

| # | Risk | Mitigation |
|---|------|------------|
| 1 | **Path rewrites break native_lib.dart resolution** | Highest-risk change. The `_resolveLibraryPath()` function probes specific paths. Write a test that verifies library resolution from the new layout before committing. The `package/` layout is actually simpler (one level up from `lib/` to `package/` where `native/` lives). |
| 2 | **ffigen paths break** | Run `cd package && fvm dart run ffigen --config ffigen.yaml` after path changes and verify `bindings.dart` regenerates correctly. |
| 3 | **Build hooks can't find native/** | Run `cd package && fvm dart test` — hooks fire during test and will fail immediately if paths are wrong. |
| 4 | **Android build script paths wrong** | Run `./scripts/build_zenoh_android.sh --abi arm64-v8a` after changes (requires NDK). |
| 5 | **GitHub repo rename breaks existing clones** | GitHub auto-redirects the old URL. Document the rename in both repos' READMEs. Existing clones need `git remote set-url origin`. |
| 6 | **pub.dev package name conflict** | The Dart package name stays `zenoh` (in pubspec.yaml). The GitHub repo name (`zenoh_dart`) is separate from the package name. No conflict. |
| 7 | **Loss of git blame for moved files** | Fresh repo = no history. Acceptable — `zenoh_dart_dev` retains full history. For any file's provenance, check the dev repo. |
| 8 | **`cd package` required for Dart commands** | All `fvm dart test`, `fvm dart run`, `fvm dart analyze` must run from `package/`. Minor ergonomic cost. Can alias in shell or document clearly. Same pattern as current `cd package`. |
| 9 | **CMake install target must know about `package/`** | The superbuild's install target uses `NATIVE_DIR = .../package/native`. If someone uses `cmake --target install` without the superbuild, the path won't match. Mitigated by always using presets. |

---

## Execution Sequence

**Recommended:** Complete the CMake superbuild proposal first — it changes the same files (CMakeLists.txt, paths, build scripts), and doing both simultaneously doubles the path-rewriting work. However, this is a scheduling preference, not a hard dependency. If the superbuild spike fails (`add_subdirectory(extern/zenoh-c)` doesn't work) or is deferred, the split proceeds with the existing standalone build system — `src/CMakeLists.txt` paths get updated for the `package/` layout and the 3-tier discovery continues to work.

1. **Complete CMake superbuild** in current repo — root CMakeLists.txt, presets, dual-mode src/CMakeLists.txt
2. **Verify** 193 tests pass with new build system
3. **Rename** current GitHub repo from `zenoh_dart` to `zenoh_dart_dev`
4. **Create** fresh `zenoh_dart` repo on GitHub
5. **Create `package/` directory** — copy Dart package files from `zenoh_dart_dev/package/`
6. **Copy build infrastructure** — `src/`, `scripts/`, `CMakeLists.txt`, `CMakePresets.json` to repo root
7. **Add `extern/zenoh-c`** as single submodule
8. **Rewrite paths** — ffigen.yaml (`../` instead of `../../`), native_lib.dart, src/CMakeLists.txt (prebuilt discovery adds `package/`), hook/build.dart, build_zenoh_android.sh
9. **Eliminate jniLibs intermediate** — cargo-ndk outputs directly to `package/native/android/<abi>/`
10. **Drop Melos** — single `package/pubspec.yaml`, no workspace, no root pubspec
11. **Write product CLAUDE.md** — focused on build/use/contribute
12. **Write product README.md** — user-facing, clean
13. **Verify** 193 tests pass in `zenoh_dart` (run from `package/`)
14. **Update memory** — new repo locations, updated project structure
15. **Freeze `zenoh_dart_dev`** — add prominent README note pointing to `zenoh_dart`
