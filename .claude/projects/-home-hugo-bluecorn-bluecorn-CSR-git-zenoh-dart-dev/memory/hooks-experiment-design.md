# Hooks Experiment Design

**Date**: 2026-03-10
**Status**: ALL COMPLETE. A1 neg (PR#13), A2 pos (PR#14), B1 neg (PR#15), B2 pos (PR#16). @Native mandatory, build strategy irrelevant.

## Scientific Approach

**Question**: Which Dart build hooks approach works best for zenoh-dart's two-library bundling (libzenoh_dart.so + libzenohc.so with DT_NEEDED dependency)?

**Controlled variables**: Same monorepo, same native libs, same zenoh-c v1.7.2, same Dart 3.11.0 / Flutter 3.41.4.

**Independent variables** (two dimensions, one per experiment):
1. Build strategy: both-prebuilt vs CBuilder+prebuilt
2. Loading mechanism: DynamicLibrary.open() vs @Native annotations

## 2x2 Experiment Matrix

| | DynamicLibrary.open() | @Native annotations |
|---|---|---|
| **Both-prebuilt** | A1 (`exp_hooks_prebuilt_dlopen`) | A2 (`exp_hooks_prebuilt_native`) |
| **CBuilder + prebuilt** | B1 (`exp_hooks_cbuilder_dlopen`) | B2 (`exp_hooks_cbuilder_native`) |

```
packages/
  zenoh/                              # control — UNTOUCHED
  exp_hooks_prebuilt_dlopen/          # A1: both-prebuilt + DynamicLibrary.open()
  exp_hooks_prebuilt_native/          # A2: both-prebuilt + @Native annotations
  exp_hooks_cbuilder_dlopen/          # B1: CBuilder + prebuilt + DynamicLibrary.open()
  exp_hooks_cbuilder_native/          # B2: CBuilder + prebuilt + @Native annotations
```

Each experiment package gets:
- Its own `hook/build.dart`
- Its own `pubspec.yaml` with hooks dependencies
- Its own `lessons-learned.md` (living document, updated during experimentation)
- Minimal Dart code to load and call one FFI function (proof of concept)

## Verification Criteria (6 tests per experiment)

Each package is tested against:
1. Does the loading mechanism find bundled libs with `dart run`?
2. Does the loading mechanism find bundled libs with `dart test`?
3. Does `flutter run` find bundled libs? (test Flutter app)
4. Does the DT_NEEDED dependency between the two libs resolve at runtime?
5. Does the hook build succeed on Linux x86_64?
6. Is error reporting adequate when something fails?

## Research Findings (2026-03-10)

### Confirmed: Two build strategies are the only viable approaches
- Link hooks (`hook/link.dart`) are for tree-shaking, not bundling
- `DynamicLoadingSystem()` is for system-installed libs, not bundled
- `StaticLinking` is NOT YET SUPPORTED in Dart/Flutter SDK
- No third build strategy exists

### Critical finding: DynamicLibrary.open() vs @Native
- **`DynamicLibrary.open('libfoo.so')` does NOT automatically find hook-bundled assets**
- `@Native` annotations resolve automatically via asset ID mapping from build hook CodeAsset declarations
- This is why loading mechanism is the second independent variable
- Our current `native_lib.dart` uses `DynamicLibrary.open()` — may not work with hooks

### Platform-specific RPATH
- **Linux**: Must set `$ORIGIN` RPATH at compile time. CBuilder auto-adds `-Wl,-rpath,$ORIGIN`. Post-hoc `patchelf` unreliable. Our CMake already sets `$ORIGIN`.
- **macOS/iOS**: Flutter PR #153054 handles `install_name_tool` rewriting automatically (merged, in 3.41.x)
- **Android**: APK `lib/<abi>/` auto-searched by dynamic linker
- **Windows**: Buggy — open issue #2501 (access violation in native_dynamic_linking tests)

### `dart test` + hooks
- Hooks run automatically during `dart test` since Dart 3.10
- Error reporting is poor — hook failures show only "Couldn't resolve native function" (issue #1966, OPEN)
- Standalone Dart multi-library loading less mature than Flutter (@blaugold found issues with `dart run`/`dart test`/`dart build`)
- Partially addressed but not fully polished for standalone Dart

### `native_toolchain_c` is EXPERIMENTAL
- Pub.dev: "higher expected rate of API and breaking changes"
- Affects B1 and B2 experiments (CBuilder approach)
- A1 and A2 avoid this dependency entirely

### cbl-dart: production-proven two-library precedent
- Uses CBuilder + prebuilt (our Approach B)
- `libcblite.so` (prebuilt) + `libcblitedart.so` (CBuilder-compiled shim linking against cblite)
- Linux soname: copies prebuilt under both versioned and unversioned names
- 2-4 CodeAsset entries per build
- Exact same architecture as zenoh-dart

### native_dynamic_linking: official three-library example
- All CBuilder, sequential compilation, `libraries: ['dep']` parameter
- Builders MUST run sequentially (each depends on previous output)
- Test skipped on macOS and Windows CI (issue #2501)
- Linux works

### sqlite3: canonical single-library reference
- Three modes: prebuilt download, CBuilder compile, external/system
- Uses `hooks.user_defines` for configuration
- Symbol versioning script on Linux to avoid conflicts with system SQLite
- Single library only — no inter-library dependency

### Key API details
- `CodeAsset(package:, name:, linkMode: DynamicLoadingBundled(), file:)` — name becomes asset ID
- `CBuilder.library(name:, sources:, libraries:, libraryDirectories:)` — auto-adds CodeAsset to output
- `OS.linux.dylibFileName('zenoh_dart')` → `'libzenoh_dart.so'`
- All bundled assets go in one flat directory — no namespacing per package
- Only one lib needs asset ID matching Dart library URI; dependency lib gets arbitrary name

### Open issues that could affect experiments
| Issue | Impact | Status |
|-------|--------|--------|
| dart-lang/native#1966 | `dart test` error reporting buried | OPEN |
| dart-lang/native#2501 | macOS/Windows multi-lib broken | OPEN |
| dart-lang/sdk#53732 | Hook build stdout/stderr buried | OPEN |

### Reference sources
- dart.dev/tools/hooks — official hooks documentation
- docs.flutter.dev/platform-integration/bind-native-code — Flutter FFI guide
- pub.dev: hooks ^1.0.2, code_assets ^1.0.0, native_toolchain_c ^0.17.5
- dart-lang/native examples: native_dynamic_linking, sqlite_prebuilt, download_asset
- dart-lang/native#190 (CLOSED) — Code Assets depending on other code assets
- Flutter PR #153054 (MERGED) — install_name rewriting for relocated native libs
- cbl-dart (github.com/cbl-dart/cbl-dart) — two-library production reference
- sqlite3 (github.com/simolus3/sqlite3.dart) — canonical hooks migration

## Decision Criteria (for final analysis)

- Correctness: Does it work on Linux x86_64? Android arm64/x86_64?
- Simplicity: Lines of hook code, number of dependencies
- Developer experience: Can C shim developers iterate without friction?
- Consumer experience: Does `dart pub add zenoh` + `dart run` just work?
- Test compatibility: Does `dart test` find bundled libs?
- pub.dev viability: Can the package be published with this approach?
- Maintainability: How much changes when zenoh-c upgrades?
- Stability: Experimental vs stable dependencies?
