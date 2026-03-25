# Phase P1: Packaging & Distribution (Linux + Android)

## Project Context

`zenoh_dart` is a Dart FFI package providing bindings for zenoh-c v1.7.2 via a
C shim layer. See `development/phases/phase-00-bootstrap.md` for full architecture.

### Architecture (abbreviated)

```
Dart CLI example (bin/z_*.dart)  →  Idiomatic Dart API (lib/src/*.dart)
  →  Generated FFI bindings (lib/src/bindings.dart)  →  C shim (src/zenoh_dart.h/.c)
  →  libzenohc.so (zenoh-c v1.7.2)
```

### Why this phase exists

Currently `zenoh_dart` can only be built from a local checkout with
`extern/zenoh-c` built in-tree. Three blockers prevent external consumption:

1. `libzenohc.so` is never bundled into the final app (Linux)
2. `src/CMakeLists.txt` has a hardcoded path to `extern/zenoh-c/target/release`
3. No Android cross-compiled `libzenohc.so` exists at all

This phase fixes all three so that any Flutter project can depend on
`zenoh_dart` via a pubspec.yaml path dependency and have it "just work" on
Linux desktop and Android.

## Prior Phases

### Phase 0 (Bootstrap) — completed

- C shim: session/config/keyexpr/bytes management (Dart native API DL init,
  logging, 20+ functions)
- Dart: `Config`, `Session`, `KeyExpr`, `ZBytes`, `ZenohException`
- Build: CMakeLists links libzenohc, ffigen generates bindings to `lib/src/bindings.dart`
- Files: `lib/src/{bindings,native_lib,exceptions,config,session,keyexpr,bytes}.dart`

### Phase 1 (z_put + z_delete) — completed

- C shim: `zd_put`, `zd_delete`
- Dart: `Session.put()`, `Session.putBytes()`, `Session.delete()`
- CLI: `bin/z_put.dart`, `bin/z_delete.dart`

### Phase 2 (z_sub — Callback Subscriber) — completed

- C shim: `zd_declare_subscriber`, `zd_subscriber_drop`, `_zd_sample_callback`
- Dart: `Subscriber`, `Sample`, `SampleKind`
- CLI: `bin/z_sub.dart`

## This Phase's Goal

Make `zenoh_dart` consumable as a **path dependency** from any Flutter project
on **Linux (x86_64)** and **Android (arm64-v8a, x86_64)**. No pub.dev
publishing yet — just path dependency works end-to-end.

Concretely:

1. Fix `src/CMakeLists.txt` to find `libzenohc.so` from platform-appropriate
   locations instead of the hardcoded extern/ path
2. Bundle `libzenohc.so` alongside `libzenoh_dart.so` on Linux via
   `zenoh_dart_bundled_libraries`
3. Provide prebuilt `libzenohc.so` for Android ABIs via the jniLibs convention
4. Create a build script for cross-compiling zenoh-c for Android via cargo-ndk
5. Simplify `native_lib.dart` to single-load (OS linker resolves zenohc)
6. Verify end-to-end: fresh Flutter app + path dep → `flutter run` works

### What this phase does NOT do

- Publish to pub.dev (future work)
- Support iOS, macOS, or Windows (future phases)
- Use hook/build.dart / native assets (deferred to Phase P2)
- Add CI/CD for prebuilt generation (future work)
- Change any Dart API surface (no new classes, methods, or behaviors)

## Design Decisions

### Single-load Dart library loading

**Current state:** `native_lib.dart` explicitly loads TWO libraries:
`_openZenohc()` then `_openZenohDart()`.

**Change:** Load only `libzenoh_dart.so`. The OS dynamic linker resolves
`libzenohc.so` as a transitive dependency because:
- On Linux: `libzenoh_dart.so` has `DT_NEEDED` for `libzenohc.so`, and
  both are in the bundle directory (RPATH resolves it)
- On Android: Both `.so` files are in the APK's `lib/{ABI}/` directory,
  which is on the linker search path

This is proven by `dart_zenoh_xplr`, which loads only its wrapper library.

The two-load pattern was a workaround for the current broken bundling. Once
bundling is fixed (the whole point of this phase), the manual pre-load is
unnecessary.

### Platform-aware zenohc discovery in CMake

`src/CMakeLists.txt` must find `libzenohc.so` from three possible locations,
checked in order:

1. **Android jniLibs** — `android/src/main/jniLibs/${ANDROID_ABI}/libzenohc.so`
   (consumer build, or after running build script)
2. **Prebuilt native directory** — `native/linux/${CMAKE_SYSTEM_PROCESSOR}/libzenohc.so`
   (published package for Linux desktop)
3. **Developer fallback** — `extern/zenoh-c/target/release/libzenohc.so`
   (local dev build from submodule)

This mirrors the pattern used by `dart_zenoh_xplr` and is conceptually similar
to `zenoh-cpp`'s three-strategy fallback (PATH → PACKAGE → GIT_URL).

### Android prebuilt strategy

- Use `cargo-ndk` (v4.1.2, available at `extern/cargo-ndk`) to cross-compile
  `zenoh-c` for Android
- Target ABIs: **arm64-v8a** (real devices) + **x86_64** (emulator)
- Output to `android/src/main/jniLibs/{ABI}/libzenohc.so`
- Gradle auto-bundles everything in `jniLibs/` into the APK
- Git-tracked for now (simplicity); migrate to CI-generated later
- Build script: `scripts/build_zenoh_android.sh`

### Linux prebuilt strategy

- Extract `libzenohc.so` from the official zenoh-c v1.7.2 GitHub release
  standalone ZIP for `x86_64-unknown-linux-gnu`
- Place at `native/linux/x86_64/libzenohc.so`
- `linux/CMakeLists.txt` adds it to `zenoh_dart_bundled_libraries`
- Git-tracked for now

### Toolchain

- **Linux**: CMake + Clang (same as existing)
- **Android**: Gradle → NDK CMake → NDK Clang (same as existing, but now with
  zenohc available in jniLibs)
- **Android prebuilt build**: cargo-ndk wraps NDK Clang for Rust cross-compilation

## File Changes

### Modified files

#### `src/CMakeLists.txt` — Platform-aware zenohc discovery

Replace the current hardcoded `find_library` block (lines 30-37) with
platform-aware three-tier discovery:

```cmake
# ----------- zenoh-c library discovery -----------
# Resolve the real source dir (handles symlinks in pub cache)
get_filename_component(PACKAGE_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/.." REALPATH)

if(ANDROID)
  # Android: prebuilt in jniLibs (Gradle bundles these into APK automatically)
  set(ZENOHC_LIB_DIR "${PACKAGE_ROOT}/android/src/main/jniLibs/${ANDROID_ABI}")
  set(ZENOHC_LIBRARY "${ZENOHC_LIB_DIR}/libzenohc.so")
elseif(EXISTS "${PACKAGE_ROOT}/native/linux/${CMAKE_SYSTEM_PROCESSOR}/libzenohc.so")
  # Published package: prebuilt in native/ directory
  set(ZENOHC_LIB_DIR "${PACKAGE_ROOT}/native/linux/${CMAKE_SYSTEM_PROCESSOR}")
  set(ZENOHC_LIBRARY "${ZENOHC_LIB_DIR}/libzenohc.so")
else()
  # Developer fallback: locally built from submodule
  set(ZENOHC_LIB_DIR "${PACKAGE_ROOT}/extern/zenoh-c/target/release")
  set(ZENOHC_LIBRARY "${ZENOHC_LIB_DIR}/libzenohc.so")
endif()

# Validate library exists
if(NOT EXISTS "${ZENOHC_LIBRARY}")
  message(FATAL_ERROR
    "zenoh-c library not found at: ${ZENOHC_LIBRARY}\n"
    "For development: build zenoh-c with 'cmake --build extern/zenoh-c/build'\n"
    "For Android: run 'scripts/build_zenoh_android.sh'\n"
    "For published package: ensure native/ directory contains prebuilt libraries")
endif()

message(STATUS "Found zenoh-c: ${ZENOHC_LIBRARY}")

# Create IMPORTED target for zenohc
add_library(zenohc SHARED IMPORTED)
set_target_properties(zenohc PROPERTIES
  IMPORTED_LOCATION "${ZENOHC_LIBRARY}"
  IMPORTED_NO_SONAME TRUE
)

target_link_libraries(zenoh_dart PRIVATE zenohc)
```

Also:
- Set RPATH on non-Android platforms so OS linker finds zenohc at runtime:
  ```cmake
  if(NOT ANDROID)
    set_target_properties(zenoh_dart PROPERTIES
      BUILD_RPATH "${ZENOHC_LIB_DIR}"
      INSTALL_RPATH "$ORIGIN"
    )
  endif()
  ```
- Export `ZENOHC_LIB_DIR` as a cache variable so `linux/CMakeLists.txt` can
  reference it for bundled_libraries

#### `linux/CMakeLists.txt` — Bundle libzenohc.so

Add `libzenohc.so` to the bundled libraries list:

```cmake
set(zenoh_dart_bundled_libraries
  $<TARGET_FILE:zenoh_dart>
  "${ZENOHC_LIB_DIR}/libzenohc.so"
  PARENT_SCOPE
)
```

The `ZENOHC_LIB_DIR` variable is set by `src/CMakeLists.txt` (propagated
through the add_subdirectory scope).

#### `lib/src/native_lib.dart` — Single-load simplification

Remove `_openZenohc()` function and `_zenohcLibName` constant. Remove the
explicit `zenohcLib` load. The `bindings` getter becomes:

```dart
static ZenohDartBindings get bindings {
  if (_bindings != null) return _bindings!;
  _bindings = ZenohDartBindings(zenohDartLib);
  _bindings!.zd_init_dart_api_dl(NativeApi.initializeApiDLData);
  return _bindings!;
}
```

Remove `_zenohcLib` field and `zenohcLib` getter. Keep `_openZenohDart()` and
`zenohDartLib` getter as-is.

### New files

#### `native/linux/x86_64/libzenohc.so` — Linux prebuilt

Extracted from the official zenoh-c v1.7.2 release:
`zenoh-c-1.7.2-x86_64-unknown-linux-gnu-standalone.zip` → `lib/libzenohc.so`

Size: ~14.6 MB

#### `android/src/main/jniLibs/arm64-v8a/libzenohc.so` — Android arm64 prebuilt

Built via `scripts/build_zenoh_android.sh`. Cross-compiled from `extern/zenoh-c`
using cargo-ndk targeting `aarch64-linux-android` with API level 24.

Size: ~12-15 MB

#### `android/src/main/jniLibs/x86_64/libzenohc.so` — Android x86_64 prebuilt

Built via `scripts/build_zenoh_android.sh`. Cross-compiled from `extern/zenoh-c`
using cargo-ndk targeting `x86_64-linux-android` with API level 24.

Size: ~14-16 MB

#### `scripts/build_zenoh_android.sh` — Android cross-compilation script

Builds `libzenohc.so` for Android ABIs using cargo-ndk. Usage:

```bash
./scripts/build_zenoh_android.sh [--abi arm64-v8a|x86_64|all] [--api 24]
```

Implementation:

```bash
#!/usr/bin/env bash
set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ZENOHC_DIR="${PROJECT_ROOT}/extern/zenoh-c"
JNILIBS_DIR="${PROJECT_ROOT}/android/src/main/jniLibs"
API_LEVEL="${API_LEVEL:-24}"

# Default ABIs
ABIS=("arm64-v8a" "x86_64")

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --abi) ABIS=("$2"); shift 2 ;;
    --api) API_LEVEL="$2"; shift 2 ;;
    --all) ABIS=("arm64-v8a" "x86_64" "armeabi-v7a" "x86"); shift ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# Prerequisites check
command -v cargo >/dev/null 2>&1 || { echo "Error: cargo not found"; exit 1; }
command -v cargo-ndk >/dev/null 2>&1 || {
  echo "cargo-ndk not found. Install with: cargo install cargo-ndk"
  exit 1
}

# Ensure required Rust targets are installed
declare -A ABI_TO_TARGET=(
  ["arm64-v8a"]="aarch64-linux-android"
  ["armeabi-v7a"]="armv7-linux-androideabi"
  ["x86"]="i686-linux-android"
  ["x86_64"]="x86_64-linux-android"
)

for abi in "${ABIS[@]}"; do
  target="${ABI_TO_TARGET[$abi]}"
  echo "Ensuring Rust target: ${target}"
  rustup target add "${target}"
done

# Build for each ABI
for abi in "${ABIS[@]}"; do
  echo "Building zenoh-c for ${abi} (API level ${API_LEVEL})..."
  mkdir -p "${JNILIBS_DIR}/${abi}"

  RUSTUP_TOOLCHAIN=stable cargo ndk \
    -t "${abi}" \
    --platform "${API_LEVEL}" \
    -o "${JNILIBS_DIR}" \
    build --release \
    --manifest-path "${ZENOHC_DIR}/Cargo.toml"

  echo "Built: ${JNILIBS_DIR}/${abi}/libzenohc.so"
done

echo "Done. Android prebuilts at: ${JNILIBS_DIR}"
ls -la "${JNILIBS_DIR}"/*/libzenohc.so
```

Prerequisites:
- Rust toolchain (stable)
- Android NDK (r23+, typically installed via Android Studio)
- cargo-ndk (`cargo install cargo-ndk`)
- Rust targets for desired ABIs (script installs automatically)

#### `native/linux/.gitkeep` — Directory placeholder

Ensures the `native/linux/` directory exists in git.

### Files NOT changed

- `android/build.gradle` — No changes needed. Gradle's `externalNativeBuild`
  already invokes `src/CMakeLists.txt`, and jniLibs are auto-bundled.
- `ffigen.yaml` — No changes.
- `pubspec.yaml` — No changes (no new dependencies for Approach A).
- All Dart API files except `native_lib.dart` — No API surface changes.
- `src/zenoh_dart.h`, `src/zenoh_dart.c` — No C shim changes.
- iOS/macOS podspecs — Out of scope for Phase P1.

## zenoh-c APIs Wrapped

No new zenoh-c APIs wrapped in this phase. This is a build infrastructure phase.

## Reference Files

- `dart_zenoh_xplr/packages/dart_zenoh/src/CMakeLists.txt` — Platform-aware
  zenohc discovery pattern (the model for our CMake changes)
- `dart_zenoh_xplr/packages/dart_zenoh/linux/CMakeLists.txt` — bundled_libraries
  with three entries including libzenohc.so
- `dart_zenoh_xplr/scripts/build_zenoh_android.sh` — cargo-ndk cross-compilation
  reference
- `extern/zenoh-cpp/cmake/helpers.cmake` — Three-strategy dependency resolution
  pattern (conceptual model)
- `extern/cargo-ndk/` — Cross-compilation tool internals

## Verification

### Build verification

1. **Linux dev build**: `extern/zenoh-c` built locally →
   `src/CMakeLists.txt` finds zenohc at `extern/zenoh-c/target/release/` →
   C shim compiles and links → `flutter test` passes
2. **Linux prebuilt build**: Remove extern/ fallback temporarily →
   `src/CMakeLists.txt` finds zenohc at `native/linux/x86_64/` →
   same result
3. **Android build**: `scripts/build_zenoh_android.sh` produces
   `android/src/main/jniLibs/{arm64-v8a,x86_64}/libzenohc.so` →
   `flutter build apk` succeeds
4. **ffigen**: `dart run ffigen --config ffigen.yaml` still generates
   `lib/src/bindings.dart` without errors
5. **flutter analyze**: No errors or warnings

### Runtime verification

6. **Existing tests pass**: `flutter test` with `LD_LIBRARY_PATH` pointing
   to the library location — all session, put, delete, subscriber tests green
7. **Single-load works**: After `native_lib.dart` change, verify that
   `ZenohDartNative.bindings` loads successfully (zenohc resolved by OS linker,
   not explicit Dart load)
8. **Linux end-to-end**: Create a fresh Flutter desktop project, add
   `zenoh_dart: path: /path/to/zenoh_dart` to its pubspec.yaml, run
   `flutter run -d linux` — app starts, can open a zenoh session
9. **Android end-to-end**: Same fresh project, `flutter run -d <emulator>` —
   app starts, can open a zenoh session
10. **CLI examples still work**: `dart run bin/z_put.dart`,
    `dart run bin/z_sub.dart` still function correctly

### What "works" means for end-to-end

A minimal consumer app that proves the packaging:

```dart
import 'package:zenoh_dart/zenoh_dart.dart';

void main() {
  final session = Session.open();
  print('Session opened successfully!');
  session.put('demo/packaging-test', 'Hello from path dependency!');
  print('Put succeeded!');
  session.close();
  print('Session closed.');
}
```

This must run to completion without crashes on both Linux desktop and
Android emulator, when `zenoh_dart` is consumed as a path dependency.

## Implementation Notes for CZ

### Slice decomposition guidance

This phase is primarily build infrastructure. Suggested decomposition:

1. **Slice 1**: Fix `src/CMakeLists.txt` — platform-aware zenohc discovery with
   three-tier fallback. Test: existing `flutter test` still passes (zenohc found
   via developer fallback path).

2. **Slice 2**: Bundle zenohc on Linux — modify `linux/CMakeLists.txt` to add
   libzenohc.so to bundled_libraries. Add prebuilt to `native/linux/x86_64/`.
   Test: `flutter build linux` succeeds and output bundle contains both .so files.

3. **Slice 3**: Simplify Dart loading — modify `native_lib.dart` to single-load.
   Test: existing tests pass with single-load (OS linker resolves zenohc).

4. **Slice 4**: Android build script — create `scripts/build_zenoh_android.sh`.
   Test: script runs and produces `android/src/main/jniLibs/{ABI}/libzenohc.so`.

5. **Slice 5**: Android integration — verify `flutter build apk` succeeds with
   jniLibs prebuilts. Test: APK contains both libzenohc.so and libzenoh_dart.so
   for target ABIs.

6. **Slice 6**: End-to-end verification — create a throwaway consumer project,
   add path dependency, verify `flutter run` works on Linux and Android.

### Key CMake patterns from dart_zenoh_xplr

The reference project uses these patterns that we should adopt:

```cmake
# Symlink resolution (critical for pub cache paths)
get_filename_component(PACKAGE_ROOT "${CMAKE_CURRENT_LIST_DIR}/.." REALPATH)

# IMPORTED target for external library
add_library(zenohc SHARED IMPORTED)
set_target_properties(zenohc PROPERTIES
  IMPORTED_LOCATION "${ZENOHC_LIBRARY}"
  IMPORTED_NO_SONAME TRUE  # Required for Android
)

# RPATH for desktop (NOT Android)
if(NOT ANDROID)
  set_target_properties(zenoh_dart PROPERTIES
    BUILD_RPATH "${ZENOHC_LIB_DIR}"
    INSTALL_RPATH "$ORIGIN"
  )
endif()
```

### Android-specific CMake notes

- `ANDROID_ABI` is set by the NDK CMake toolchain (arm64-v8a, x86_64, etc.)
- `IMPORTED_NO_SONAME TRUE` is required because Android .so files in jniLibs
  don't follow the standard soname convention
- Android's runtime linker finds libraries in the APK's `lib/{ABI}/` directory
  automatically — no RPATH needed
- The existing `"-Wl,-z,max-page-size=16384"` link option for Android 15+ 16KB
  pages should be preserved

### Single-load rationale

The current two-load in `native_lib.dart`:
```dart
// Load zenohc first so its symbols are available to zenoh_dart
zenohcLib;  // <-- this becomes unnecessary
_bindings = ZenohDartBindings(zenohDartLib);
```

After fix:
```dart
_bindings = ZenohDartBindings(zenohDartLib);
// OS linker loads zenohc automatically as DT_NEEDED dependency
```

This works because `libzenoh_dart.so` is linked against `libzenohc.so` at build
time (via `target_link_libraries(zenoh_dart PRIVATE zenohc)`), creating a
`DT_NEEDED` entry. When the OS loads `libzenoh_dart.so`, it automatically loads
`libzenohc.so` from the same directory (Linux: RPATH, Android: APK lib/).

### Git tracking of prebuilt binaries

For Phase P1, prebuilt `.so` files are git-tracked for simplicity. This adds
~40-45 MB to the repo (14.6 MB Linux + ~14 MB arm64 + ~15 MB x86_64).

Ensure `.gitattributes` marks them as binary:
```
*.so binary
```

Future optimization: generate via CI and attach to GitHub releases.
