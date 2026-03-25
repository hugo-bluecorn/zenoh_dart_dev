# Phase Coordination: Pure Dart Package

## Problem
Phase 0 and P1 were written for a Flutter FFI plugin. The new project is a pure Dart package in a Melos monorepo. Both phase docs need updating before TDD execution.

## Phase 0 (Bootstrap) — Changes

| Original (Flutter plugin) | New (Pure Dart + Melos) |
|--------------------------|------------------------|
| `flutter create --template=plugin_ffi` scaffold | `dart create --template=package` scaffold |
| `lib/zenoh_dart.dart` with sum() placeholder | `lib/zenoh.dart` (empty barrel) |
| `lib/zenoh_dart_bindings_generated.dart` | `lib/src/bindings.dart` |
| `flutter analyze` / `flutter test` | `fvm dart analyze` / `fvm dart test` |
| CMake via Flutter build system | Standalone CMake at monorepo `src/CMakeLists.txt` |
| Tests find libs via Flutter bundle | Tests use `LD_LIBRARY_PATH` |
| Platform dirs (android/, linux/, etc.) | No platform dirs (pure Dart) |

Core work UNCHANGED: C shim functions, Dart API classes, FFI bindings.

## Phase P1 (Packaging) — Changes

| Original (Flutter plugin) | New (Pure Dart + Melos) |
|--------------------------|------------------------|
| `linux/CMakeLists.txt` bundled_libraries | **Deferred to Phase PF** (zenoh_flutter) |
| `android/build.gradle` + jniLibs | **Deferred to Phase PF** |
| `flutter build apk/linux` verification | `fvm dart test` with `LD_LIBRARY_PATH` |
| Single-load simplification | Already in scaffold |
| 3-tier CMake discovery | Still relevant for standalone build |
| Prebuilt Linux libzenohc.so | Still relevant |
| Android build script | Reference for Phase PF |

## Phase P1 for zenoh (reduced scope)
1. 3-tier CMake discovery in standalone `src/CMakeLists.txt`
2. Prebuilt Linux `native/linux/x86_64/libzenohc.so` (built from scratch)
3. Android build script (reference material)
4. Test infrastructure (LD_LIBRARY_PATH helpers)
5. RPATH configuration

## Phase 1+ — Inherently Pure Dart
All feature phases (put/delete, subscriber, publisher, etc.) are pure Dart + C FFI.
Only build/test commands change (`flutter` → `fvm dart`).
The tdd-planner updates each phase doc at planning time.

## Chain: Phase 0 → P1 → Phase 1

### Phase 0 produces:
- C shim with zenoh-c functions (session, config, keyexpr, bytes)
- Dart API classes (Config, Session, KeyExpr, ZBytes, ZenohException)
- Working standalone CMake build
- Passing tests with LD_LIBRARY_PATH

### Phase P1 consumes Phase 0 output, adds:
- 3-tier CMake (dev fallback already from Phase 0; P1 adds prebuilt tiers)
- Prebuilt Linux libzenohc.so
- Improved test infrastructure

### Phase 1 consumes Phase 0+P1 output, adds:
- Session.put(), Session.delete() methods
- CLI examples (bin/z_put.dart, bin/z_delete.dart)

**NO CONFLICTS** — each phase builds cleanly on the previous.

## Phase PF (Future): zenoh_flutter
Separate Flutter plugin package in the monorepo:
- `packages/zenoh_flutter/`
- Depends on `package:zenoh` for the Dart API
- bundles prebuilt libzenoh_dart.so + libzenohc.so
- Platform-specific: android/build.gradle, linux/CMakeLists.txt, ios/podspec
- bundled_libraries, jniLibs, abiFilters
- All the Flutter-specific P1 work lives here
