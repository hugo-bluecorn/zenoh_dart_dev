---
name: Android ASharedMemory IPC research for Flutter
description: Full research on Android SharedMemory IPC between Flutter apps — ASharedMemory APIs, AIDL fd passing, Dart FFI mmap, proposed zenoh-counter-shm-android monorepo architecture
type: project
---

## Context

User wants a new project where a Flutter/Android writer app receives counter values via zenoh and writes them to Android SharedMemory, and two separate Flutter/Android reader apps read from the same shared memory region.

**Why:** Demonstrate Android-native IPC (ASharedMemory) bridged by zenoh — a template for zero-copy local data sharing on Android.

**How to apply:** When this project starts, use this research as the design foundation. The architecture is validated through research but not yet implemented.

## Key Finding: Zenoh SHM Cannot Work on Android

Zenoh's `PosixShmProvider` uses `shm_open`/`shm_unlink` internally. Android's Bionic libc does **not** provide `shm_open` — explicitly listed as missing, blocked by SELinux. This is a hard blocker at the Rust level. Zenoh would need an upstream `ASharedMemory`-backed SHM provider (doesn't exist; GitHub discussion #138 unresolved).

Therefore this project uses **Android's own ASharedMemory API** (independent from zenoh SHM).

## Android SharedMemory APIs

- `ASharedMemory_create(name, size)` — NDK API level 26+ (`<android/sharedmem.h>`), returns fd
- `android.os.SharedMemory` — Java/Kotlin API level 26+, implements `Parcelable`
- fd shared cross-process via `ParcelFileDescriptor` over Binder (AIDL)
- `ASharedMemory_setProt(fd, PROT_READ)` — one-way ratchet, enforced at kernel level
- ARM64 aligned int64 loads/stores are naturally atomic — no barriers needed for single-writer/single-reader

## Proposed Architecture

```
C++ SHM Pub -> zenohd -> WiFi -> Writer App (zenoh sub -> ASharedMemory write)
                                      | fd via AIDL Bound Service
                                +-----+-----+
                            Reader A     Reader B
                           (mmap read)  (mmap read)
                            poll 100ms   poll 100ms
```

## Proposed Project Structure: zenoh-counter-shm-android

Melos monorepo with two Flutter apps + shared package:

```
zenoh-counter-shm-android/
  apps/
    writer/          # Flutter app: zenoh subscriber + ASharedMemory writer + AIDL Service
    reader/          # Flutter app: AIDL client + mmap reader (NO zenoh dependency)
  packages/
    shm_common/      # Shared Dart FFI: libc mmap/munmap/close bindings, constants
```

### Writer App
- Subscribes to zenoh counter topic, decodes int64 LE
- Creates `android.os.SharedMemory.create("counter", 8)` in Kotlin Service
- Maps read/write, writes counter via platform channel or Dart FFI mmap
- Runs AIDL Bound Service (`ISharedMemoryService.getSharedMemoryFd()`) exposing `ParcelFileDescriptor`
- Calls `ASharedMemory_setProt(fd, PROT_READ)` after own mmap (readers get read-only)
- `android:exported="true"` + signature-level custom permission

### Reader App
- Binds to writer's AIDL service via platform channel (`bindService` + `ServiceConnection`)
- Gets `ParcelFileDescriptor`, calls `detachFd()` for ownership
- Passes raw int fd to Dart via MethodChannel
- Dart FFI: `mmap(NULL, 8, PROT_READ, MAP_SHARED, fd, 0)` via `DynamicLibrary.open('libc.so')`
- `Timer.periodic(100ms)` reads `Pointer<Int64>.value`, emits changes to StreamController
- **No zenoh dependency** — proves SHM works independently

### AIDL Interface (identical in both apps)
```aidl
package com.bluecorn.shm_writer;
import android.os.ParcelFileDescriptor;
interface ISharedMemoryService {
    ParcelFileDescriptor getSharedMemoryFd();
}
```

### shm_common Package
- `libc_bindings.dart`: mmap, munmap, close via `DynamicLibrary.open('libc.so')`
- Constants: PROT_READ (0x1), PROT_WRITE (0x2), MAP_SHARED (0x01)

## Key Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| SHM API | `android.os.SharedMemory` (Java) | Simpler than NDK JNI; Parcelable for free |
| fd passing | AIDL Bound Service | Android-blessed cross-app IPC |
| Change notification | Timer poll 100ms | ARM64 atomic int64; 1Hz doesn't need eventfd |
| Security | signature-level permission | Both apps same signing key |
| minSdkVersion | 26 | ASharedMemory requires API 26 (Android 8.0, 2017) |
| Reader zenoh dep | None | Proves SHM independence |

## Open Design Questions (not yet decided)

1. **Writer SHM writes**: Platform channel (Kotlin ByteBuffer) vs Dart FFI mmap? Platform channel simpler for 1Hz; FFI better for higher frequencies.
2. **AIDL file sync**: Monorepo keeps one source of truth, but could also use a symlink or gradle copy task.

## References

- Android NDK Memory API: developer.android.com/ndk/reference/group/memory
- Android SharedMemory Java API: developer.android.com/reference/android/os/SharedMemory
- Android bionic missing functions: android.googlesource.com/platform/bionic/+/master/docs/status.md
- ~~Zenoh SHM on Android discussion: github.com/eclipse-zenoh/roadmap/discussions/138~~ — **NOT relevant to our work.** That discussion is about zenoh's own SHM roadmap at the Rust/core level (PosixShmProvider). Our project uses Android-native ASharedMemory independently from zenoh SHM — it's a separate design, not a fix for #138. Do not respond to or track that issue.
