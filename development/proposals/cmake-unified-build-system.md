# Build System Analysis & Proposal: Unified CMake Superbuild

**Date:** 2026-03-24 (revised 2026-03-24, pass 3)
**Author:** CA (Code Architect)
**Reviewed by:** CA2 (independent review session)
**Status:** Proposal — awaiting human review

---

## Diagnosis: Current State

The build today is a **5-step manual pipeline** with no unified entry point:

| Step | Command | Where documented |
|------|---------|-----------------|
| 1. Build zenoh-c | `cmake -S extern/zenoh-c -B ... && RUSTUP_TOOLCHAIN=stable cmake --build ...` | CLAUDE.md |
| 2. Build C shim | `cmake -S src -B build && cmake --build build` | CLAUDE.md |
| 3. Copy prebuilts | `mkdir -p ... && cp ... && cp ...` | CLAUDE.md |
| 4. Patch RPATH | `patchelf --set-rpath '$ORIGIN' ...` | CLAUDE.md |
| 5. Run tests | `cd packages/zenoh && fvm dart test` | CLAUDE.md |

For Android, steps 1-4 are collapsed into `build_zenoh_android.sh`, but that script is disconnected from the Linux flow — different discovery paths, different output locations, separate CMake invocations.

**Root cause**: There is no root `CMakeLists.txt`. The only CMake file is `src/CMakeLists.txt`, which builds the C shim against a *pre-existing* `libzenohc.so` it discovers via a 3-tier search. zenoh-c is treated as an external artifact, not a build dependency.

---

## Finding: `extern/cmake` is the CMake Source Repo

The `extern/cmake` submodule is **the CMake project source code itself** — 166MB, ~30,000 files, checked out from `gitlab.kitware.com/cmake/cmake.git` at v4.3.0-dev. It is NOT a cmake module library or toolchain collection.

**Decision: KEEP.** It serves as a local CMake reference manual — agents can RTFM directly from `extern/cmake/Modules/`, `extern/cmake/Help/`, and platform files without burning internet bandwidth on web fetches. Particularly valuable for cross-compilation module details (`Modules/Platform/Android*.cmake`), toolchain file patterns, and FindXXX module internals.

It is not used in the build pipeline itself — developers use a system-installed `cmake` binary.

---

## Key Insight from zenoh-c

zenoh-c's `CMakeLists.txt` (353 lines) has first-class **subdirectory support**:

```cmake
# Line 346 — only includes install/tests/examples when root project
if(${CMAKE_SOURCE_DIR} STREQUAL ${CMAKE_CURRENT_SOURCE_DIR})
    add_subdirectory(install)
    add_subdirectory(tests)
    add_subdirectory(examples)
endif()
```

When used via `add_subdirectory(extern/zenoh-c)`, it:
1. Runs `cargo build` automatically (via `add_custom_command`)
2. Exports three targets: `zenohc::shared`, `zenohc::static`, `zenohc::lib`
3. Skips install/tests/examples (no pollution)
4. Respects `ZENOHC_BUILD_WITH_SHARED_MEMORY`, `ZENOHC_BUILD_WITH_UNSTABLE_API`
5. Handles Cargo.toml placement into the binary dir automatically ("Mode: Non-IDE")
6. Copies `rust-toolchain.toml` to binary dir for cargo invocation

It also provides `cmake/helpers.cmake` with reusable utilities (`declare_cache_var`, `set_default_build_type`, `include_project`, `get_required_static_libs`) — the same patterns zenoh-cpp uses.

**This is our integration point.** Instead of building zenoh-c separately and discovering the artifact, we include it as a CMake subdirectory and link directly against the target.

**Risk: This path is untested.** zenoh-c's subdirectory mode exists but we have not verified it works from a parent project. The `cargo build` invocation, Cargo.toml templating, and target directory resolution all need validation during implementation. This is the first thing to spike.

---

## What Gets Built and How

This project produces **two native shared libraries** that the Dart runtime loads via `DynamicLibrary.open()`:

| Library | Source | Language | Build tool |
|---------|--------|----------|------------|
| `libzenohc.so` | `extern/zenoh-c/` (Rust crate) | Rust | `cargo` (Linux) / `cargo-ndk` (Android) |
| `libzenoh_dart.so` | `src/zenoh_dart.{h,c}` (C shim) | C | CMake + clang (Linux) / CMake + NDK clang (Android) |

After building, both `.so` files must land in `packages/zenoh/native/<platform>/<arch>/` where the Dart build hook and `native_lib.dart` expect them.

There is also a **Dart code generation step** (not part of CMake):

| Artifact | Source | Tool | When to run |
|----------|--------|------|-------------|
| `bindings.dart` | `src/zenoh_dart.h` | `fvm dart run ffigen` | Only when C header changes |

This is orthogonal to the native build — ffigen reads the C header and generates Dart code. It runs in the Dart ecosystem, not CMake.

---

## Proposed Architecture

```
zenoh-dart/
  CMakeLists.txt          # NEW — Root superbuild orchestrator
  CMakePresets.json        # NEW — Platform/config presets
  src/
    CMakeLists.txt         # MODIFIED — dual-mode (subdirectory or standalone)
  extern/
    zenoh-c/               # EXISTING — add_subdirectory() target
    cmake/                 # KEEP — local CMake RTFM reference (not used in build)
  scripts/
    build_zenoh_android.sh # SIMPLIFIED — uses cmake presets for Stage 2
  packages/zenoh/
    native/                # EXISTING — prebuilt output (unchanged)
    hook/build.dart        # UNCHANGED — Dart build hooks
    lib/src/
      native_lib.dart      # UNCHANGED — DynamicLibrary.open() loading
      bindings.dart        # UNCHANGED — auto-generated FFI bindings
    ffigen.yaml            # UNCHANGED — code generation config
```

### Root `CMakeLists.txt` (new)

```cmake
cmake_minimum_required(VERSION 3.16)
project(zenoh_dart VERSION 0.0.1 LANGUAGES C CXX)
# CXX required because zenoh-c's project() declares both C and CXX

# Reuse zenoh-c's battle-tested helpers
set(CMAKE_MODULE_PATH "${CMAKE_CURRENT_SOURCE_DIR}/extern/zenoh-c/cmake"
                      ${CMAKE_MODULE_PATH})
include(helpers)
set_default_build_type(Release)

# ── Options ──
declare_cache_var(ZENOH_DART_BUILD_ZENOHC TRUE BOOL
    "Build zenoh-c from source via cargo (FALSE = use prebuilt)")

# ── Platform guard ──
if(NOT (UNIX OR ANDROID))
    message(FATAL_ERROR "Only Linux and Android targets are supported")
endif()
if(ANDROID)
    # cargo-ndk builds zenoh-c separately; CMake only builds the C shim here
    set(ZENOH_DART_BUILD_ZENOHC FALSE)
endif()

# ── zenoh-c (from source) ──
if(ZENOH_DART_BUILD_ZENOHC)
    # These cache vars configure zenoh-c's CMakeLists.txt before add_subdirectory
    set(BUILD_SHARED_LIBS TRUE CACHE BOOL "" FORCE)
    set(ZENOHC_BUILD_WITH_SHARED_MEMORY TRUE CACHE BOOL "" FORCE)
    set(ZENOHC_BUILD_WITH_UNSTABLE_API TRUE CACHE BOOL "" FORCE)
    # "+stable" makes cargo invoke `cargo +stable build ...`
    # This overrides extern/zenoh-c/rust-toolchain.toml which pins an unreleased version
    set(ZENOHC_CARGO_CHANNEL "+stable" CACHE STRING "" FORCE)
    # Note: ZENOHC_BUILD_IN_SOURCE_TREE is irrelevant here — zenoh-c's condition
    # (line 79) also checks CMAKE_SOURCE_DIR == CMAKE_CURRENT_SOURCE_DIR, which
    # is always FALSE when used via add_subdirectory(). No need to set it.
    add_subdirectory(extern/zenoh-c)
    message(STATUS "zenoh-c: building from source (cargo)")
else()
    message(STATUS "zenoh-c: using prebuilt (discovery in src/CMakeLists.txt)")
endif()

# ── C shim ──
add_subdirectory(src)

# ── Install: copy both .so files to the prebuilt directory ──
# Uses absolute DESTINATION intentionally — CMake install normally uses
# CMAKE_INSTALL_PREFIX + relative path, but we need libraries placed into
# the Dart package's native/ directory (which the build hook reads), not
# a system prefix like /usr/local/lib.
set(NATIVE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/packages/zenoh/native")

if(ANDROID)
    set(PREBUILT_DIR "${NATIVE_DIR}/android/${ANDROID_ABI}")
else()
    set(PREBUILT_DIR "${NATIVE_DIR}/linux/${CMAKE_SYSTEM_PROCESSOR}")
endif()

# Install libzenoh_dart.so via install(TARGETS) — NOT install(FILES).
# install(TARGETS) applies INSTALL_RPATH ("$ORIGIN") automatically via
# chrpath/relinking. install(FILES) is a raw copy that skips RPATH editing.
# This eliminates the patchelf dependency entirely.
install(TARGETS zenoh_dart LIBRARY DESTINATION "${PREBUILT_DIR}")

# Install libzenohc.so — source depends on build mode.
# zenohc_shared is an IMPORTED target, so install(TARGETS) cannot be used.
# install(FILES) is correct here — we don't own this library's RPATH.
if(ZENOH_DART_BUILD_ZENOHC AND TARGET zenohc_shared)
    # Superbuild: copy from cargo output in build tree
    install(FILES $<TARGET_FILE:zenohc_shared> DESTINATION "${PREBUILT_DIR}")
else()
    # Standalone/Android: libzenohc.so already in place (cargo-ndk or prior build)
    # Only copy if source differs from destination (avoids self-copy)
    if(DEFINED ZENOHC_LIB_DIR AND NOT "${ZENOHC_LIB_DIR}" STREQUAL "${PREBUILT_DIR}")
        install(FILES "${ZENOHC_LIB_DIR}/libzenohc.so" DESTINATION "${PREBUILT_DIR}")
    endif()
endif()
```

### Modified `src/CMakeLists.txt` (dual-mode)

The key change: check if `zenohc::lib` target already exists (from parent's `add_subdirectory(extern/zenoh-c)`). If yes, link directly. If no, use existing 3-tier discovery. This preserves backward compatibility — the file still works standalone.

```cmake
cmake_minimum_required(VERSION 3.10)
project(zenoh_dart_library VERSION 0.0.1 LANGUAGES C)

add_library(zenoh_dart SHARED
  "zenoh_dart.c"
  "dart/dart_api_dl.c"
)

set_target_properties(zenoh_dart PROPERTIES
  PUBLIC_HEADER zenoh_dart.h
  OUTPUT_NAME "zenoh_dart"
  C_VISIBILITY_PRESET hidden
  POSITION_INDEPENDENT_CODE ON
)

target_compile_definitions(zenoh_dart PUBLIC DART_SHARED_LIB)
if(NOT ANDROID)
  target_compile_definitions(zenoh_dart PRIVATE
    Z_FEATURE_SHARED_MEMORY
    Z_FEATURE_UNSTABLE_API
  )
endif()

target_include_directories(zenoh_dart PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}/dart"
)

# ── zenoh-c linkage ──
get_filename_component(PACKAGE_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/.." REALPATH)

if(TARGET zenohc::lib)
  # ── Superbuild mode: zenoh-c built by parent CMakeLists.txt ──
  # zenohc::lib's INTERFACE_INCLUDE_DIRECTORIES already provides the
  # zenoh-c headers, so no explicit target_include_directories needed.
  # Note: headers come from two sources during cargo build:
  #   1. Static headers (zenoh.h, zenoh_memory.h, zenoh_constants.h) copied
  #      by configure_cargo_toml() to the generated include dir
  #   2. Generated headers (zenoh_commons.h, zenoh_opaque.h, etc.) produced
  #      by cbindgen during the cargo build step
  # Both end up in the same INTERFACE_INCLUDE_DIRECTORIES path.
  # Verify during spike that all headers are resolvable.
  message(STATUS "zenoh-c: linking against zenohc::lib target (superbuild)")
  target_link_libraries(zenoh_dart PRIVATE zenohc::lib)

  # Resolve zenohc location for RPATH.
  # Uses zenohc_shared directly (not zenohc::lib) because:
  # 1. get_target_property() doesn't work on ALIAS targets before CMake 3.27
  # 2. We always want the shared library location regardless of BUILD_SHARED_LIBS
  get_target_property(ZENOHC_LOC zenohc_shared IMPORTED_LOCATION)
  if(ZENOHC_LOC)
    get_filename_component(ZENOHC_LIB_DIR "${ZENOHC_LOC}" DIRECTORY)
  endif()
else()
  # ── Standalone mode: 3-tier discovery (existing logic, unchanged) ──
  # zenoh-c headers must be added explicitly
  target_include_directories(zenoh_dart PUBLIC
    "${PACKAGE_ROOT}/extern/zenoh-c/include"
  )

  if(ANDROID)
    set(ZENOHC_LIB_DIR "${PACKAGE_ROOT}/android/src/main/jniLibs/${ANDROID_ABI}")
    set(ZENOHC_LIBRARY "${ZENOHC_LIB_DIR}/libzenohc.so")
  elseif(EXISTS "${PACKAGE_ROOT}/native/linux/${CMAKE_SYSTEM_PROCESSOR}/libzenohc.so")
    set(ZENOHC_LIB_DIR "${PACKAGE_ROOT}/native/linux/${CMAKE_SYSTEM_PROCESSOR}")
    set(ZENOHC_LIBRARY "${ZENOHC_LIB_DIR}/libzenohc.so")
  else()
    set(ZENOHC_LIB_DIR "${PACKAGE_ROOT}/extern/zenoh-c/target/release")
    set(ZENOHC_LIBRARY "${ZENOHC_LIB_DIR}/libzenohc.so")
  endif()

  if(NOT EXISTS "${ZENOHC_LIBRARY}")
    message(FATAL_ERROR
      "zenoh-c library not found at: ${ZENOHC_LIBRARY}\n"
      "For development: build from root with 'cmake --preset linux-x64'\n"
      "For Android: run 'scripts/build_zenoh_android.sh'\n"
      "For published package: ensure native/ directory contains prebuilt libraries")
  endif()

  message(STATUS "Found zenoh-c: ${ZENOHC_LIBRARY}")
  add_library(zenohc SHARED IMPORTED)
  set_target_properties(zenohc PROPERTIES
    IMPORTED_LOCATION "${ZENOHC_LIBRARY}"
    IMPORTED_NO_SONAME TRUE
  )
  target_link_libraries(zenoh_dart PRIVATE zenohc)
endif()

# Propagate ZENOHC_LIB_DIR to parent scope (for install target)
set(ZENOHC_LIB_DIR "${ZENOHC_LIB_DIR}" PARENT_SCOPE)

# ── Platform-specific ──
if(ANDROID)
  target_link_options(zenoh_dart PRIVATE "-Wl,-z,max-page-size=16384")
else()
  set_target_properties(zenoh_dart PROPERTIES
    BUILD_RPATH "${ZENOHC_LIB_DIR}"
    INSTALL_RPATH "$ORIGIN"
  )
endif()
```

### `CMakePresets.json` (new)

```json
{
  "version": 3,
  "configurePresets": [
    {
      "name": "linux-x64",
      "displayName": "Linux x86_64 — full build (zenoh-c from source + C shim)",
      "generator": "Ninja",
      "binaryDir": "${sourceDir}/build/linux-x64",
      "cacheVariables": {
        "CMAKE_C_COMPILER": "clang",
        "CMAKE_CXX_COMPILER": "clang++",
        "CMAKE_BUILD_TYPE": "Release",
        "ZENOH_DART_BUILD_ZENOHC": "TRUE"
      }
    },
    {
      "name": "linux-x64-shim-only",
      "displayName": "Linux x86_64 — C shim only (prebuilt zenoh-c)",
      "generator": "Ninja",
      "binaryDir": "${sourceDir}/build/linux-x64-shim",
      "cacheVariables": {
        "CMAKE_C_COMPILER": "clang",
        "CMAKE_BUILD_TYPE": "Release",
        "ZENOH_DART_BUILD_ZENOHC": "FALSE"
      }
    },
    {
      "name": "android-arm64",
      "displayName": "Android arm64-v8a — C shim only (zenoh-c via cargo-ndk)",
      "generator": "Ninja",
      "binaryDir": "${sourceDir}/build/android/arm64-v8a",
      "toolchainFile": "$env{ANDROID_NDK_HOME}/build/cmake/android.toolchain.cmake",
      "cacheVariables": {
        "ANDROID_ABI": "arm64-v8a",
        "ANDROID_PLATFORM": "android-24",
        "CMAKE_BUILD_TYPE": "Release"
      }
    },
    {
      "name": "android-x86_64",
      "displayName": "Android x86_64 — C shim only (zenoh-c via cargo-ndk)",
      "generator": "Ninja",
      "binaryDir": "${sourceDir}/build/android/x86_64",
      "toolchainFile": "$env{ANDROID_NDK_HOME}/build/cmake/android.toolchain.cmake",
      "cacheVariables": {
        "ANDROID_ABI": "x86_64",
        "ANDROID_PLATFORM": "android-24",
        "CMAKE_BUILD_TYPE": "Release"
      }
    }
  ],
  "buildPresets": [
    {
      "name": "linux-x64",
      "configurePreset": "linux-x64",
      "configuration": "Release"
    },
    {
      "name": "linux-x64-shim-only",
      "configurePreset": "linux-x64-shim-only"
    },
    {
      "name": "android-arm64",
      "configurePreset": "android-arm64"
    },
    {
      "name": "android-x86_64",
      "configurePreset": "android-x86_64"
    }
  ]
}
```

---

## Platform Flows: Before vs After

### Linux — Full Developer Build

**Before** (8 commands, documented across CLAUDE.md and docs/build/):
```bash
# 1. Configure zenoh-c
cmake -S extern/zenoh-c -B extern/zenoh-c/build -G Ninja \
  -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++ \
  -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=TRUE \
  -DZENOHC_BUILD_IN_SOURCE_TREE=TRUE
# 2. Build zenoh-c (cargo)
RUSTUP_TOOLCHAIN=stable cmake --build extern/zenoh-c/build --config Release
# 3. Configure C shim
cmake -S src -B build -G Ninja
# 4. Build C shim
cmake --build build
# 5-7. Copy + patch
mkdir -p packages/zenoh/native/linux/x86_64/
cp build/libzenoh_dart.so packages/zenoh/native/linux/x86_64/
cp extern/zenoh-c/target/release/libzenohc.so packages/zenoh/native/linux/x86_64/
patchelf --set-rpath '$ORIGIN' packages/zenoh/native/linux/x86_64/libzenoh_dart.so
# 8. (optional) Regenerate FFI bindings if C header changed
cd packages/zenoh && fvm dart run ffigen --config ffigen.yaml
# 9. Test
cd packages/zenoh && fvm dart test
```

**After** (2 native build commands + unchanged Dart commands):
```bash
# 1. Configure + build + cargo + install (RPATH set automatically by CMake)
cmake --preset linux-x64
cmake --build --preset linux-x64 --target install
# 2. (optional) Regenerate FFI bindings if C header changed
cd packages/zenoh && fvm dart run ffigen --config ffigen.yaml
# 3. Test
cd packages/zenoh && fvm dart test
```

### Android — End-to-End Build Pipeline

Android requires a **hybrid flow** because `libzenohc.so` is a Rust crate that needs `cargo-ndk` for Android cross-compilation. CMake cannot drive `cargo-ndk` — zenoh-c's CMakeLists.txt invokes bare `cargo build` which doesn't set up the NDK linker paths, sysroot, or target-specific flags that Android requires.

**What produces each `.so` on Android:**

```
┌─────────────────────────────────────────────────────────────────────┐
│ Stage 1: Build libzenohc.so (Rust → Android)                      │
│                                                                     │
│  Tool:    cargo-ndk (wraps cargo with NDK environment)             │
│  Input:   extern/zenoh-c/ (Rust crate)                             │
│  Command: cargo ndk -t arm64-v8a --platform 24 build --release    │
│  Output:  android/src/main/jniLibs/arm64-v8a/libzenohc.so         │
│                                                                     │
│  WHY NOT CMAKE: zenoh-c's CMakeLists.txt uses bare `cargo build`. │
│  cargo-ndk sets CC, CXX, AR, CARGO_TARGET_*_LINKER to NDK tools  │
│  and calls `cargo build --target aarch64-linux-android`. CMake     │
│  cannot replicate this without fragile env var injection.          │
└─────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────────┐
│ Stage 2: Build libzenoh_dart.so (C → Android)                     │
│                                                                     │
│  Tool:    CMake + NDK toolchain file                               │
│  Input:   src/zenoh_dart.{h,c} + prebuilt libzenohc.so from above │
│  Command: cmake --preset android-arm64 && cmake --build ...       │
│  Output:  build/android/arm64-v8a/libzenoh_dart.so                │
│                                                                     │
│  The C shim's 3-tier discovery finds libzenohc.so in jniLibs/.    │
│  SHM features excluded (if(NOT ANDROID) guard in CMakeLists.txt). │
└─────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────────┐
│ Stage 3: Install to prebuilt directory                             │
│                                                                     │
│  cmake --build --preset android-arm64 --target install             │
│  Copies BOTH .so files to packages/zenoh/native/android/arm64-v8a/│
│                                                                     │
│  This is where the Dart build hook reads them from.                │
│  On Flutter APK build, hook registers CodeAssets, Flutter places   │
│  them in lib/arm64-v8a/ inside the APK.                           │
└─────────────────────────────────────────────────────────────────────┘
```

**Before** (1 bash script command, but opaque — hides 3 stages):
```bash
./scripts/build_zenoh_android.sh                  # arm64-v8a + x86_64
./scripts/build_zenoh_android.sh --abi arm64-v8a  # single ABI
```

**After** (same entry point, clearer internals):
```bash
./scripts/build_zenoh_android.sh                  # Still the entry point
# Internally per ABI:
#   Stage 1: cargo ndk -t arm64-v8a ... build --release  (UNCHANGED)
#   Stage 2: cmake --preset android-arm64                 (replaces 6 manual cmake flags)
#   Stage 3: cmake --build --preset android-arm64 --target install  (replaces cp commands)
```

**Honest assessment**: The improvement for Android is modest. The bash script still orchestrates two fundamentally different build tools (`cargo-ndk` + `cmake`). The win is:
- Stage 2 uses presets instead of 6 manual flags
- Stage 3 uses `cmake --target install` instead of manual `cp` + `mkdir`
- The preset names make the intent clear (`android-arm64` vs wall of `-D` flags)

The bash script remains necessary because it iterates over ABIs, auto-detects NDK, and installs Rust targets — none of which are CMake's job.

### Runtime: How Dart Loads the `.so` Files

After building, the native libraries sit in `packages/zenoh/native/<platform>/<arch>/`. The Dart runtime loads them via a completely separate mechanism:

```
                    ┌─────────────────────────────┐
                    │ fvm dart test / fvm dart run │
                    └─────────────┬───────────────┘
                                  │
                                  ▼
                    ┌─────────────────────────────┐
                    │ native_lib.dart              │
                    │ ensureInitialized()          │
                    │                             │
                    │ Linux:                      │
                    │   _resolveLibraryPath()     │
                    │   → native/linux/x86_64/    │
                    │   DynamicLibrary.open(path) │
                    │                             │
                    │ Android:                    │
                    │   DynamicLibrary.open(       │
                    │     'libzenoh_dart.so')     │
                    │   → APK linker resolves     │
                    └─────────────┬───────────────┘
                                  │
                                  ▼
                    ┌─────────────────────────────┐
                    │ OS linker loads libzenohc.so│
                    │ via DT_NEEDED entry +       │
                    │ RPATH=$ORIGIN (Linux) or    │
                    │ APK lib/<abi>/ (Android)    │
                    └─────────────────────────────┘
```

This Dart-side loading is completely untouched by the proposal. It doesn't care how the `.so` files were built — only that they exist in the right place.

---

## What Changes, What Stays

| Component | Change | Rationale |
|-----------|--------|-----------|
| Root `CMakeLists.txt` | **NEW** | Superbuild entry point, drives cargo + C shim + install |
| `CMakePresets.json` | **NEW** | Replaces 15+ manual cmake flags across platforms |
| `src/CMakeLists.txt` | **MODIFIED** | Dual-mode: `zenohc::lib` target (superbuild) or 3-tier discovery (standalone) |
| `extern/cmake` | **KEEP** | Local CMake RTFM reference for agents |
| `scripts/build_zenoh_android.sh` | **SIMPLIFIED** | Uses presets for Stage 2+3 instead of manual flags+cp |
| `packages/zenoh/hook/build.dart` | Unchanged | Dart build hooks — reads from `native/`, registers CodeAssets |
| `packages/zenoh/lib/src/native_lib.dart` | Unchanged | Runtime `DynamicLibrary.open()` loading |
| `packages/zenoh/lib/src/bindings.dart` | Unchanged | Auto-generated FFI bindings |
| `packages/zenoh/ffigen.yaml` | Unchanged | Code generation config — run when C header changes |
| Prebuilt layout (`native/`) | Unchanged | Same directory structure, same files |

---

## Why Not Full CMake for Android?

zenoh-c's `CMakeLists.txt` invokes bare `cargo build`, which doesn't know how to cross-compile for Android without the environment setup that `cargo-ndk` provides (NDK linker paths, sysroot, target-specific flags). We could replicate that environment in CMake, but:

1. `cargo-ndk` is the battle-tested approach (used by zenoh-kotlin, the Rust ecosystem)
2. Replicating it in CMake is fragile — `cargo-ndk` sets `CC`, `CXX`, `AR`, and `CARGO_TARGET_*_LINKER` to NDK-specific paths that change with NDK versions
3. The bash script already works and is 136 lines
4. CMake's `add_custom_command` for cargo doesn't have access to the NDK toolchain environment that `CMAKE_TOOLCHAIN_FILE` sets up (that's for C/C++ compilation, not Rust)

The hybrid approach is pragmatic: `cargo-ndk` for Rust compilation, CMake presets for C shim compilation. The root CMakeLists.txt auto-disables `ZENOH_DART_BUILD_ZENOHC` when `ANDROID` is defined.

---

## Risks and Mitigations

| # | Risk | Impact | Mitigation |
|---|------|--------|------------|
| 1 | **`add_subdirectory(extern/zenoh-c)` untested from parent project** | Could fail due to Cargo.toml placement, target directory resolution, or cmake variable scope issues | **Spike first.** Before implementing the full proposal, create a minimal parent CMakeLists.txt that does just `add_subdirectory(extern/zenoh-c)` and verify `zenohc::lib` target works. This is the critical path — if it fails, the superbuild approach doesn't work. |
| 2 | zenoh-c subdirectory build writes to build tree, not source tree | Cargo output in `build/linux-x64/extern/zenoh-c/` instead of `extern/zenoh-c/target/` | Expected behavior. The install target copies to `native/`. Old `extern/zenoh-c/target/` from prior manual builds can be cleaned up. |
| 3 | `ZENOHC_CARGO_CHANNEL "+stable"` — does `cargo +stable` actually override `rust-toolchain.toml`? | If not, cargo may try to use the pinned unreleased toolchain and fail | The `+channel` syntax is a rustup override that takes precedence over `rust-toolchain.toml`. This is the same mechanism as the current `RUSTUP_TOOLCHAIN=stable` env var, just invoked differently. Verify during spike. |
| 4 | `add_subdirectory` pulls in zenoh-c's full cargo build time | First build takes 5-10 min | Same as current. Cargo is incremental — subsequent builds only rebuild if Rust sources change. C shim-only changes rebuild in ~2s. |
| 5 | CMakePresets.json requires CMake 3.21+ | Developers with older CMake can't use presets | Root CMakeLists.txt works without presets (manual `-D` flags). Presets are convenience, not requirement. Version 3 is the minimum needed (toolchainFile support). |
| 6 | Root project declares `LANGUAGES C CXX` but developer may not have `clang++` | Configure fails | Presets set `CMAKE_CXX_COMPILER=clang++`. If missing, cmake error is clear. CXX is needed because zenoh-c's `project()` declares both C and CXX. |

---

## Migration Path

This is a Phase-P2 (Packaging/Build) effort. Suggested execution:

1. **Spike `add_subdirectory(extern/zenoh-c)`** — Minimal test to verify superbuild integration works (Risk #1). Write a 10-line parent CMakeLists.txt, configure, build, check `zenohc::lib` target exists and links correctly.
2. **Add root `CMakeLists.txt`** — Superbuild orchestrator (the full version from this proposal)
3. **Add `CMakePresets.json`** — Platform presets
4. **Modify `src/CMakeLists.txt`** — Add `if(TARGET zenohc::lib)` dual-mode branch
5. **Update `build_zenoh_android.sh`** — Use presets for Stage 2+3
6. **Verify Linux** — `cmake --preset linux-x64 && cmake --build --preset linux-x64 --target install && cd packages/zenoh && fvm dart test` (193 tests pass)
7. **Verify Android** — `./scripts/build_zenoh_android.sh && cd packages/zenoh && fvm dart test` (if device available)
8. **Update CLAUDE.md** — Replace manual build commands with preset commands
9. **Update `docs/build/01-build-zenoh-c.md`** — Reflect new unified flow

This is a CI-session task (direct edit, not TDD — build infrastructure, not testable behavior).

**Note on helpers.cmake dependency:** The root CMakeLists.txt reuses `extern/zenoh-c/cmake/helpers.cmake`. Since zenoh-c is pinned at v1.7.2 via submodule, this is a controlled dependency — helpers won't change unexpectedly. When upgrading the zenoh-c submodule version, review the root CMakeLists.txt for compatibility with any helpers.cmake changes.
