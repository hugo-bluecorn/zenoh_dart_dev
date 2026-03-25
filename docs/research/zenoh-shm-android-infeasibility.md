# Why Zenoh SHM Cannot Work on Android

**Date:** 2026-03-16
**Author:** CA session (zenoh-dart)
**Status:** Research finding — explains why SHM is excluded on Android

---

## The Call Chain

```
Dart ShmProvider.alloc()
  → C shim zd_shm_provider_alloc()
    → zenoh-c z_shm_provider_alloc()
      → Rust zenoh-shm PosixShmProviderBackendTalc
        → unix.rs: nix::sys::mman::shm_open()    ← LINK ERROR HERE
```

## What Zenoh's SHM Actually Does (Rust Layer)

File: `extern/zenoh/commons/zenoh-shm/src/shm/unix.rs`

Zenoh's `PosixShmSegment` calls **7 POSIX APIs** via the Rust `nix` crate:

| API | Purpose | Line |
|-----|---------|------|
| `shm_open(O_CREAT\|O_EXCL\|O_RDWR)` | Create named SHM object (e.g., `/dev/shm/12345678.zenoh`) | 71 |
| `ftruncate(fd, size)` | Set segment size | 100 |
| `fstat(fd)` | Get actual allocated size (page-aligned) | 104 |
| `mmap(MAP_SHARED\|MAP_NORESERVE)` | Map segment into address space | 273 |
| `mlock()` | Pin pages in RAM (no swap) | 277 |
| `shm_unlink()` | Delete named SHM object on cleanup | 286 |
| `advisory_lock` (fcntl) | Coordinate concurrent access | 87-96 |

Segment names follow the pattern `<random-u128>.zenoh`, created in `/dev/shm/`. Cross-process sharing works because another process can `shm_open()` the same name and `mmap()` it.

The default memory allocator is TALC (`talc` Rust crate), which manages heap allocations within the SHM segment. Alternative backends include buddy_system_allocator and binary_heap.

## Where It Breaks on Android

**`shm_open` does not exist in Android's Bionic libc. Period.**

This is not a runtime error, not a stub returning `ENOSYS`, not a permission denial. The **symbol is not declared, not compiled, and not exported**:

- **`sys/mman.h`** in bionic: declares `mmap`, `mprotect`, `memfd_create` — but **not** `shm_open`/`shm_unlink`
- **`libc.map.txt`** (bionic's exported symbol list): `shm_open` and `shm_unlink` are completely absent at every API level
- **Bionic status.md** classifies them as **"either obsolete or explicitly disallowed by SELinux"** — a will-not-implement decision

This means if you try to compile zenoh-c with `--features shared-memory` targeting Android via cargo-ndk, the Rust `nix` crate tries to link against `shm_open` and you get:

```
undefined reference to `shm_open'
undefined reference to `shm_unlink'
```

**Link-time failure.** The binary cannot even be produced. This is exactly what was reported in zenoh's GitHub discussion #138.

## Why Android Doesn't Have `/dev/shm`

Android deliberately chose a different shared memory model:

| POSIX SHM | Android SHM |
|-----------|-------------|
| Named objects in `/dev/shm` filesystem | Anonymous fd-based regions |
| Any process can open by name | Must receive fd via Binder IPC |
| Persist until `shm_unlink()` called | Auto-cleanup when all fds closed |
| Filesystem permissions | Capability-based (you need the fd) |
| Requires tmpfs mount at `/dev/shm` | No special filesystem needed |

Android doesn't mount `/dev/shm` at all. Its security model is fd-passing via Binder — you can only access shared memory if someone explicitly gives you the file descriptor. This is fundamentally incompatible with POSIX SHM's name-based discovery.

### Android's Shared Memory Timeline

| Mechanism | API Level | Kernel | Status |
|-----------|-----------|--------|--------|
| **ashmem** (`/dev/ashmem`) | All | Custom Android driver | Legacy; removed from mainline Linux 5.18 |
| **ASharedMemory_create()** | 26+ (Android O) | Wraps ashmem | Current NDK API |
| **memfd_create()** | 30+ in bionic | 3.17+ | Modern replacement; Android migrating ashmem internals to memfd |

The NDK API is `ASharedMemory_create(name, size)` which returns an fd, then you `mmap()` it. It supports one-way permission restriction via `ASharedMemory_setProt()`.

## What Would Fix This Upstream

Zenoh would need a new SHM backend in `zenoh-shm` — something like:

```rust
// Hypothetical: zenoh-shm/src/shm/android.rs
#[cfg(target_os = "android")]
impl ShmSegment {
    fn create(size: usize) -> Result<Self> {
        // ASharedMemory_create() instead of shm_open()
        let fd = unsafe { ASharedMemory_create(name, size) };
        let ptr = mmap(fd, size, ...);
        // But how to share the fd cross-process?
        // POSIX SHM shares by name. Android needs Binder IPC.
        // This is an architectural mismatch, not just an API swap.
    }
}
```

The problem is deeper than swapping one syscall for another. Zenoh's SHM protocol assumes **name-based discovery** — publisher creates segment `12345.zenoh`, sends the name in zenoh protocol metadata, subscriber opens the same name. On Android, you'd need to pass file descriptors over Binder or Unix domain sockets, which requires a completely different sharing protocol.

This is why the zenoh discussion #138 has zero replies — it's not a bug fix, it's an architectural change to the SHM transport.

## Why Our Guards Are Correct

Our three-layer exclusion is necessary and correct:

1. **`scripts/build_zenoh_android.sh`** — cargo-ndk builds zenoh-c **without** `--features shared-memory` → the Rust SHM code is not compiled → no link error
2. **`src/CMakeLists.txt`** — `if(NOT ANDROID)` guard prevents `-DZ_FEATURE_SHARED_MEMORY` → C shim SHM functions are `#ifdef`'d out
3. **C shim (`src/zenoh_dart.c`)** — `#if defined(Z_FEATURE_SHARED_MEMORY) && defined(Z_FEATURE_UNSTABLE_API)` around all 13 SHM functions → they don't appear in the Android `.so`

If any layer were missing, you'd get either a link error (layer 1) or undefined symbol at runtime (layers 2-3).

## Real-World Precedent

Other projects that hit this same wall:

- **LLVM ORC JIT** ([#56812](https://github.com/llvm/llvm-project/issues/56812)): Added `#if !defined(__ANDROID__)` guards around SHM code
- **fio benchmark** ([#352](https://github.com/axboe/fio/issues/352)): Cannot build SHM support for Android
- **Termux libandroid-shmem** ([#10](https://github.com/termux/libandroid-shmem/issues/10)): Only emulates SysV IPC, not POSIX SHM
- **Zenoh itself** ([Discussion #138](https://github.com/eclipse-zenoh/roadmap/discussions/138)): `undefined reference to 'shm_open'` when building for Android 13 — unresolved

## Options for Android SHM Support

The `shm_open` calls are in the zenoh Rust crate (Layer 1), not in our C shim or build scripts (Layers 3-4). Our code merely exposes what zenoh-c provides.

```
Layer 4:  Dart API (ShmProvider)           ← WE CONTROL
Layer 3:  C shim (zd_shm_*)               ← WE CONTROL
Layer 2:  zenoh-c (z_shm_*)               ← GENERATED FROM RUST
Layer 1:  zenoh-shm Rust crate (unix.rs)  ← shm_open IS HERE
```

### Option A: Fork zenoh-shm (modify Layer 1)

Add an `android.rs` backend alongside `unix.rs` in the zenoh-shm crate:

```rust
// zenoh-shm/src/shm/mod.rs (currently)
#[cfg(unix)]
mod unix;

// Would need to become:
#[cfg(all(unix, not(target_os = "android")))]
mod unix;
#[cfg(target_os = "android")]
mod android;  // NEW: uses ASharedMemory_create + mmap
```

**Problem**: This changes the cross-process sharing model. zenoh SHM shares segments **by name** — the segment ID travels in zenoh protocol metadata, and the receiver calls `shm_open(name)`. On Android, there are no named SHM objects. You'd need to pass file descriptors via Binder/Unix sockets, which means changing the zenoh **transport protocol** too — not just the memory backend.

This is a significant upstream contribution, not a local patch.

### Option B: Bypass zenoh SHM entirely (Android ASharedMemory project)

Use Android's `ASharedMemory` API independently of zenoh's SHM:

```
zenoh pub/sub (network bytes) → Flutter writer → ASharedMemory write
                                                      ↓ fd via AIDL
                                                  Reader apps (mmap read)
```

zenoh transports the data over the network as regular bytes. The Android SharedMemory part is purely local IPC, separate from zenoh. No upstream changes needed. This is the architecture designed in the `zenoh-counter-shm-android` proposal (see `memory/android-shm-ipc-research.md`).

### Option C: Contribute an Android SHM backend upstream

Same as Option A, done properly as an Eclipse Zenoh contribution. Would require:

1. New `android.rs` SHM segment implementation using `ASharedMemory_create`
2. New fd-passing transport mechanism (Binder or Unix domain sockets)
3. Protocol extension for fd-based segment sharing
4. Upstream review and acceptance

This is months of work and requires buy-in from the zenoh maintainers.

### Recommendation

**Option B is the pragmatic path.** It works today with no upstream dependencies. zenoh handles network transport, Android ASharedMemory handles local IPC. They compose cleanly.

Options A/C would only matter for **zero-copy SHM transport between two zenoh processes on the same Android device** (two apps sharing memory directly via zenoh's SHM protocol). For our use case — C++ publisher → router → WiFi → Android — the SHM benefit is already captured on the publisher side, and data crosses the network as regular bytes regardless.

## Authoritative Sources

- [Android bionic status.md](https://android.googlesource.com/platform/bionic/+/master/docs/status.md) — lists shm_open as "obsolete or explicitly disallowed by SELinux"
- [bionic libc.map.txt](https://android.googlesource.com/platform/bionic/+/master/libc/libc.map.txt) — symbol export list, shm_open absent
- [bionic sys/mman.h](https://android.googlesource.com/platform/bionic/+/master/libc/include/sys/mman.h) — no shm_open declaration
- [bionic sys/shm.h](https://android.googlesource.com/platform/bionic/+/master/libc/include/sys/shm.h) — SysV only, "Not useful on Android"
- [Android NDK ASharedMemory API](https://developer.android.com/ndk/reference/group/memory) — Android's replacement
- zenoh SHM source: `extern/zenoh/commons/zenoh-shm/src/shm/unix.rs`
