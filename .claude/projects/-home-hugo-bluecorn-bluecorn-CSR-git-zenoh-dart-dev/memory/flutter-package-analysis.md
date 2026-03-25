# zenoh_flutter Package Analysis (2026-03-07)

## Question
Should zenoh-dart create a separate `zenoh_flutter` package (Flutter plugin) or is the pure Dart `zenoh` package sufficient for Flutter apps?

## Three Approaches

### A) Pure Dart Only (current state)
- `packages/zenoh/` loads `libzenoh_dart.so` via `DynamicLibrary.open()` (bare name, OS linker resolves)
- CLI/Serverpod: set LD_LIBRARY_PATH — works today
- Flutter Android: consumer must manually place .so files in `android/app/src/main/jniLibs/<abi>/`
- Flutter Linux: consumer must modify CMakeLists.txt to bundle .so files
- No `flutter test` support (can't find native libraries)
- Fine for internal apps; poor "just add to pubspec" experience for external consumers

### B) Pure Dart + zenoh_flutter Plugin Wrapper
- zenoh_flutter is thin: CMake per platform + one-line Dart re-export (`export 'package:zenoh/zenoh.dart'`)
- Flutter's build system auto-invokes plugin CMake per platform
- Android: Gradle picks up CMakeLists.txt, builds C shim, bundles .so files into APK
- Linux: Flutter CMake invokes plugin CMake, bundles via `${PLUGIN}_bundled_libraries`
- Proven pattern (sqlite3_flutter_libs did this for years)
- Monorepo already structured for this (`packages/*` workspace glob)
- Flutter officially calls plugin_ffi "legacy" but not removing it

### C) Native Assets (hook/build.dart)
- Official forward-looking recommendation (stable since Dart 3.10 / Flutter 3.38)
- Single package for both Dart and Flutter
- `hook/build.dart` runs at build time, declares CodeAssets
- Can use `@Native` annotations (replaces DynamicLibrary.open) or `DynamicLoadingBundled()`
- sqlite3 successfully migrated (but their case is simpler — single self-contained .c file)

## The Two-Library Problem (Unique to zenoh-dart)
- Most FFI packages ship ONE native library
- zenoh-dart ships TWO: `libzenoh_dart.so` (C shim) depends on `libzenohc.so` (zenoh-c, built from Rust)
- `libzenohc.so` is linked via DT_NEEDED — both must be findable by OS linker at runtime
- No native_assets toolchain can invoke Cargo — libzenohc.so must ALWAYS be prebuilt
- This complicates all three approaches

## C Approach Blockers (as of 2026-03-07)
- No `native_toolchain_cmake` exists (dart-lang/native#2036 is a proposal only)
- `native_toolchain_c` (CBuilder) can compile simple C but can't drive CMake builds
- C shim depends on zenoh-c headers (`extern/zenoh-c/include/`) — hook must vendor or download them
- Two CodeAsset declarations needed (or transitive loading must work)
- Hook complexity significantly higher than sqlite3's migration
- Would require ffigen regeneration for @Native annotations (or @DefaultAsset workaround)

## Recommendation: A -> B -> C Progression

| Timeframe | Approach | Trigger |
|-----------|----------|---------|
| Now (counter MVP) | A | Internal app, manual .so placement documented |
| Medium term | B | External Flutter consumers, pub.dev publication |
| Long term | C | When native_toolchain_cmake lands and stabilizes |

## Key Insight
There is NO API reason for zenoh_flutter. It would contain zero Dart logic — just CMake files and a re-export. The question is purely about native library distribution mechanics.

## Reference Sources
- Dart Hooks docs: https://dart.dev/tools/hooks
- Flutter FFI binding: https://docs.flutter.dev/platform-integration/bind-native-code
- Simon Binder's native_assets migration: https://www.simonbinder.eu/posts/native_assets/
- dart-lang/native#2036: native_toolchain_cmake proposal
- Flutter #181694: FFI package with cmake dependencies
- sqlite3 package (migrated to hooks): https://pub.dev/packages/sqlite3
- sqlite3_flutter_libs (deprecated in favor of hooks): https://pub.dev/packages/sqlite3_flutter_libs

## Files Referenced
- `packages/zenoh/lib/src/native_lib.dart` — current DynamicLibrary.open() loading
- `src/CMakeLists.txt` — three-tier native discovery (Android jniLibs, prebuilt, developer fallback)
- `scripts/build_zenoh_android.sh` — Android cross-compilation
- `packages/zenoh/ffigen.yaml` — DynamicLibrary-based binding generation
