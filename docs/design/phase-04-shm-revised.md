# Phase 4: SHM Provider + Pub/Sub (Core SHM) -- REVISED

> **This spec supersedes `development/phases/phase-04-shm-pub-sub.md`.** It incorporates
> patterns established in Phases 0-3 and cross-cutting decisions from
> `docs/design/cross-cutting-patterns.md`.

## Project Context

`zenoh` is a pure Dart FFI package providing bindings for zenoh-c v1.7.2 via a
C shim layer. See `development/phases/phase-00-bootstrap.md` for full architecture.

**SHM (Shared Memory) is a first-class feature** -- it is the primary reason for
building dart:ffi bindings rather than using a higher-level approach. SHM enables
zero-copy data transfer between zenoh peers on the same machine.

## Prior Phases

### Phase 0 (Bootstrap) -- completed
- C shim: session/config/keyexpr/bytes management
- Dart: `Config`, `Session`, `KeyExpr`, `ZBytes`, `ZenohException`

### Phase 1 (z_put + z_delete) -- completed
- C shim: `zd_put`, `zd_delete`
- Dart: `Session.put()`, `Session.putBytes()`, `Session.deleteResource()`

### Phase 2 (z_sub) -- completed
- C shim: `zd_declare_subscriber`, `zd_subscriber_drop`, NativePort callback bridge
- Dart: `Sample`, `SampleKind`, `Subscriber` with `Stream<Sample>`

### Phase 3 (z_pub) -- completed
- C shim: `zd_declare_publisher`, `zd_publisher_put`, matching listener
- Dart: `Publisher`, `Encoding`, `CongestionControl`, `Priority`

## This Phase's Goal

Introduce the **SHM provider infrastructure** and implement SHM-based
publishing and subscribing. SHM buffers enable zero-copy data transfer by
allocating payloads in shared memory regions that zenoh can pass between
peers without copying.

**Reference examples**:
- `extern/zenoh-c/examples/z_pub_shm.c`
- Subscriber is standard `z_sub.c` (no SHM-specific subscriber)

### SHM Build Requirement

libzenohc must be built with SHM support:

```bash
cmake \
  -S extern/zenoh-c \
  -B extern/zenoh-c/build \
  -G Ninja \
  -DCMAKE_C_COMPILER=/usr/bin/clang \
  -DCMAKE_CXX_COMPILER=/usr/bin/clang++ \
  -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=TRUE \
  -DZENOHC_BUILD_IN_SOURCE_TREE=TRUE \
  -DZENOHC_BUILD_WITH_SHARED_MEMORY=TRUE \
  -DZENOHC_BUILD_WITH_UNSTABLE_API=TRUE
```

This enables `Z_FEATURE_SHARED_MEMORY` and `Z_FEATURE_UNSTABLE_API`
compile-time flags. All SHM C shim functions must be guarded with:

```c
#if defined(Z_FEATURE_SHARED_MEMORY) && defined(Z_FEATURE_UNSTABLE_API)
// ... SHM functions ...
#endif
```

### SHM Concepts (from zenoh-c)

1. **SHM Provider**: Manages a shared memory pool. Created with
   `z_shm_provider_default_new(size)` (uses platform-appropriate backend).
2. **Allocation**: Request buffer from provider. Multiple strategies exist;
   we expose two:
   - `alloc` -- simple, may fail if pool is full
   - `alloc_gc_defrag_blocking` -- garbage collects, defragments, blocks
     until space is available (safest)
3. **Mutable buffer** (`z_owned_shm_mut_t`): Writable buffer, get raw pointer
   via `z_shm_mut_data_mut()`.
4. **Immutable buffer** (`z_owned_shm_t`): Read-only, converted from mutable.
5. **Bytes conversion**: SHM buffers convert to `z_owned_bytes_t` for
   publishing (zero-copy path).
6. **Receive-side detection**: Check if a received `z_loaned_bytes_t` is
   SHM-backed via `z_bytes_as_loaned_shm()`.

### z_buf_layout_alloc_result_t

zenoh-c returns allocation results in a `z_buf_layout_alloc_result_t` struct
with fields: `status`, `buf` (z_owned_shm_mut_t), `alloc_error`,
`layout_error`. This struct is **hidden from Dart** -- the C shim handles
it internally and either returns the buffer or an error code.

## C Shim Functions to Add

### SHM Provider Lifecycle

```c
// Returns sizeof(z_owned_shm_provider_t) for Dart FFI allocation.
FFI_PLUGIN_EXPORT size_t zd_shm_provider_sizeof(void);

// Create a default SHM provider with given total pool size.
//
// Uses z_shm_provider_default_new internally (platform-appropriate backend).
// Returns 0 on success, negative on failure.
FFI_PLUGIN_EXPORT int zd_shm_provider_new(
    z_owned_shm_provider_t* provider,
    size_t total_size);

// Get a loaned reference to the provider.
FFI_PLUGIN_EXPORT const z_loaned_shm_provider_t* zd_shm_provider_loan(
    const z_owned_shm_provider_t* provider);

// Drop (free) the SHM provider and its memory pool.
FFI_PLUGIN_EXPORT void zd_shm_provider_drop(z_owned_shm_provider_t* provider);

// Query available (free) bytes in the provider's pool.
FFI_PLUGIN_EXPORT size_t zd_shm_provider_available(
    const z_loaned_shm_provider_t* provider);
```

### SHM Allocation

```c
// Returns sizeof(z_owned_shm_mut_t) for Dart FFI allocation.
FFI_PLUGIN_EXPORT size_t zd_shm_mut_sizeof(void);

// Basic allocation -- may fail if pool is full.
//
// Internally creates z_buf_layout_alloc_result_t, calls
// z_shm_provider_alloc, checks status, moves buf to output.
// Returns 0 on success, 1 on alloc error, 2 on layout error.
FFI_PLUGIN_EXPORT int zd_shm_provider_alloc(
    const z_loaned_shm_provider_t* provider,
    z_owned_shm_mut_t* buf,
    size_t size);

// Allocation with garbage collection, defragmentation, and blocking.
// Blocks until space is available (safest strategy).
//
// Same internal pattern as zd_shm_provider_alloc.
// Returns 0 on success, 1 on alloc error, 2 on layout error.
FFI_PLUGIN_EXPORT int zd_shm_provider_alloc_gc_defrag_blocking(
    const z_loaned_shm_provider_t* provider,
    z_owned_shm_mut_t* buf,
    size_t size);
```

### SHM Mutable Buffer Operations

```c
// Get a mutable loaned reference to the buffer.
FFI_PLUGIN_EXPORT z_loaned_shm_mut_t* zd_shm_mut_loan_mut(
    z_owned_shm_mut_t* buf);

// Get mutable data pointer for writing into SHM buffer.
FFI_PLUGIN_EXPORT uint8_t* zd_shm_mut_data_mut(
    z_loaned_shm_mut_t* buf);

// Get length of SHM buffer in bytes.
FFI_PLUGIN_EXPORT size_t zd_shm_mut_len(
    const z_loaned_shm_mut_t* buf);

// Convert mutable SHM buffer directly to bytes for publishing.
// Consumes the mutable buffer (zero-copy).
// Returns 0 on success.
FFI_PLUGIN_EXPORT int zd_bytes_from_shm_mut(
    z_owned_bytes_t* bytes,
    z_owned_shm_mut_t* buf);

// Drop (free) a mutable SHM buffer without converting.
FFI_PLUGIN_EXPORT void zd_shm_mut_drop(z_owned_shm_mut_t* buf);
```

### SHM Immutable Buffer Operations (Deferred)

The immutable buffer path (`z_owned_shm_t`, `z_shm_from_mut`,
`z_bytes_from_shm`) is **deferred to Phase 4.1** (or later). The direct
mutable-to-bytes path (`zd_bytes_from_shm_mut`) covers the primary SHM
publish workflow. The immutable buffer is only needed for:
- Receive-side SHM detection (see below)
- Advanced buffer sharing patterns

### SHM Detection on Receive Side (Deferred)

Receive-side SHM detection (`z_bytes_as_loaned_shm`,
`z_bytes_as_mut_loaned_shm`, `z_shm_try_reloan_mut`) is **deferred to
Phase 4.1**. Rationale:

1. The subscriber callback in Phase 2 already converts payloads to
   `Uint8List` via `z_bytes_to_string`. SHM detection requires the raw
   `z_loaned_bytes_t*` to be accessible, which means changing the Sample
   type or the callback bridge.
2. The primary SHM value (zero-copy publish) is delivered in Phase 4
   without detection. Detection is an optimization for the receive side.
3. Phase 4 scope is already substantial (SHM provider + alloc + buffer ops).

**Total: 12 new C shim functions**

## zenoh-c APIs Wrapped

| C shim function | zenoh-c function(s) |
|----------------|---------------------|
| `zd_shm_provider_sizeof` | `sizeof(z_owned_shm_provider_t)` |
| `zd_shm_provider_new` | `z_shm_provider_default_new` |
| `zd_shm_provider_loan` | `z_shm_provider_loan` (macro) |
| `zd_shm_provider_drop` | `z_shm_provider_drop` + `z_shm_provider_move` |
| `zd_shm_provider_available` | `z_shm_provider_available` |
| `zd_shm_mut_sizeof` | `sizeof(z_owned_shm_mut_t)` |
| `zd_shm_provider_alloc` | `z_shm_provider_alloc` + result extraction |
| `zd_shm_provider_alloc_gc_defrag_blocking` | `z_shm_provider_alloc_gc_defrag_blocking` + result extraction |
| `zd_shm_mut_loan_mut` | `z_shm_mut_loan_mut` (macro) |
| `zd_shm_mut_data_mut` | `z_shm_mut_data_mut` |
| `zd_shm_mut_len` | `z_shm_mut_len` |
| `zd_bytes_from_shm_mut` | `z_bytes_from_shm_mut` + `z_shm_mut_move` |
| `zd_shm_mut_drop` | `z_shm_mut_drop` + `z_shm_mut_move` |

## Dart API Surface

### New file: `package/lib/src/shm_provider.dart`

```dart
/// Manages a shared memory pool for zero-copy data transfer.
///
/// Wraps `z_owned_shm_provider_t`. Use to allocate SHM buffers that can be
/// published without copying.
///
/// Call [close] when done to release the provider and its memory pool.
class ShmProvider {
  /// Create a SHM provider with the given total pool [size] in bytes.
  ///
  /// Throws [ZenohException] if provider creation fails.
  ShmProvider({required int size});

  /// Allocate a mutable SHM buffer of the given [size] bytes.
  ///
  /// Simple allocation -- may fail if pool is full.
  /// Throws [ZenohException] on allocation failure.
  ShmMutBuffer alloc(int size);

  /// Allocate a mutable SHM buffer with GC, defragmentation, and blocking.
  ///
  /// Blocks until space is available (safest strategy).
  /// Throws [ZenohException] on allocation failure.
  ShmMutBuffer allocGcDefragBlocking(int size);

  /// Query available (free) bytes in the provider's pool.
  int get available;

  /// Release the provider and its memory pool.
  ///
  /// Safe to call multiple times -- subsequent calls are no-ops.
  void close();
}
```

### New file: `package/lib/src/shm_buffer.dart`

```dart
/// A mutable shared memory buffer for zero-copy writes.
///
/// Wraps `z_owned_shm_mut_t`. Allocated from a [ShmProvider].
/// Write data via [data] pointer, then convert to [ZBytes] for publishing.
class ShmMutBuffer {
  /// Raw pointer to the buffer data for zero-copy writes.
  ///
  /// Use with `Pointer<Uint8>.asTypedList(length)` to get a writable
  /// Uint8List view into shared memory.
  Pointer<Uint8> get data;

  /// Length of the buffer in bytes.
  int get length;

  /// Convert to bytes for publishing (consumes this buffer, zero-copy).
  ///
  /// After this call, [data] is invalid and must not be accessed.
  /// Throws [StateError] if already consumed or disposed.
  ZBytes toBytes();

  /// Drop (free) without converting.
  ///
  /// Safe to call multiple times -- subsequent calls are no-ops.
  void dispose();
}
```

### Modify `package/lib/zenoh.dart`

Add exports for `ShmProvider`, `ShmMutBuffer`.

## CLI Example to Create

### `package/bin/z_pub_shm.dart`

Mirrors `extern/zenoh-c/examples/z_pub_shm.c`:

```
Usage: fvm dart run -C package bin/z_pub_shm.dart [OPTIONS]

Options:
    -k, --key <KEYEXPR>           (default: 'demo/example/zenoh-dart-pub')
    -p, --payload <VALUE>         (default: 'Pub from Dart (SHM)!')
    -e, --connect <ENDPOINT>      (optional, repeatable)
    -l, --listen <ENDPOINT>       (optional, repeatable)
    --add-matching-listener       (optional, enables matching status)
```

Behavior:
1. Parse args (matching zenoh-c z_pub_shm.c flags)
2. `Zenoh.initLog('error')`
3. Open session (with connect/listen endpoints if provided)
4. Declare publisher
5. Create SHM provider (pool size: 4096)
6. Loop:
   a. Allocate SHM buffer via `allocGcDefragBlocking(bufSize)`
   b. Write `"[<idx>] <value>"` into buffer via raw pointer
   c. Convert buffer to bytes via `toBytes()` (zero-copy)
   d. Publish via `publisher.putBytes(payload)`
   e. Sleep 1 second
7. Clean up: close publisher, close provider, close session
8. Run until SIGINT

## SHM Publish Workflow in Dart

```dart
final provider = ShmProvider(size: 4096);
final buf = provider.allocGcDefragBlocking(256);

// Write directly to shared memory (zero-copy):
final data = utf8.encode('[${idx}] Pub from Dart (SHM)!');
buf.data.asTypedList(buf.length).setAll(0, data);

// Convert to bytes and publish (zero-copy, consumes buf):
final payload = buf.toBytes();
publisher.putBytes(payload);
```

## Deferred to Phase 4.1

The following features exist in zenoh-c v1.7.2 but are deferred from this
phase to keep scope manageable:

| Feature | zenoh-c APIs | Rationale |
|---------|-------------|-----------|
| Immutable SHM buffer | `z_owned_shm_t`, `z_shm_from_mut`, `z_bytes_from_shm` | Mutable-to-bytes path covers primary use case |
| SHM detection (receive) | `z_bytes_as_loaned_shm`, `z_shm_try_reloan_mut` | Requires Sample/callback changes |
| Aligned allocation | `z_shm_provider_alloc_*_aligned` variants | Optimization, not core |
| SHM client storage | `z_shm_client_storage_*`, `z_shm_client_*` | Custom SHM backends, advanced |
| Shared SHM provider | `z_owned_shared_shm_provider_t` | Thread-safe variant, advanced |
| Precomputed layout | `z_owned_precomputed_layout_t` | Performance optimization |
| Async defrag allocation | `z_shm_provider_alloc_gc_defrag_async` | Requires async callback bridge |

## Verification

1. `cmake --build build` -- C shim compiles with 12 new functions (guarded by SHM flags)
2. `cd package && fvm dart run ffigen --config ffigen.yaml` -- regenerate bindings
3. `fvm dart analyze package` -- no errors
4. **Unit tests:**
   - ShmProvider creation with valid size succeeds
   - ShmProvider.close is idempotent (double-close safe)
   - ShmProvider.available returns expected value after creation
   - ShmMutBuffer.alloc returns writable buffer of correct length
   - ShmMutBuffer.allocGcDefragBlocking returns writable buffer
   - Write data into ShmMutBuffer via pointer, read back correctly
   - ShmMutBuffer.toBytes returns valid ZBytes (consumed)
   - ShmMutBuffer.toBytes throws StateError on second call
   - ShmMutBuffer.dispose is idempotent
   - ShmProvider.alloc with insufficient pool size throws ZenohException
   - Operations on closed ShmProvider throw StateError
5. **Integration tests (two sessions):**
   - Publisher.putBytes with SHM buffer received by subscriber as PUT sample
   - SHM-published data matches original string content
   - Multiple SHM publishes in sequence all received correctly
   - SHM publish with encoding option works
   - SHM publish with attachment works
6. **CLI integration:**
   - `z_pub_shm.dart` publishes, `z_sub.dart` receives periodic messages
   - `z_pub_shm.dart -e tcp/localhost:7447` connects to specified endpoint
