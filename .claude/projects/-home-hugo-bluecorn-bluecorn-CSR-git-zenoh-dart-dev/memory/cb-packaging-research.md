# CB Packaging Research — Complete Analysis

## Goal

Make `zenoh_dart` consumable via `pubspec.yaml` for any new Dart/Flutter app.
Target platforms: Linux and Android first.

## Flutter Version

- Flutter 3.41.2, Dart 3.11.0 (via fvm)
- Supports hook/build.dart (requires Dart >=3.10.0) — but deferred to future phase
- Clang ecosystem throughout (Clang compiler, NDK Clang for Android)

## Current State of zenoh_dart

### Completed Phases

- **Phase 0 (Bootstrap)**: C shim (42 functions), FFI bindings, core Dart API
  (Config, Session, KeyExpr, ZBytes, ZenohException)
- **Phase 1 (put/delete)**: `zd_put`, `zd_delete`, CLI examples
- **Phase 2 (subscriber)**: Callback subscriber with NativePort bridge

### Three Packaging Blockers

1. **libzenohc.so is NOT bundled** — `linux/CMakeLists.txt:17-21` only bundles
   `libzenoh_dart.so`, not `libzenohc.so`
2. **Build requires hardcoded local path** — `src/CMakeLists.txt:31-36` uses
   `find_library` pointing only at `extern/zenoh-c/target/release` with
   `NO_DEFAULT_PATH`
3. **Android has no cross-compiled zenohc** — no mechanism exists

### Current Architecture

- Two native libraries: `libzenohc.so` (zenoh-c) + `libzenoh_dart.so` (C shim)
- `native_lib.dart` explicitly loads BOTH: `_openZenohc()` first, then `_openZenohDart()`
- C shim (`src/zenoh_dart.c`) wraps zenoh-c macros, uses Dart native API DL for callbacks
- 42 C shim functions currently

### Current Build Files

| File | Role | Blocker? |
|------|------|----------|
| `src/CMakeLists.txt` | Shared: compiles C shim, links zenohc | YES — hardcoded extern/ path |
| `linux/CMakeLists.txt` | Linux: add_subdirectory(../src), bundled_libraries | YES — missing libzenohc.so |
| `windows/CMakeLists.txt` | Windows: same pattern as linux | YES — same issue |
| `android/build.gradle` | Android: externalNativeBuild → ../src/CMakeLists.txt | YES — no jniLibs |
| `ios/zenoh_dart.podspec` | iOS: Classes/**/* forwarder | Not addressed in Phase 1 |
| `macos/zenoh_dart.podspec` | macOS: Classes/**/* forwarder | Not addressed in Phase 1 |
| `ffigen.yaml` | FFI binding generation | No change needed |

---

## Ecosystem Research

### zenoh-kotlin (closest analog)

- Uses Rust JNI bridge (`zenoh-jni`), NOT zenoh-c directly
- Links `zenoh` Rust crate → produces ONE .so per ABI (`libzenoh_jni.so`)
- Android: `rust-android-gradle` plugin (org.mozilla.rust-android-gradle:0.9.6)
- cargo config: `targets = ["arm", "arm64", "x86", "x86_64"]`
- NDK version: 26.0.10792818
- Runtime: `System.loadLibrary("zenoh_jni")` — single load
- Published to Maven Central as AAR with jniLibs
- Key file: `extern/zenoh-kotlin/zenoh-kotlin/build.gradle.kts`

### zenoh-c release artifacts (v1.7.2)

GitHub release includes standalone ZIPs for 11 targets (NO Android):
```
zenoh-c-1.7.2-x86_64-unknown-linux-gnu-standalone.zip contains:
  lib/libzenohc.a (37.7 MB)
  lib/libzenohc.so (14.6 MB)
  lib/pkgconfig/zenohc.pc
  lib/cmake/zenohc/zenohcConfig.cmake
  lib/cmake/zenohc/zenohcConfigVersion.cmake
  include/zenoh.h, zenoh_commons.h, zenoh_opaque.h, zenoh_macros.h, ...
```

Download URL pattern:
`https://github.com/eclipse-zenoh/zenoh-c/releases/download/1.7.2/zenoh-c-1.7.2-{target}-standalone.zip`

Available Linux targets: x86_64-unknown-linux-gnu, aarch64-unknown-linux-gnu,
x86_64-unknown-linux-musl, aarch64-unknown-linux-musl, arm variants.

**ZERO Android targets in releases.**

### zenoh-c static library support

- `Cargo.toml`: `crate-type = ["cdylib", "staticlib"]` — produces both .so and .a
- CMake targets: `zenohc::shared`, `zenohc::static`, `zenohc::lib` (alias)
- Static lib transitive deps (Unix): rt pthread m dl
- Static lib transitive deps (Android/Bionic): different — no separate rt/pthread

### zenoh-cpp dependency resolution pattern

`cmake/helpers.cmake` implements `configure_include_project()` with THREE fallback
strategies:
1. **PATH** → `add_subdirectory(local_path)` — submodule
2. **PACKAGE** → `find_package(zenohc)` — installed prefix
3. **GIT_URL** → `FetchContent` — clone and build from git

User can override with `-DZENOHC_SOURCE=PACKAGE` etc.
The standalone release ZIP is designed for strategy #2 (extract, point
CMAKE_PREFIX_PATH).

### dart_zenoh_xplr (reference project)

Path: `/home/hugo-bluecorn/bluecorn/CSR/git/dart_zenoh_xplr`

- Dynamic linking: two .so files (libzenohc.so + libdart_zenoh_wrapper.so)
- Android: prebuilt libzenohc.so in `android/src/main/jniLibs/arm64-v8a/` (12.4 MB)
  - Built via `scripts/build_zenoh_android.sh` using `cargo-ndk`
  - NOT tracked in git (*.so in .gitignore)
- Linux: libzenohc.so bundled explicitly in `linux/CMakeLists.txt` via
  `bundled_libraries` (THREE entries: dart_zenoh + dart_zenoh_wrapper + libzenohc.so)
- Dart loads ONLY the wrapper library; OS linker resolves zenohc as transitive dep
- RPATH set on desktop for library discovery
- `src/CMakeLists.txt` uses `IMPORTED_NO_SONAME TRUE` for Android
- Key: symlink resolution with `get_filename_component(REAL_SOURCE_DIR ... REALPATH)`
- Platform-aware zenohc discovery in CMake:
  - Android: `jniLibs/${ANDROID_ABI}`
  - Desktop: `extern/zenoh-c/target/release`
- Library existence check: graceful degradation if not found
- Android: NO RPATH, NO SONAME (APK lib/ structure handles discovery)
- Android: `"-Wl,-z,max-page-size=16384"` for Android 15+ 16KB pages
- Android: links `log` library for `__android_log_print`

### zenoh-demos Android apps

Three complete Android apps in `extern/zenoh-demos/zenoh-android/`:
- ZenohApp, RobotTeleop, LocationTracker
- All consume `org.eclipse.zenoh:zenoh-kotlin-android:1.3.0` from Maven Central
- Just `implementation("org.eclipse.zenoh:zenoh-kotlin-android:1.3.0")` in build.gradle
- This is the UX bar to match

### Existing pub.dev zenoh_dart package

- Version 0.2.0, by M-PIA (unverified publisher)
- Uses download-on-demand: `dart run tool/fetch_zenoh_binaries.dart`
- Fetches from zenoh-c GitHub releases with SHA-256 verification
- Supports Linux/macOS/Windows but NOT Android

### cargo-ndk (v4.1.2)

Path: `extern/cargo-ndk`

- CLI: `cargo ndk -t <ABI> -P <API_LEVEL> -o <OUTPUT_DIR> build --release`
- Target mapping:
  - arm64-v8a ↔ aarch64-linux-android
  - armeabi-v7a ↔ armv7-linux-androideabi
  - x86 ↔ i686-linux-android
  - x86_64 ↔ x86_64-linux-android
- Acts as linker wrapper: sets itself as `CARGO_TARGET_<TRIPLE>_LINKER`, spawns
  clang with `--target=<triple><api_level>`
- Sets CC, CXX, AR, RANLIB, CFLAGS, CXXFLAGS, BINDGEN_EXTRA_CLANG_ARGS for NDK
- Exports `CARGO_NDK_CMAKE_TOOLCHAIN_PATH` pointing to `android.toolchain.cmake`
- Output: creates `<output>/<abi>/lib*.so` (jniLibs structure)
- Only copies `cdylib` artifacts
- Min NDK: r23, min Rust: 1.68.0
- 64-bit targets get `-Wl,-z,max-page-size=16384` for NDK <=27 (automatic)

### Flutter native assets (hook/build.dart)

Production-ready packages:
- `hooks` 1.0.0, `native_toolchain_c` 0.17.4, `code_assets` 1.0.0
- Flutter's own integration tests use it (`link_hook`, `hook_user_defines`)
- Requires Dart SDK >=3.10.0

**Deferred to future phase** because:
- `CBuilder` compiling C shim + linking against external prebuilt libzenohc is unproven
- No reference project does this exact two-library pattern
- Android prebuilt source problem exists regardless of approach

---

## Approach Evaluation

### Approach A: Traditional FFI Plugin + Prebuilt Binaries (CHOSEN for Phase 1)

- Keep CMakeLists.txt / build.gradle architecture
- Ship prebuilt libzenohc.so inside package (or next to it for dev)
- Android: `android/src/main/jniLibs/{ABI}/libzenohc.so` — Gradle auto-bundles
- Linux: add libzenohc.so to `zenoh_dart_bundled_libraries` in `linux/CMakeLists.txt`
- C shim compiled from source by Flutter build system (CMake + Clang)
- Proven by: dart_zenoh_xplr
- Pros: no Flutter version req, no network dep, proven pattern
- Cons: ~25-50 MB package (prebuilt binaries), multiple platform build files

### Approach B: hook/build.dart (Native Assets) — DEFERRED to Phase 2+

- Single `hook/build.dart` replaces all OS-specific build files
- Downloads prebuilt libzenohc from zenoh-c GitHub releases at build time
- Compiles C shim via `package:native_toolchain_c`
- BLOCKER: CBuilder linking against external prebuilt = uncharted territory
- BLOCKER for Android: no upstream Android prebuilts from zenoh-c

### Approach H: Hybrid — DEFERRED to Phase 2+

- hook/build.dart for Linux (download from releases), traditional jniLibs for Android
- Best of both worlds but adds complexity for Phase 1

### Recommendation

Phase 1: Approach A uniformly (proven, unblocks consumption fastest)
Phase 2: Migrate Linux to hook/build.dart (experiment with lower risk)
Phase 3: Migrate Android to hook/build.dart (once self-hosted prebuilts exist)

---

## Decisions Made

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Phase 1 approach | Approach A (traditional) | Proven, lowest risk, fastest to unblock |
| Dart loading | Single-load | Once bundling works, OS linker resolves zenohc as transitive dep. Two-load was a workaround for broken bundling. dart_zenoh_xplr proves single-load works. |
| Android ABIs | arm64-v8a + x86_64 | arm64-v8a for real devices, x86_64 for emulator testing |
| Prebuilt hosting | Git-tracked for Phase 1 | Simplicity; migrate to CI release artifacts later |
| Build toolchain | Clang everywhere | CMake + Clang on Linux, NDK Clang on Android, cargo-ndk wraps NDK Clang |
| CBuilder | NOT used in Phase 1 | Only relevant to hook/build.dart (deferred) |
| Phase doc | Yes | Substantial enough for own phase doc, CZ implements via /tdd-plan |

## Open Questions (for future phases)

1. Should hook/build.dart migration be Phase 2 or later?
2. Self-hosted Android prebuilt hosting: GitHub releases on zenoh_dart repo? CI artifacts?
3. iOS/macOS: when to tackle? (need prebuilt frameworks, CocoaPods vendored_frameworks)
4. Static vs dynamic linking: revisit if package size becomes a concern
5. armeabi-v7a: add for older 32-bit Android devices?

## Submodules Available

- extern/zenoh-c (v1.7.2)
- extern/zenoh-cpp
- extern/zenoh-kotlin
- extern/zenoh-demos
- extern/cargo-ndk (v4.1.2)
