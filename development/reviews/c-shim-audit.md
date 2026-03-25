# C Shim Layer Audit

**Scope:** `src/zenoh_dart.{h,c}` (62 exported symbols) and the Dart FFI consumers in `package/lib/src/`.
**Audience:** Expert C and Dart code reviewers.
**Date:** 2026-03-09
**zenoh-c version:** v1.7.2

---

## 1. Why the C Shim Exists

Dart FFI (`dart:ffi`) can only call C functions with plain scalar/pointer signatures. The zenoh-c API v1.7.2 presents several constructs that are not directly callable from Dart:

| Problem | zenoh-c mechanism | Why Dart FFI cannot use it directly |
|---------|-------------------|-------------------------------------|
| **Generic macros** | `z_open()`, `z_close()`, `z_drop()` are `_Generic` macros that dispatch on the argument type at compile time | Dart FFI resolves symbols at link time; C macros do not produce symbols |
| **Opaque struct sizes** | `z_owned_session_t`, `z_owned_config_t`, etc. have sizes known only to the compiled zenoh-c library | Dart needs `sizeof` at runtime to `calloc.allocate` the correct number of bytes |
| **Closure callbacks** | Subscriber, scout, and matching listener use `z_owned_closure_*_t` with function pointers and void* context | Dart cannot construct C closure structs or pass Dart closures as C function pointers across async boundaries |
| **Move semantics** | `z_*_move()` returns `z_moved_*_t*`, consumed by callers. The move/drop protocol is encoded in C macros and inline functions | Dart cannot call inline functions or macros |
| **Options structs with defaults** | `z_put_options_t`, `z_publisher_options_t`, etc. require `_default()` initialization then selective field overrides | Dart cannot call `_default()` macros or set fields on opaque structs |
| **Loaning pattern** | `z_*_loan()` / `z_*_loan_mut()` return `const z_loaned_*_t*` / `z_loaned_*_t*` from owned types | Some are macros (not callable), and the const/mut distinction must be enforced in C |

The C shim resolves all six problems by exposing a flat C function API where every symbol is a real, linkable function with scalar/pointer-only parameters.

---

## 2. Architectural Principles

### 2.1 Namespace Isolation

All shim symbols use the `zd_` prefix. The `ffigen.yaml` filter `zd_.*` ensures only shim functions appear in `bindings.dart`. This prevents accidental binding to zenoh-c internal symbols that share the `z_` prefix.

### 2.2 Single-Load Model

Only `libzenoh_dart.so` is loaded explicitly via `DynamicLibrary.open()`. The OS dynamic linker resolves `libzenohc.so` via the `DT_NEEDED` entry in `libzenoh_dart.so`'s ELF headers. This avoids dual-load ordering issues and ensures zenoh-c internal global state is initialized exactly once.

### 2.3 Opaque Type Mapping

All zenoh-c types (`z_owned_*_t`, `z_loaned_*_t`, `z_view_*_t`, `z_moved_*_t`) are mapped to `ffi.Opaque` in `ffigen.yaml`. Dart never inspects struct fields. Memory is allocated on the Dart side via `calloc.allocate(zd_*_sizeof())` and freed after the corresponding `zd_*_drop()`.

### 2.4 Callback Bridge Pattern

For asynchronous notifications (subscriber samples, matching status, scout results), the shim uses `Dart_PostCObject_DL` to post structured data to a Dart `ReceivePort`. The pattern:

1. C allocates a context struct containing a `Dart_Port_DL`
2. C registers a zenoh-c closure with the context
3. zenoh-c invokes the callback on its internal thread
4. Callback extracts fields, marshals them into `Dart_CObject`, posts to the port
5. Dart `ReceivePort.listen` receives the data on the Dart event loop
6. zenoh-c invokes the `_drop` callback when the closure is destroyed, freeing the context

---

## 3. Function-by-Function Analysis

### 3.1 Initialization (2 functions)

#### `zd_init_dart_api_dl`

```c
FFI_PLUGIN_EXPORT intptr_t zd_init_dart_api_dl(void* data) {
  return Dart_InitializeApiDL(data);
}
```

**Problem solved:** `Dart_InitializeApiDL` must be called before any `Dart_PostCObject_DL` usage. Wrapping it as an exported symbol allows `ffigen` to generate a callable binding.

**Assessment:** Correct. The return value is propagated to Dart, which checks for non-zero failure. Called once during `_initBindings()`.

#### `zd_init_log`

```c
FFI_PLUGIN_EXPORT void zd_init_log(const char* fallback_filter) {
  zc_init_log_from_env_or(fallback_filter);
}
```

**Problem solved:** `zc_init_log_from_env_or` may be a macro or may not be directly bindable due to header complexity. The shim provides a stable symbol.

**Assessment:** Correct. Dart passes a `toNativeUtf8()` string and frees it after the call.

### 3.2 Config (5 functions)

| Function | Wraps | Problem Solved |
|----------|-------|----------------|
| `zd_config_sizeof` | `sizeof(z_owned_config_t)` | Runtime sizeof for Dart allocation |
| `zd_config_default` | `z_config_default()` | May be macro; provides stable symbol |
| `zd_config_insert_json5` | `z_config_loan_mut()` + `zc_config_insert_json5()` | Combines loan-mut + insert into single call; `z_config_loan_mut` may be a macro |
| `zd_config_loan` | `z_config_loan()` | Macro flattening |
| `zd_config_drop` | `z_config_move()` + `z_config_drop()` | Move + drop are both macros |

**Finding [C-1]: `zd_config_drop` calls `z_config_drop(z_config_move(config))`.**

```c
FFI_PLUGIN_EXPORT void zd_config_drop(z_owned_config_t* config) {
  z_config_drop(z_config_move(config));
}
```

`z_config_move()` returns a `z_moved_config_t*` pointing into the same memory (it's a reinterpret, not a copy). `z_config_drop()` accepts the moved pointer and resets the original to gravestone state. This is the correct zenoh-c v1.7.2 drop idiom. The same pattern is used consistently for bytes, strings, subscribers, publishers, SHM types.

**Dart side (Config.dispose):**
```dart
void dispose() {
  if (_disposed) return;
  _ensureNotConsumed();
  _disposed = true;
  bindings.zd_config_drop(_ptr.cast());
  calloc.free(_ptr);
}
```

Double-dispose is safe: the flag prevents re-entry. The `calloc.free` releases the Dart-allocated wrapper memory after zenoh-c has released its internal state.

### 3.3 Session (4 functions)

#### `zd_open_session`

```c
FFI_PLUGIN_EXPORT int zd_open_session(z_owned_session_t* session,
                                      z_owned_config_t* config) {
  return z_open(session, z_config_move(config), NULL);
}
```

**Problem solved:** `z_open` is a `_Generic` macro. `z_config_move` is a macro. The third parameter (`z_open_options_t*`) is NULL for defaults.

**Assessment:** Correct. Config is consumed by `z_config_move` regardless of success/failure.

**Dart side (Session.open):** Marks config as consumed immediately after the call, before checking the return code. This is correct because `z_config_move` transfers ownership even if `z_open` fails.

#### `zd_close_session`

```c
FFI_PLUGIN_EXPORT void zd_close_session(z_owned_session_t* session) {
  z_close(z_session_loan_mut(session), NULL);
  z_session_drop(z_session_move(session));
}
```

**Problem solved:** Graceful close requires two steps: `z_close` (sends close message to peers) then `z_session_drop` (frees resources). Both `z_close`, `z_session_loan_mut`, `z_session_move`, and `z_session_drop` may be macros.

**Finding [C-2]: `z_close` return value is not checked.**

`z_close` can fail (e.g., if the session is already closed or the network is unreachable). The return value is silently discarded. In zenoh-cpp, `Session::close()` similarly ignores the return value, treating close as best-effort. This is acceptable for the current use case but should be documented.

**Severity:** Low. Close-time errors are non-actionable in most applications.

### 3.4 KeyExpr (4 functions)

#### `zd_view_keyexpr_from_str`

```c
FFI_PLUGIN_EXPORT int zd_view_keyexpr_from_str(z_view_keyexpr_t* ke,
                                               const char* expr) {
  return z_view_keyexpr_from_str(ke, expr);
}
```

**Problem solved:** `z_view_keyexpr_from_str` may be a macro.

**Critical invariant:** The `z_view_keyexpr_t` borrows the `expr` string. The string must outlive the view. The Dart `KeyExpr` class correctly holds `_nativeStr` (allocated via `toNativeUtf8()`) and frees it only in `dispose()`, after the view is no longer used.

**Finding [C-3]: The `KeyExpr` constructor uses `toNativeUtf8()` (malloc) for the string but `calloc.allocate` for the view struct.**

```dart
KeyExpr(String expr)
  : _kePtr = calloc.allocate(bindings.zd_view_keyexpr_sizeof()),
    _nativeStr = expr.toNativeUtf8() {
```

This is correct behavior. `toNativeUtf8()` uses `malloc` by default, and `KeyExpr.dispose()` correctly calls `malloc.free(_nativeStr)` and `calloc.free(_kePtr)`. The two allocators are used for their respective allocations. Not a bug.

### 3.5 Bytes (6 functions)

The bytes family (`zd_bytes_sizeof`, `zd_bytes_copy_from_str`, `zd_bytes_copy_from_buf`, `zd_bytes_to_string`, `zd_bytes_loan`, `zd_bytes_drop`) are straightforward macro-to-function wrappers.

**Finding [C-4]: `ZBytes.fromUint8List` copies data element-by-element.**

```dart
factory ZBytes.fromUint8List(Uint8List data) {
  final Pointer<Uint8> nativeBuf = calloc<Uint8>(data.length);
  for (var i = 0; i < data.length; i++) {
    nativeBuf[i] = data[i];
  }
```

This could use `nativeBuf.asTypedList(data.length).setAll(0, data)` for a bulk `memcpy`-equivalent. The element-by-element copy is O(n) with Dart bounds checking overhead per element.

**Severity:** Low (performance). Functional correctness is unaffected. For large payloads, the `ShmMutBuffer` zero-copy path should be preferred anyway.

### 3.6 String (5 functions) and View String (3 functions)

These are pure macro-to-function wrappers. The `zd_view_string_data` and `zd_view_string_len` compound functions (loan + data/len) save one FFI round-trip per call.

**Assessment:** Correct. The Dart side consistently uses `data.cast<Utf8>().toDartString(length: len)` with explicit length, avoiding reliance on null-termination.

### 3.7 Put/Delete (2 functions)

#### `zd_put`

```c
FFI_PLUGIN_EXPORT int zd_put(
    const z_loaned_session_t* session,
    const z_loaned_keyexpr_t* keyexpr,
    z_owned_bytes_t* payload) {
  z_put_options_t opts;
  z_put_options_default(&opts);
  return z_put(session, keyexpr, z_bytes_move(payload), &opts);
}
```

**Problem solved:** `z_put` is a macro. `z_bytes_move` is a macro. Options struct initialization via `z_put_options_default` may be a macro. All three are flattened into a single callable symbol.

**Design choice:** The shim uses default options (no encoding, no attachment, no QoS override). This matches Phase 1 scope. Future phases can add `zd_put_with_options` or extend parameters.

**Dart side:** `Session.put` and `Session.putBytes` both call `payload.markConsumed()` after the FFI call, correctly tracking that `z_bytes_move` transferred ownership.

### 3.8 Subscriber (3 functions)

#### `zd_declare_subscriber` and `_zd_sample_callback`

This is the most complex shim code. The callback must:
1. Extract 5 fields from `z_loaned_sample_t`
2. Marshal them into `Dart_CObject` types
3. Post the array to Dart via `Dart_PostCObject_DL`
4. Clean up all temporary allocations

**Finding [C-5]: The payload is converted to string via `z_bytes_to_string` then sent as `Dart_TypedData_kUint8`.**

```c
z_owned_string_t payload_str;
z_bytes_to_string(payload_loaned, &payload_str);
// ...
c_payload.value.as_typed_data.values = (uint8_t*)payload_data;
```

The payload bytes are first converted to a `z_owned_string_t`, then the string's data pointer is used as the `Uint8List` source for the Dart CObject. This means:

- `z_bytes_to_string` performs a copy from the zenoh bytes container into a `z_owned_string_t`
- The Dart CObject `Dart_TypedData_kUint8` data points to the string's internal buffer
- `Dart_PostCObject_DL` copies the typed data into the Dart heap
- The `z_owned_string_t` is then freed via `z_string_drop`

The lifetime chain is safe: `z_owned_string_t` outlives the `Dart_PostCObject_DL` call, and `Dart_PostCObject_DL` performs a deep copy into the Dart heap before returning.

**However,** using `z_bytes_to_string` means non-UTF-8 binary payloads may be corrupted or cause undefined behavior. `z_bytes_to_string` in zenoh-c interprets the bytes as UTF-8. For true binary payloads, `z_bytes_reader` should be used instead. The Dart `Sample.payloadBytes` field (added in 0.6.1) relies on this path, meaning binary data passes through a UTF-8 string conversion.

**Severity:** Medium. Binary payloads that are not valid UTF-8 will be misrepresented in `payloadBytes`. The `Sample.payload` (string) field naturally expects UTF-8, but `payloadBytes` promises raw bytes.

**Finding [C-6]: Key expression string requires malloc + memcpy for null-termination.**

```c
char* key_buf = (char*)malloc(key_len + 1);
memcpy(key_buf, key_data, key_len);
key_buf[key_len] = '\0';
c_keyexpr.value.as_string = key_buf;
```

`z_string_data` does not guarantee null-termination. The `Dart_CObject_kString` type requires a null-terminated string. The malloc + copy + null-terminate is correct. The encoding field uses the same pattern. Properly freed after `Dart_PostCObject_DL`.

**Finding [C-7]: Subscriber error path may double-free the closure.**

```c
int rc = z_declare_subscriber(
    session, subscriber, keyexpr,
    z_closure_sample_move(&callback), NULL);

if (rc != 0) {
  z_closure_sample_drop(z_closure_sample_move(&callback));
}
```

If `z_declare_subscriber` fails, the code attempts to drop the closure. According to zenoh-c semantics, `z_closure_sample_move` consumes the closure (moves it). If `z_declare_subscriber` consumed the move, the closure is already in gravestone state, and the drop in the error branch is a safe no-op. If `z_declare_subscriber` failed before consuming, the closure still needs cleanup.

**Assessment:** The code is defensive and correct. `z_closure_sample_move(&callback)` in the error path creates a second move from the same storage. If the first move transferred ownership into `z_declare_subscriber` (and it failed internally), the original is in gravestone state and the second move + drop is a no-op. If the first move was not consumed (early failure), the second move + drop correctly frees the context. This matches zenoh-c's idempotent drop guarantees.

### 3.9 Publisher (7 functions)

#### `zd_declare_publisher`

```c
FFI_PLUGIN_EXPORT int zd_declare_publisher(
    const z_loaned_session_t* session,
    z_owned_publisher_t* publisher,
    const z_loaned_keyexpr_t* keyexpr,
    const char* encoding,
    int congestion_control,
    int priority) {
```

**Problem solved:** Flattens the options struct pattern. Uses sentinel values (`NULL` for encoding, `-1` for enums) to distinguish "use default" from "override".

**Finding [C-8]: Encoding ownership leak on publisher declaration failure.**

```c
z_owned_encoding_t owned_encoding;
if (encoding != NULL) {
  z_encoding_from_str(&owned_encoding, encoding);
  opts.encoding = z_encoding_move(&owned_encoding);
}
// ...
return z_declare_publisher(session, publisher, keyexpr, &opts);
```

If `z_declare_publisher` fails, the encoding has already been moved into `opts`. The options struct is stack-allocated and goes out of scope. In zenoh-c, `z_publisher_options_t.encoding` is a `z_moved_encoding_t*` (a pointer, not owning). The actual ownership was transferred to the options struct which `z_declare_publisher` is responsible for consuming. If `z_declare_publisher` fails, it is responsible for cleaning up moved values in the options. This is the zenoh-c contract.

**Assessment:** Correct per zenoh-c ownership semantics. The options struct's moved pointers are cleaned up by the callee on failure.

#### `zd_publisher_put`

```c
FFI_PLUGIN_EXPORT int zd_publisher_put(
    const z_loaned_publisher_t* publisher,
    z_owned_bytes_t* payload,
    const char* encoding,
    z_owned_bytes_t* attachment) {
```

**Problem solved:** Combines payload move, optional encoding override, and optional attachment into a single flat call.

**Assessment:** Correct. Both `payload` and `attachment` are moved via `z_bytes_move`, which is the correct ownership transfer. The Dart side marks both as consumed after the call.

#### `zd_publisher_declare_background_matching_listener`

Uses the same NativePort callback pattern as the subscriber. Posts `Int64` values (0/1) for matching status changes.

**Assessment:** Correct. Context is heap-allocated and freed via the drop callback. Error path drops the closure defensively.

### 3.10 Info (4 functions)

#### `zd_info_zid`

```c
FFI_PLUGIN_EXPORT void zd_info_zid(const z_loaned_session_t* session,
                                   uint8_t* out_id) {
  z_id_t zid = z_info_zid(session);
  memcpy(out_id, zid.id, 16);
}
```

**Problem solved:** `z_info_zid` returns a `z_id_t` by value (a 16-byte struct). Dart FFI cannot receive structs by value across FFI boundaries in all configurations. The shim copies the bytes into a caller-provided buffer.

**Finding [C-9]: Fixed 16-byte size assumption.**

The ZID size (16 bytes) is hardcoded in both C and Dart. This matches the zenoh-c v1.7.2 definition (`z_id_t` has `uint8_t id[16]`). If zenoh-c ever changes the ZID size, both layers must be updated.

**Severity:** None (informational). The zenoh protocol specifies 128-bit identifiers.

#### `zd_info_routers_zid` / `zd_info_peers_zid`

```c
static void _zd_zid_collect_callback(const z_id_t* id, void* context) {
  zd_zid_collect_context_t* ctx = (zd_zid_collect_context_t*)context;
  if (ctx->count < ctx->max_count) {
    memcpy(ctx->out_ids + ctx->count * 16, id->id, 16);
    ctx->count++;
  }
}
```

**Problem solved:** zenoh-c delivers ZIDs via a closure callback (`z_owned_closure_zid_t`). The shim collects them into a flat buffer that Dart can read.

**Design choice:** Stack-allocated context (no heap allocation needed since `z_info_routers_zid` is synchronous). The closure's `_drop` parameter is `NULL` because the context lives on the stack and outlives the closure.

**Finding [C-10]: Buffer overflow protection is correct but max_count is hardcoded in Dart.**

The Dart side allocates `maxCount = 64` ZIDs (1024 bytes). If a session has more than 64 connected routers or peers, the excess are silently dropped. This is reasonable for practical deployments.

### 3.11 Scout (3 functions)

#### `zd_scout`

```c
FFI_PLUGIN_EXPORT int zd_scout(z_owned_config_t* config, int64_t dart_port,
                               uint64_t timeout_ms, int what) {
  zd_scout_context_t ctx = { .dart_port = (Dart_Port_DL)dart_port };
```

**Finding [C-11]: Scout context is stack-allocated, but the callback is asynchronous.**

The `zd_scout_context_t` is on the stack. `z_scout()` is documented as blocking for `timeout_ms` then returning. The `_zd_scout_hello_callback` is called synchronously within `z_scout`'s execution. Therefore, the stack-allocated context is safe -- it outlives all callback invocations.

The null sentinel posted after `z_scout` returns signals completion to the Dart side. The Dart `Completer` resolves and the `ReceivePort` is closed.

**Assessment:** Correct. The blocking nature of `z_scout` means `ctx` on the stack is safe.

**Finding [C-12]: Locator string building uses two passes (length computation + copy).**

```c
for (size_t i = 0; i < loc_count; i++) {
  loc_buf_len += z_string_len(loc);
  if (i < loc_count - 1) loc_buf_len += 1;
}
loc_buf = (char*)malloc(loc_buf_len + 1);
```

This is correct and avoids realloc. The semicolon-joined format is parsed by `locatorsStr.split(';')` in Dart. Empty locator list produces an empty string, which Dart handles with `locatorsStr.isEmpty ? <String>[] : locatorsStr.split(';')`.

### 3.12 SHM (13 functions, guarded by feature flags)

All SHM functions are guarded by `#if defined(Z_FEATURE_SHARED_MEMORY) && defined(Z_FEATURE_UNSTABLE_API)`.

#### `zd_shm_provider_alloc`

```c
FFI_PLUGIN_EXPORT int zd_shm_provider_alloc(
    const z_loaned_shm_provider_t* provider,
    z_owned_shm_mut_t* buf,
    size_t size) {
  z_buf_layout_alloc_result_t result;
  z_shm_provider_alloc(&result, provider, size);
  if (result.status == ZC_BUF_LAYOUT_ALLOC_STATUS_OK) {
    *buf = result.buf;
    return 0;
  }
  return -1;
}
```

**Problem solved:** `z_shm_provider_alloc` returns a `z_buf_layout_alloc_result_t` struct with a status enum and a buffer. Dart cannot handle this compound return type. The shim flattens it to: write buffer into out-parameter, return 0/-1.

**Finding [C-13]: `*buf = result.buf` performs a struct copy.**

The `z_owned_shm_mut_t` is copied from the result struct into the caller-provided memory. Since `z_owned_shm_mut_t` is an opaque type, this struct copy is valid only if zenoh-c's ownership model allows it. In zenoh-c, `z_buf_layout_alloc_result_t.buf` is a `z_owned_shm_mut_t` that can be trivially copied (it contains only a pointer and metadata, no self-referential fields). The result struct is stack-local and goes out of scope, so the ownership is effectively moved.

**Assessment:** Correct. This is functionally equivalent to a move.

#### `zd_bytes_from_shm_mut`

```c
FFI_PLUGIN_EXPORT int zd_bytes_from_shm_mut(z_owned_bytes_t* bytes,
                                            z_owned_shm_mut_t* buf) {
  return z_bytes_from_shm_mut(bytes, z_shm_mut_move(buf));
}
```

**Problem solved:** Converts a mutable SHM buffer into `z_owned_bytes_t` (zero-copy). `z_shm_mut_move` is a macro.

**Dart side:** `ShmMutBuffer.toBytes()` marks the buffer as consumed, preventing double-free. The returned `ZBytes` owns the underlying memory.

---

## 4. Cross-Cutting Findings

### 4.1 Memory Ownership Protocol

The Dart side implements a three-state ownership model:

| State | Flags | Operations allowed |
|-------|-------|--------------------|
| **Live** | `_disposed=false, _consumed=false` | All operations |
| **Consumed** | `_consumed=true` | None (StateError) |
| **Disposed** | `_disposed=true` | `dispose()` (no-op) |

This is enforced consistently across `Config`, `ZBytes`, `ShmMutBuffer`, `KeyExpr`. The `markConsumed()` method is called after any FFI call that performs a `z_*_move()` on the native pointer. This correctly models zenoh-c's ownership transfer semantics in Dart.

**Finding [C-14]: `ZBytes.dispose()` skips `zd_bytes_drop` if consumed.**

```dart
void dispose() {
  if (_disposed) return;
  if (_consumed) return;  // skip drop -- ownership was transferred
  _disposed = true;
  bindings.zd_bytes_drop(_ptr.cast());
  calloc.free(_ptr);
}
```

When consumed, the native bytes have been moved into zenoh-c (e.g., via `z_bytes_move` in `zd_put`). The Dart wrapper memory (`_ptr`) is never freed in this path. This is a **minor memory leak**: the `calloc.allocate`'d wrapper (typically 8-64 bytes depending on `z_owned_bytes_t` size) is never released.

**Severity:** Low. The leaked memory is the Dart-side `calloc` wrapper, not the zenoh-c payload. The wrapper is small (the size of `z_owned_bytes_t`, typically ~32 bytes). In a long-running publisher loop, this accumulates. Fix: add `calloc.free(_ptr)` after the consumed check:

```dart
void dispose() {
  if (_disposed) return;
  _disposed = true;
  if (!_consumed) {
    bindings.zd_bytes_drop(_ptr.cast());
  }
  calloc.free(_ptr);
}
```

The `ShmMutBuffer.dispose()` already implements this pattern correctly:

```dart
void dispose() {
  if (_disposed) return;
  _disposed = true;
  if (!_consumed) {
    bindings.zd_shm_mut_drop(_ptr.cast());
  }
  calloc.free(_ptr);
}
```

### 4.2 Allocator Consistency

The codebase uses two Dart-side allocators:

| Allocator | Usage |
|-----------|-------|
| `calloc` | Opaque zenoh type wrappers, temporary buffers for FFI calls |
| `malloc` (via `toNativeUtf8()`) | Dart strings marshaled to C |

The `Session.open` method uses `calloc.free` for the session pointer in the error path, which is correct since `calloc.allocate` was used to allocate it. The comment in MEMORY.md about `zenoh.dart:32` using `calloc.free` for `malloc`'d memory is noted but requires verification against the actual code.

**Finding [C-15]: `Zenoh.initLog` frees `toNativeUtf8()` string with `calloc.free` instead of `malloc.free`.**

```dart
static void initLog(String fallback) {
  final cStr = fallback.toNativeUtf8();
  try {
    bindings.zd_init_log(cStr.cast<Char>());
  } finally {
    calloc.free(cStr);
  }
}
```

`toNativeUtf8()` allocates via `malloc` by default. Freeing it with `calloc.free` is technically incorrect. In practice, on most platforms, `calloc.free` and `malloc.free` both resolve to the same `free()` implementation, so this does not cause crashes. However, it violates the allocator pairing contract and should use `malloc.free(cStr)`.

**Severity:** Low (works in practice, incorrect in principle). The same issue exists in the MEMORY.md note about `zenoh.dart:32`.

### 4.3 Thread Safety

The C shim's callback functions (`_zd_sample_callback`, `_zd_matching_status_callback`, `_zd_scout_hello_callback`) are invoked by zenoh-c's internal threads. They use only:

1. Stack-local variables
2. The context struct (read-only access to `dart_port`)
3. `Dart_PostCObject_DL` (documented as thread-safe)

No shared mutable state is accessed without synchronization. The Dart `ReceivePort` handles thread-to-isolate message delivery. This is correct.

### 4.4 Error Handling Completeness

| C shim function | Return value on error | Dart exception |
|-----------------|----------------------|----------------|
| `zd_config_default` | negative | `ZenohException` |
| `zd_config_insert_json5` | negative | `ZenohException` |
| `zd_open_session` | negative | `ZenohException` |
| `zd_put` | negative | `ZenohException` |
| `zd_delete` | negative | `ZenohException` |
| `zd_declare_subscriber` | negative | `ZenohException` |
| `zd_declare_publisher` | negative | `ZenohException` |
| `zd_publisher_put` | negative | `ZenohException` |
| `zd_publisher_delete` | negative | `ZenohException` |
| `zd_publisher_get_matching_status` | negative | `ZenohException` |
| `zd_publisher_declare_background_matching_listener` | negative | `ZenohException` |
| `zd_scout` | negative | Not checked (see below) |
| `zd_bytes_copy_from_str` | negative | `ZenohException` |
| `zd_bytes_copy_from_buf` | negative | `ZenohException` |
| `zd_bytes_to_string` | negative | `ZenohException` |
| `zd_shm_provider_new` | negative | `ZenohException` |
| `zd_shm_provider_alloc` | negative | Returns null |
| `zd_shm_provider_alloc_gc_defrag_blocking` | negative | Returns null |
| `zd_bytes_from_shm_mut` | negative | `ZenohException` |

**Finding [C-16]: `Zenoh.scout` does not check the return value of `zd_scout`.**

```dart
bindings.zd_scout(cfgPtr.cast(), nativePort, timeoutMs, what);
return completer.future;
```

If `zd_scout` fails (e.g., invalid config), it still posts the null sentinel (line 612 of `zenoh_dart.c`), so the Dart completer will resolve with an empty list. The error is silently swallowed. The Dart code should check the return value and either throw or propagate the error.

**Severity:** Medium. Scout failures are indistinguishable from "no entities found."

### 4.5 Payload Binary Fidelity

**Finding [C-5 expanded]: The subscriber callback pipeline is:**

```
z_sample_payload() → z_bytes_to_string() → z_string_data/len → Dart_TypedData_kUint8 → Uint8List
```

`z_bytes_to_string` in zenoh-c v1.7.2 performs a copy and may interpret the bytes as UTF-8. For payloads that are not valid UTF-8, the behavior depends on the zenoh-c implementation. If it performs validation and rejects non-UTF-8, the conversion will fail silently. If it copies bytes verbatim (treating "string" as "byte sequence"), the data is preserved.

**Recommendation:** For guaranteed binary fidelity, the callback should use `z_bytes_reader` or `z_bytes_slice_iterator` to extract raw bytes without string interpretation. This would require changes to the C shim callback.

---

## 5. Summary of Findings

| ID | Description | Severity | Category |
|----|-------------|----------|----------|
| C-1 | Drop pattern (`move` + `drop`) is correct and consistent | N/A | Positive |
| C-2 | `z_close` return value ignored in `zd_close_session` | Low | Error handling |
| C-3 | Mixed `malloc`/`calloc` in `KeyExpr` is intentional and correct | N/A | Informational |
| C-4 | `ZBytes.fromUint8List` element-by-element copy | Low | Performance |
| C-5 | Payload bytes pass through `z_bytes_to_string` in subscriber callback | Medium | Correctness |
| C-6 | Key expression null-termination handling is correct | N/A | Positive |
| C-7 | Subscriber closure error-path defensive drop is correct | N/A | Positive |
| C-8 | Encoding ownership in publisher options is correct per zenoh-c contract | N/A | Positive |
| C-9 | Hardcoded 16-byte ZID matches zenoh protocol spec | N/A | Informational |
| C-10 | Max 64 ZIDs buffer limit in Dart | Low | Limitation |
| C-11 | Stack-allocated scout context is safe due to blocking `z_scout` | N/A | Positive |
| C-12 | Two-pass locator string building is correct | N/A | Positive |
| C-13 | Struct copy for SHM alloc result is correct | N/A | Positive |
| C-14 | `ZBytes.dispose()` leaks calloc wrapper when consumed | Low | Memory leak |
| C-15 | `Zenoh.initLog` frees `malloc`'d string with `calloc.free` | Low | Allocator mismatch |
| C-16 | `Zenoh.scout` ignores `zd_scout` return value | Medium | Error handling |

### Recommended Fixes (Priority Order)

1. **C-5 (Medium):** Replace `z_bytes_to_string` in `_zd_sample_callback` with a byte-level extraction API to preserve binary payload fidelity.
2. **C-16 (Medium):** Check `zd_scout` return value in Dart and throw `ZenohException` on failure.
3. **C-14 (Low):** Fix `ZBytes.dispose()` to free the calloc wrapper even when consumed (match `ShmMutBuffer` pattern).
4. **C-15 (Low):** Change `calloc.free(cStr)` to `malloc.free(cStr)` in `Zenoh.initLog`.
5. **C-4 (Low):** Use `nativeBuf.asTypedList(data.length).setAll(0, data)` for bulk copy in `ZBytes.fromUint8List`.

---

## 6. Architecture Assessment

The C shim is well-designed for its purpose. It solves the six core FFI impedance problems (macros, opaque sizes, closures, move semantics, options structs, loaning) with minimal additional complexity. Key strengths:

- **Minimal surface area:** Each shim function does exactly one thing, usually 1-5 lines of C code
- **Consistent ownership model:** The move/drop/gravestone pattern is applied uniformly
- **Safe callback bridge:** The NativePort pattern correctly handles thread safety between zenoh-c threads and the Dart event loop
- **Build system integration:** The three-tier library discovery (Android/prebuilt/developer) is well-structured
- **Feature gating:** SHM functions are properly guarded with preprocessor conditionals

The Dart side complements the shim with a clean three-state ownership model, idiomatic dispose patterns, and consistent error handling. The two layers together form a robust FFI bridge.
