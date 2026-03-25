# TDD Implementer Memory

## Project Setup
- Working dir: `/home/hugo-bluecorn/bluecorn/CSR/git/zenoh_dart/package`
- Test command: `LD_LIBRARY_PATH=../../extern/zenoh-c/target/release:../../build fvm dart test test/<file>.dart`
- Analysis: `fvm dart analyze package` (run from repo root)
- All commands require `fvm` prefix

## zenoh-c SHM Behavioral Notes
- `ShmProvider(size: 256)` throws ZenohException — zenoh-c rejects small pool sizes (minimum appears > 256)
- `provider.available` returns 0 before any allocation (lazy allocation) — do NOT test available decreasing after alloc
- Pool exhaustion works: allocating repeatedly with `alloc(512)` on a 4096-byte pool eventually returns null
- `zd_shm_mut_loan_mut` returns a loaned pointer needed by `zd_shm_mut_len` and `zd_shm_mut_data_mut`

## Patterns
- Entity lifecycle: sizeof -> new/alloc -> loan -> operations -> drop + calloc.free
- Idempotent close/dispose: guard with `_closed`/`_disposed` flag, early return on second call
- State checks: `_ensureOpen()` / `_ensureNotDisposed()` / `_ensureUsable()` throwing StateError
- alloc returns null on failure (not exception) — check rc != 0, free bufPtr, return null
- ShmMutBuffer.fromNative(Pointer<Void>) constructor — called by ShmProvider.alloc
- Consumed pattern: `_consumed` flag set by toBytes(), `_ensureUsable()` checks both `_disposed` and `_consumed`
- ZBytes.fromNative(Pointer<Void>) constructor — wraps an existing z_owned_bytes_t pointer (used by ShmMutBuffer.toBytes)
- dispose() after consume: skip native drop (owned by new ZBytes), only free calloc wrapper
- Pointer<Uint8> in Dart 3.11: `asTypedList` not available; use index operator `ptr[i]` for read/write. REQUIRES `import 'dart:ffi'` in the file — without it, `[]=` operator is not found even if the type comes from another package
- SHM zero-copy: allocate exact size needed if round-trip string comparison is required (buffer size = data size)

## Test Structure
- SHM tests in `test/shm_provider_test.dart` with separate groups for ShmProvider and ShmMutBuffer
- ShmMutBuffer group uses setUp/tearDown to create/close a ShmProvider(size: 4096)
- Use `addTearDown` for buffer cleanup in individual tests
- Inter-process tests in `test/interprocess_test.dart` with helper at `test/helpers/interprocess_connect.dart`
- Session.open() takes NAMED parameter: `Session.open(config: config)` not `Session.open(config)`

## RTLD_LOCAL / @Native Crash Investigation
- `zd_promote_zenohc_global()` successfully promotes symbols to RTLD_GLOBAL (verified with DynamicLibrary.process().lookup)
- BUT inter-process TCP connection STILL crashes listener with SEGV (pc=0 on tokio worker thread)
- Crash happens with ALL loading mechanisms: @Native, LD_LIBRARY_PATH, LD_PRELOAD
- Two distinct crashes found:
  1. Tokio waker vtable crash (pc=0, si_addr=nil, isolate_group=nil) — non-Dart thread
  2. Dart VM FfiResolve crash (si_addr=0x1874, in dlsym) — @Native lazy resolution on ThreadPool worker
- Full test suite crash: running session_test + any subprocess test in same VM crashes (pre-existing since PR #18 hooks migration)
- Tests with `--concurrency=1` still crash when session-using tests precede subprocess tests
- Individual test files pass when run alone
