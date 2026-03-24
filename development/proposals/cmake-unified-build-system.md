# Build System Analysis & Proposal: Unified CMake Superbuild

**Date:** 2026-03-24
**Author:** CA (Code Architect)
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
5. Handles Cargo.toml placement into the binary dir automatically

It also provides `cmake/helpers.cmake` with reusable utilities (`declare_cache_var`, `set_default_build_type`, `include_project`, `get_required_static_libs`) — the same patterns zenoh-cpp uses.

**This is our integration point.** Instead of building zenoh-c separately and discovering the artifact, we include it as a CMake subdirectory and link directly against the target.

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
    cmake/                 # KEEP — local CMake RTFM reference
  scripts/
    build_zenoh_android.sh # SIMPLIFIED — uses cmake presets
  packages/zenoh/
    native/                # EXISTING — prebuilt output (unchanged)
    hook/build.dart        # UNCHANGED
    lib/src/native_lib.dart # UNCHANGED
```

### Root `CMakeLists.txt` (new)

```cmake
cmake_minimum_required(VERSION 3.16)
project(zenoh_dart VERSION 0.0.1 LANGUAGES C)

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
    # cargo-ndk builds zenoh-c separately; we only build the C shim here
    set(ZENOH_DART_BUILD_ZENOHC FALSE)
endif()

# ── zenoh-c (from source) ──
if(ZENOH_DART_BUILD_ZENOHC)
    set(BUILD_SHARED_LIBS TRUE CACHE BOOL "" FORCE)
    set(ZENOHC_BUILD_WITH_SHARED_MEMORY TRUE CACHE BOOL "" FORCE)
    set(ZENOHC_BUILD_WITH_UNSTABLE_API TRUE CACHE BOOL "" FORCE)
    set(ZENOHC_CARGO_CHANNEL "+stable" CACHE STRING "" FORCE)
    set(ZENOHC_BUILD_IN_SOURCE_TREE FALSE CACHE BOOL "" FORCE)
    add_subdirectory(extern/zenoh-c)
    message(STATUS "zenoh-c: building from source (cargo)")
else()
    message(STATUS "zenoh-c: using prebuilt (discovery in src/CMakeLists.txt)")
endif()

# ── C shim ──
add_subdirectory(src)

# ── Install prebuilts ──
include(GNUInstallDirs)
set(NATIVE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/packages/zenoh/native")

if(ANDROID)
    set(PREBUILT_DIR "${NATIVE_DIR}/android/${ANDROID_ABI}")
else()
    set(PREBUILT_DIR "${NATIVE_DIR}/linux/${CMAKE_SYSTEM_PROCESSOR}")
endif()

# 'install' target copies libraries to the prebuilt directory
install(FILES $<TARGET_FILE:zenoh_dart> DESTINATION "${PREBUILT_DIR}")

if(ZENOH_DART_BUILD_ZENOHC AND TARGET zenohc_shared)
    install(FILES $<TARGET_FILE:zenohc_shared> DESTINATION "${PREBUILT_DIR}")
endif()

# Linux: fix RPATH on installed libraries
if(NOT ANDROID)
    find_program(PATCHELF patchelf)
    if(PATCHELF)
        install(CODE "
            execute_process(
                COMMAND ${PATCHELF} --set-rpath \\$ORIGIN
                    \"${PREBUILT_DIR}/libzenoh_dart.so\"
            )
            message(STATUS \"Set RPATH=\\$ORIGIN on libzenoh_dart.so\")
        ")
    else()
        message(WARNING "patchelf not found — RPATH won't be set on installed libraries")
    endif()
endif()
```

### Modified `src/CMakeLists.txt` (dual-mode)

The key change: check if `zenohc::lib` target already exists (from parent's `add_subdirectory(extern/zenoh-c)`). If yes, link directly. If no, use existing 3-tier discovery.

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

# zenoh-c headers (always needed, even when target exists)
target_include_directories(zenoh_dart PUBLIC
  "${PACKAGE_ROOT}/extern/zenoh-c/include"
)

if(TARGET zenohc::lib)
  # ── Superbuild mode: zenoh-c built by parent CMakeLists.txt ──
  message(STATUS "zenoh-c: linking against zenohc::lib target")
  target_link_libraries(zenoh_dart PRIVATE zenohc::lib)
  # RPATH points to zenohc build output (for running from build tree)
  get_target_property(ZENOHC_LOC zenohc_shared IMPORTED_LOCATION)
  if(ZENOHC_LOC)
    get_filename_component(ZENOHC_LIB_DIR "${ZENOHC_LOC}" DIRECTORY)
  endif()
else()
  # ── Standalone mode: 3-tier discovery (existing logic) ──
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

# Propagate for parent
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
  "version": 6,
  "configurePresets": [
    {
      "name": "linux-x64",
      "displayName": "Linux x86_64 (build zenoh-c from source)",
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
      "displayName": "Linux x86_64 (C shim only, prebuilt zenoh-c)",
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
      "displayName": "Android arm64-v8a",
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
      "displayName": "Android x86_64",
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

### Linux Developer

**Before** (5 commands, 3 documented in different places):
```bash
cmake -S extern/zenoh-c -B extern/zenoh-c/build -G Ninja \
  -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++ \
  -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=TRUE \
  -DZENOHC_BUILD_IN_SOURCE_TREE=TRUE
RUSTUP_TOOLCHAIN=stable cmake --build extern/zenoh-c/build --config Release
cmake -S src -B build -G Ninja
cmake --build build
mkdir -p packages/zenoh/native/linux/x86_64/
cp build/libzenoh_dart.so packages/zenoh/native/linux/x86_64/
cp extern/zenoh-c/target/release/libzenohc.so packages/zenoh/native/linux/x86_64/
patchelf --set-rpath '$ORIGIN' packages/zenoh/native/linux/x86_64/libzenoh_dart.so
```

**After** (2 commands):
```bash
cmake --preset linux-x64
cmake --build --preset linux-x64 --target install
```

Configure + build + cargo + copy + patchelf all in one pipeline.

### Android

**Before** (1 command, but disconnected from Linux flow):
```bash
./scripts/build_zenoh_android.sh
```

**After** (same script, simplified internally to use presets):
```bash
./scripts/build_zenoh_android.sh          # Still the entry point
# Internally:
#   Stage 1: cargo-ndk (unchanged — Rust needs cargo-ndk, not CMake)
#   Stage 2: cmake --preset android-arm64 --target install  (replaces manual cmake flags)
```

---

## What Changes, What Stays

| Component | Change | Rationale |
|-----------|--------|-----------|
| Root `CMakeLists.txt` | **NEW** | Superbuild entry point |
| `CMakePresets.json` | **NEW** | Replaces 15+ manual flags |
| `src/CMakeLists.txt` | **MODIFIED** | Dual-mode: target or discovery |
| `extern/cmake` | **KEEP** | Local CMake RTFM reference for agents |
| `scripts/build_zenoh_android.sh` | **SIMPLIFIED** | Uses presets for Stage 2 |
| `packages/zenoh/hook/build.dart` | Unchanged | Dart-side unaffected |
| `packages/zenoh/lib/src/native_lib.dart` | Unchanged | Runtime loading unaffected |
| `packages/zenoh/ffigen.yaml` | Unchanged | Code generation unaffected |
| Prebuilt layout (`native/`) | Unchanged | Same directory structure |

---

## Why Not Full CMake for Android?

zenoh-c's `CMakeLists.txt` invokes bare `cargo build`, which doesn't know how to cross-compile for Android without the environment setup that `cargo-ndk` provides (NDK linker paths, sysroot, target-specific flags). We could replicate that environment in CMake, but:

1. `cargo-ndk` is the battle-tested approach (used by zenoh-kotlin, the Rust ecosystem)
2. Replicating it in CMake is fragile and would break when NDK updates
3. The bash script already works and is 136 lines

The hybrid approach is pragmatic: `cargo-ndk` for Rust compilation, CMake presets for C shim compilation. The root CMakeLists.txt auto-disables `ZENOH_DART_BUILD_ZENOHC` on Android.

---

## Risks and Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| zenoh-c subdirectory build writes to build tree, not source tree | Cargo output in `build/linux-x64/extern/zenoh-c/` instead of `extern/zenoh-c/target/` | Expected behavior. Install target copies to `native/`. Old `extern/zenoh-c/target/` from prior manual builds can be cleaned up. |
| `ZENOHC_CARGO_CHANNEL "+stable"` forced | Overrides zenoh-c's `rust-toolchain.toml` pinning 1.93.0 | Same workaround we use today. Already documented. |
| `add_subdirectory` pulls in zenoh-c's full cargo build time | First build takes 5-10 min | Same as current. Incremental builds are fast (~2s for C shim only). |
| patchelf dependency for install target | Build fails without patchelf | WARNING, not FATAL_ERROR. Developer can install via `apt install patchelf`. |
| CMakePresets.json requires CMake 3.21+ | Our minimum is 3.10 | Root CMakeLists.txt still works without presets (manual flags). Presets are convenience, not requirement. Bump minimum to 3.16 (matching zenoh-c). |

---

## Migration Path

This is a Phase-P2 (Packaging/Build) effort. Suggested execution:

1. **Add root `CMakeLists.txt`** — Superbuild orchestrator
3. **Add `CMakePresets.json`** — Platform presets
4. **Modify `src/CMakeLists.txt`** — Add `if(TARGET zenohc::lib)` dual-mode
5. **Update `build_zenoh_android.sh`** — Use presets for Stage 2
6. **Verify** — `cmake --preset linux-x64 && cmake --build --preset linux-x64 --target install && cd packages/zenoh && fvm dart test` (193 tests pass)
7. **Update CLAUDE.md** — Replace manual build commands with preset commands
8. **Update `docs/build/01-build-zenoh-c.md`** — Reflect new flow

This is a CI-session task (direct edit, not TDD — build infrastructure, not testable behavior).
