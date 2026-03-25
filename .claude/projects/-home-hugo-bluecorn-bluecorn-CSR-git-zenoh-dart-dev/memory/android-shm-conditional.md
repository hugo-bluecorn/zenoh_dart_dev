---
name: Android SHM full analysis — upstream blocker, workaround, and future path
description: Comprehensive analysis of why zenoh SHM cannot work on Android (POSIX shm_open missing in Bionic), our four-layer exclusion workaround, how SHM works today on Linux vs Android, and what upstream/local changes would be needed if zenoh adds Android SHM support
type: project
---

## Root Cause: POSIX shm_open Missing on Android

Zenoh's SHM is 100% POSIX-based. The call chain is:
- zenoh Rust crate -> `PosixShmProviderBackend` -> `shm_open()` / `shm_unlink()`
- Android Bionic libc does NOT implement `shm_open` — explicitly missing, blocked by SELinux

There is **no alternative SHM backend** in zenoh. The `CSHMProvider` enum has variants (Posix, SharedPosix, Dynamic, DynamicThreadsafe) but all use `PosixShmProviderBackend`. No ASharedMemory provider, no Windows provider.

**Why:** This is a hard blocker at the Rust level. Cannot be worked around with build flags alone — even if you compiled zenoh-c with `--features shared-memory` on Android, the resulting binary would fail at runtime on `shm_open`.

## Our Four-Layer Exclusion Workaround (applied 2026-03-12)

| Layer | Mechanism | Effect |
|-------|-----------|--------|
| **cargo-ndk** | `build_zenoh_android.sh` doesn't pass `--features=shared-memory` | zenoh-c Rust `shm/` module not compiled |
| **CMake** | `src/CMakeLists.txt`: `if(NOT ANDROID)` | C shim SHM compile flags not defined |
| **C preprocessor** | `#if defined(Z_FEATURE_SHARED_MEMORY) && defined(Z_FEATURE_UNSTABLE_API)` | 13 C shim functions excluded from .so |
| **Dart API** | **None** — ShmProvider/ShmMutBuffer exported unconditionally | Gap: symbol-not-found crash on Android if called |

**Known gap:** The Dart layer has no platform guard. Calling `ShmProvider()` on Android produces a raw FFI symbol-not-found error instead of a clean exception. Low priority — SHM is a developer-facing API and the limitation is documented.

## How SHM Works Today

**Linux/macOS (full support):**
- `ShmProvider.alloc()` -> `zd_shm_provider_alloc()` -> `z_shm_provider_alloc()` -> `PosixShmProviderBackend` -> `shm_open()` + `mmap()` -> zero-copy buffer -> `publisher.putBytes()` -> zenoh network

**Android (transparent fallback):**
- SHM **publishing**: impossible (no POSIX SHM)
- SHM **receiving**: works transparently — zenohd deserializes SHM data before forwarding over TCP. Android subscriber receives normal ZBytes, no SHM awareness needed
- This is how the counter demo works: C++ SHM pub -> zenohd -> WiFi -> Pixel 9a -> standard subscriber

## What Upstream Would Need to Fix

1. A pluggable SHM backend trait (may already exist as `ShmProviderBackend` in Rust)
2. An `ASharedMemoryBackend` implementation using NDK API 26+ (`ASharedMemory_create`, `ASharedMemory_setProt`, standard `mmap` with ASharedMemory fds)
3. `#[cfg(target_os = "android")]` conditional in zenoh's SHM module to select ASharedMemory over POSIX
4. zenoh-c feature flag updates to expose Android backend through the same C API

**Note:** eclipse-zenoh/roadmap/discussions/138 is NOT directly relevant — it's about zenoh's general SHM roadmap, not Android-specific. Do not track or respond to it.

## What Would Change In Our Code If Upstream Fixes It

| Our Layer | Change Needed |
|-----------|---------------|
| zenoh-c submodule | Bump to version with Android SHM |
| cargo-ndk build | Add `--features=shared-memory` to `build_zenoh_android.sh` |
| CMake | Remove `if(NOT ANDROID)` guard — define SHM flags for all platforms |
| C shim | Nothing — same 13 functions, same guards (now active on Android) |
| Dart API | Nothing — ShmProvider/ShmMutBuffer already exported unconditionally |
| Tests | Add Android SHM integration tests |

The Dart API's lack of platform guards goes from "gap" to "correct by design." The C shim functions are platform-agnostic wrappers — they work unchanged once zenoh-c's underlying backend supports Android.

**How to apply:** Do NOT attempt to enable SHM on Android by just passing `--features shared-memory` to cargo-ndk. It would compile but crash at runtime on `shm_open`. Wait for upstream to provide an ASharedMemory-backed provider.
