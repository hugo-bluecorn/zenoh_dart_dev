---
name: Android native lib loading gap
description: native_lib.dart and build hook are Linux-only — three changes needed for Android support (loading, hook, cross-compilation)
type: project
---

Android runtime crash discovered 2026-03-12 when running zenoh-counter-flutter on Pixel 9a.

**Symptom**: `StateError: Could not find libzenoh_dart.so. Ensure the build hook has run.` thrown at `ensureInitialized()` (native_lib.dart:83) when user taps Connect.

**Root cause**: Three components are Linux-only:

1. **`native_lib.dart`** — `_resolveLibraryPath()` only searches `native/linux/x86_64/` paths. On Android, `DynamicLibrary.open('libzenoh_dart.so')` (bare name, no path) works because Android's linker auto-searches the APK's `lib/<abi>/` directory. Fix: `Platform.isAndroid` short-circuit before path resolution.

2. **`hook/build.dart`** — hardcoded to `native/linux/x86_64/`. Needs target-aware resolution using `input.config.targetOS` and `input.config.targetArchitecture`. Proposed layout: `native/android/arm64-v8a/`, `native/android/x86_64/`.

3. **Cross-compilation** — `build_zenoh_android.sh` only builds `libzenohc.so` (via cargo-ndk). No script for `libzenoh_dart.so` (C shim, needs NDK CMake toolchain). Both .so files needed per ABI.

**Why:** zenoh-dart was built Linux-first; Android was always planned but deferred. The flutter counter app is the first consumer to exercise the Android path.

**How to apply:** Option A (quick validation) first: manually cross-compile, drop in jniLibs, patch native_lib.dart locally. Then Option B (upstream): platform-aware hook, prebuilt layout, build scripts. Research zenoh-kotlin's approach before designing Option B — it's the reference Android port.
