# RTLD_LOCAL Crash Investigation (2026-03-11)

## Bug Report: Inter-Process SIGSEGV/SIGBUS When Two Dart Processes Connect

### Problem Statement

After the hooks migration (PR #18), any two separate Dart processes that both
load `libzenohc.so` via `@Native` build hooks crash when they establish a TCP
connection via zenoh. The **listener** process crashes; the connector is fine.
No data transfer is required — just `Session.open()` with TCP listen/connect
on each side triggers the crash.

The crash was first observed running `zenoh-counter-dart`'s publisher and
subscriber in separate terminals. It also reproduces with zenoh-dart's own
`z_pub.dart` + `z_sub.dart` examples.

### Crash Signature

```
===== CRASH =====
si_signo=Segmentation fault(11), si_code=SEGV_MAPERR(1), si_addr=(nil)
pid=XXXX, thread=YYYY, isolate_group=(nil), isolate=(nil)
pc=0
```

- Crash on a **non-Dart thread** (isolate_group=nil) — a tokio worker thread
  inside libzenohc.so
- `pc=0` = null function pointer dereference

### GDB Stack Trace (Thread 19 "app-0")

```
#0  0x0000000000000000 in ?? ()
#1  tokio::runtime::io::scheduled_io::ScheduledIo::wake()  [libzenohc.so]
#2  tokio::runtime::io::driver::Driver::turn()              [libzenohc.so]
#3  tokio::runtime::time::Driver::park_internal()           [libzenohc.so]
#4  tokio::runtime::scheduler::multi_thread::worker::Context::park_internal()
#5  tokio::runtime::scheduler::multi_thread::worker::run()
...
#9  std::sys::thread::unix::Thread::new::thread_start()
```

The crash is in tokio's I/O event driver calling `ScheduledIo::wake()` with a
null waker function pointer. This is inside `libzenohc.so`'s Rust runtime, NOT
in our C shim or subscriber callback.

### Investigation Methodology

**Systematic isolation via 6 inter-process test combinations:**

| Publisher | Subscriber | Result |
|-----------|-----------|--------|
| zenoh-c native (z_pub) | zenoh-c native (z_sub) | **PASS** |
| zenoh-c native (z_pub) | Dart (z_sub.dart) | **PASS** — 7 messages received |
| Dart (z_pub.dart) | zenoh-c native (z_sub) | **PASS** |
| Dart (z_pub.dart) | Dart (z_sub.dart) | **CRASH** — subscriber crashes |
| Dart (empty Session) | Dart (empty Session) | **CRASH** — listener crashes |
| Dart (LD_PRELOAD) | Dart (LD_PRELOAD) | **PASS** |

**Key observations:**
- All 185 in-process tests pass (two sessions, same process, same tokio runtime)
- Crash requires TWO SEPARATE Dart processes connecting — no data needed
- zenoh-c native examples (compiled C, same libzenohc.so binary by md5sum) work
  fine in all combinations
- SHM transport disabled (`transport/shared_memory/enabled: false`) still crashes
- libzenohc.so rebuilt WITHOUT SHM features still crashes
- `LD_PRELOAD=libzenohc.so` on both processes **completely fixes the crash**
- `LD_PRELOAD=libzenohc.so` (without libzenoh_dart.so) also fixes it

**Library identity verified:**
```
md5sum extern/zenoh-c/target/release/libzenohc.so = 71384a9fca9ceb098c491c5176b4c447
md5sum packages/zenoh/native/linux/x86_64/libzenohc.so = 71384a9fca9ceb098c491c5176b4c447
```
Same binary in both locations.

### Root Cause Analysis

**`libzenohc.so` loaded with `RTLD_LOCAL` causes tokio's waker vtable dispatch
to fail on worker threads.**

When `@Native` resolves `libzenoh_dart.so`, it calls `dlopen()` with
`RTLD_LAZY` (default, which implies `RTLD_LOCAL`). The DT_NEEDED dependency
`libzenohc.so` inherits these flags. Under `RTLD_LOCAL`, the library's symbols
are not visible in the global symbol namespace.

`LD_PRELOAD` forces `RTLD_GLOBAL` loading before the Dart VM starts. The Linux
dlopen man page states: "If a library previously loaded with RTLD_LOCAL is
reopened with RTLD_GLOBAL, the RTLD_GLOBAL flag takes effect."

The likely mechanism is that Rust's tokio runtime uses thread-local storage
(TLS) or vtable-based waker dispatch that depends on symbols being globally
visible. When loaded with `RTLD_LOCAL`, these resolution paths fail silently
(null function pointers) and crash when the I/O driver tries to wake a task.

**Why it works in-process:** Single `dlopen` call, one tokio runtime instance
shared by both sessions. The waker vtable is resolved within the same library
instance. No cross-library symbol resolution needed.

**Why it works with native zenoh-c processes:** The native C executable loads
`libzenohc.so` via the normal ELF loader at startup (effectively RTLD_GLOBAL).
Only the Dart side uses `dlopen`.

**Why two Dart processes crash:** Both load `libzenohc.so` via `dlopen` with
`RTLD_LOCAL`. When two such processes connect via TCP, the listener's tokio I/O
driver processes the incoming connection event, and the waker dispatch fails.

**Dart SDK limitation:** `DynamicLibrary.open()` does not support `RTLD_GLOBAL`.
Open issue: https://github.com/dart-lang/sdk/issues/50105

### Proposed Fix

Add a C shim function that promotes libzenohc.so from `RTLD_LOCAL` to
`RTLD_GLOBAL` by re-opening it with the global flag:

**C shim addition (src/zenoh_dart.c):**
```c
#include <dlfcn.h>

FFI_PLUGIN_EXPORT int zd_promote_zenohc_global(void) {
    void* handle = dlopen("libzenohc.so", RTLD_LAZY | RTLD_GLOBAL);
    if (handle == NULL) {
        return -1;
    }
    // Don't dlclose — we want it to stay RTLD_GLOBAL
    return 0;
}
```

Since this is called from within `libzenoh_dart.so`, the dynamic linker resolves
`libzenohc.so` via RUNPATH (`$ORIGIN`), finding the already-loaded instance.
The `RTLD_GLOBAL` flag promotes it in-place.

**Dart side (native_lib.dart):**
```dart
void ensureInitialized() {
    if (_initialized) return;
    // Promote libzenohc.so to RTLD_GLOBAL before any zenoh-c work
    ffi_bindings.zd_promote_zenohc_global();
    final result = ffi_bindings.zd_init_dart_api_dl(NativeApi.initializeApiDLData);
    if (result != 0) {
        throw StateError('Failed to initialize Dart API DL (code: $result)');
    }
    _initialized = true;
}
```

**Scope:** 1 new C function + 1 new C header declaration + ffigen regeneration +
1 line in native_lib.dart. Rebuild libzenoh_dart.so and copy to native/.

### Downstream Impact (After Fix)

Once the fix lands in zenoh-dart:

1. **zenoh-counter-dart** — Remove all LD_LIBRARY_PATH from docs (11 files,
   28 occurrences). Tests and CLI work without it.
2. **zenoh-counter-cpp** — Interop tests (`tests/integration/test_peer_interop.sh`,
   `test_router_interop.sh`) currently set LD_LIBRARY_PATH for the Dart
   subscriber process. These can be simplified to rely on build hooks.
3. **All future consumers** — Benefit automatically.

### Files Changed in Fix

| File | Change |
|------|--------|
| `src/zenoh_dart.h` | Add `zd_promote_zenohc_global()` declaration |
| `src/zenoh_dart.c` | Add `zd_promote_zenohc_global()` implementation (~5 lines) |
| `packages/zenoh/lib/src/bindings.dart` | Regenerate (ffigen) |
| `packages/zenoh/lib/src/native_lib.dart` | Call `zd_promote_zenohc_global()` in `ensureInitialized()` |
| `packages/zenoh/native/linux/x86_64/libzenoh_dart.so` | Rebuild + copy |

### Test Plan

1. Existing 185 in-process tests must still pass
2. New inter-process test: two Dart processes connect via TCP without crash
3. New inter-process test: Dart pub + Dart sub exchange data correctly
4. Verify no LD_LIBRARY_PATH or LD_PRELOAD needed

### Open Questions for Senior Review

1. **Is `dlopen` promotion to RTLD_GLOBAL the right fix?** Alternative: compile
   libzenohc.so as a static library linked into libzenoh_dart.so. This would
   eliminate the two-library problem entirely but increases binary size (~14MB)
   and may complicate Android cross-compilation.
2. **Should we report this upstream?** The Rust/tokio TLS issue with RTLD_LOCAL
   may affect other projects embedding Rust cdylib libraries via dlopen. Relevant
   upstream issues:
   - https://github.com/rust-lang/rust/issues/54291 (Rust TLS + dlopen)
   - https://github.com/dart-lang/sdk/issues/50105 (Dart RTLD_GLOBAL support)
3. **Platform portability:** The `dlopen`/`RTLD_GLOBAL` approach is POSIX.
   Windows uses `LoadLibrary` which doesn't have this distinction. macOS/iOS
   uses the same POSIX API. Need `#ifdef` guards for Windows.
4. **Should `zd_promote_zenohc_global` return an error or be best-effort?**
   If it fails, inter-process still crashes. Should `ensureInitialized()` throw?
