# Changelog
## 0.13.0

### Added
- CLI example: `z_ping_shm.dart` — SHM zero-copy latency benchmark
  using allocate-once-clone-in-loop pattern
- 10 new integration tests (372 → 382 total): SHM clone semantics
  (6 tests) and z_ping_shm CLI (4 tests)

### Changed
- SHM pool minimum size enforced at 65536 bytes for Talc allocator
  compatibility with small payloads


## 0.12.0

### Added
- `Session.declareBackgroundSubscriber()` returns `Stream<Sample>` — fire-and-forget
  subscriber that lives until session closes, no explicit close needed
- `ZBytes.toBytes()` — reads content as `Uint8List` (non-destructive, can be called
  multiple times)
- `ZBytes.clone()` — shallow ref-counted copy with independent lifetime
- CLI examples: `z_ping.dart` (latency measurement), `z_pong.dart` (echo responder)
- 4 new C shim functions (88 → 92 total): zd_declare_background_subscriber,
  zd_bytes_clone, zd_bytes_len, zd_bytes_to_buf
- 32 new integration tests (340 → 372 total)

### Changed
- `Session.declarePublisher()` now accepts `isExpress` parameter (default false)
  for low-latency batching control
- `zd_declare_publisher` C signature extended with 7th parameter `is_express`
  (sentinel -1 = default)

## 0.11.0

### Added
- `Session.declareLivelinessToken()` returns `LivelinessToken` — announces
  entity presence on the network; token disappearance triggers DELETE events
- `Session.declareLivelinessSubscriber()` returns `Subscriber` — observes
  token PUT (appearance) and DELETE (disappearance) events with optional
  `history` parameter to receive pre-existing alive tokens
- `Session.livelinessGet()` returns `Stream<Reply>` — discovers currently
  alive tokens with configurable timeout
- `LivelinessToken` class with `keyExpr` and `close()`
- 5 new C shim functions (83 → 88 total): zd_liveliness_token_sizeof,
  zd_liveliness_declare_token, zd_liveliness_token_drop,
  zd_liveliness_declare_subscriber, zd_liveliness_get
- CLI examples: `z_liveliness.dart`, `z_sub_liveliness.dart`,
  `z_get_liveliness.dart`
- 30 new integration tests (310 → 340 total)

## 0.10.0

### Added
- `Session.declareQuerier()` returns `Querier` — long-lived entity for
  repeated queries on the same key expression
- `Querier` class with `get()` (returns `Stream<Reply>`), `keyExpr`, `close()`,
  `hasMatchingQueryables()`, `matchingStatus` stream; declaration-time options
  (target, consolidation, timeout) fixed at creation, per-query options
  (payload, encoding) vary per `get()` call
- 6 new C shim functions (77 → 83 total): zd_querier_sizeof,
  zd_declare_querier, zd_querier_drop, zd_querier_get,
  zd_querier_declare_background_matching_listener,
  zd_querier_get_matching_status
- CLI example: `z_querier.dart`
- 28 new integration tests (282 → 310 total)

## 0.9.0

### Added
- `Session.declarePullSubscriber()` returns `PullSubscriber` with synchronous
  `tryRecv()` polling via ring buffer
- `PullSubscriber` class with `tryRecv()` (returns `Sample?`), `keyExpr`,
  `close()`, and configurable ring buffer `capacity` (lossy: drops oldest on
  overflow)
- 4 new C shim functions (73 → 77 total): zd_ring_handler_sample_sizeof,
  zd_declare_pull_subscriber, zd_pull_subscriber_try_recv,
  zd_ring_handler_sample_drop
- CLI example: `z_pull.dart` (interactive stdin polling)
- 20 new integration tests (262 → 282 total)

## 0.8.0

### Changed
- `Session.get()` payload parameter widened from `Uint8List?` to `ZBytes?` —
  accepts SHM-backed bytes for zero-copy query payloads
- `Query.replyBytes()` payload parameter widened from `Uint8List` to `ZBytes` —
  accepts SHM-backed bytes for zero-copy reply payloads
- `zd_get()` and `zd_query_reply()` C shim signatures updated: raw
  `uint8_t* + len` replaced with `z_owned_bytes_t*` (consumed)

### Added
- `ZBytes.isShmBacked` property — detects whether bytes are backed by
  shared memory (SHM feature-guarded, returns false on Android)
- 1 new C shim function `zd_bytes_is_shm()` (72 → 73 total)
- CLI examples: `z_get_shm.dart`, `z_queryable_shm.dart`
- 25 new integration tests (237 → 262 total)

## 0.7.0

### Added
- `Session.get()` returns `Stream<Reply>` with selector, parameters, payload,
  encoding, target, consolidation, and timeout options
- `Session.declareQueryable()` returns `Queryable` with `stream`, `keyExpr`,
  `close()`, and `complete` flag
- `Query` class with `reply()`, `replyBytes()`, `dispose()`, `keyExpr`,
  `parameters`, `payloadBytes` — supports multiple replies per query via
  clone-and-post pattern
- `Reply` tagged union with `isOk`, `ok` (Sample), `error` (ReplyError) accessors
- `ReplyError` class with `payloadBytes`, `payload`, `encoding` fields
- `QueryTarget` enum: bestMatching, all, allComplete
- `ConsolidationMode` enum: auto, none, monotonic, latest
- 10 new C shim functions (62 → 72 total): zd_get, zd_declare_queryable,
  zd_queryable_drop, zd_queryable_sizeof, zd_query_sizeof, zd_query_reply,
  zd_query_drop, zd_query_keyexpr, zd_query_parameters, zd_query_payload
- CLI examples: `z_get.dart`, `z_queryable.dart`
- 44 new integration tests (193 → 237 total)

## 0.6.2 (Unreleased)

### Fixed
- Inter-process SIGSEGV crash when two Dart processes connect via zenoh TCP
  - Root cause: `@Native` lazy loading via `NoActiveIsolateScope` causes tokio
    waker vtable dispatch failure on background threads
  - Fix: reverted from `@Native` ffi-native bindings to class-based
    `ZenohDartBindings(DynamicLibrary)` loaded eagerly via `DynamicLibrary.open()`
  - Removed wrong-fix `zd_promote_zenohc_global()` C shim function (62 shim
    functions, unchanged from Phase 5)

### Added
- 13 new tests (193 total): native lib pre-load (6), inter-process TCP
  connection (4), inter-process pub/sub data exchange (3)
- Test helpers: `interprocess_connect.dart`, `interprocess_pubsub.dart`

### Changed
- `bindings.dart` regenerated as class-based (was `@Native` ffi-native)
- `native_lib.dart`: `ensureInitialized()` now loads via `DynamicLibrary.open()`
  with path resolution from package root (`native/linux/x86_64/`)

## Experiment B2: CBuilder + @Native Annotations (2026-03-10)

### Added
- Experiment package `exp_hooks_cbuilder_native` testing CBuilder.library() compilation + @Native annotation loading
- CBuilder compiles vendored C shim from source, linking against prebuilt `libzenohc.so`
- `@DefaultAsset` + `@Native` bindings with CBuilder `assetName` alignment
- 10 automated tests (all pass)
- `lessons-learned.md` with full 2x2 matrix comparison and migration recommendation

### Results
- **POSITIVE**: CBuilder + @Native successfully compiles and loads without `LD_LIBRARY_PATH`
- Completes the 2x2 experiment matrix: @Native is the sole determinant of success
- CBuilder auto-sets RUNPATH=$ORIGIN (no patchelf), `native_toolchain_c` 0.17.5 stable
- Migration recommendation: start with prebuilt+@Native (A2), consider CBuilder for CI/CD

## Experiment B1: CBuilder + DynamicLibrary.open() (2026-03-10)

### Added
- Experiment package `exp_hooks_cbuilder_dlopen` testing CBuilder.library() compilation from source + DynamicLibrary.open() loading
- Build hook compiles minimal 2-function C shim via `native_toolchain_c` CBuilder, linking against prebuilt `libzenohc.so`
- Vendored C source (zenoh_dart_minimal), Dart API DL files, and zenoh-c headers (15 files total)
- 11 automated tests (6 pass, 5 skip with documented negative result)
- Control test proving CBuilder output works with explicit `LD_LIBRARY_PATH`
- `lessons-learned.md` with CBuilder-specific observations and A1/A2/B1 comparison

### Results
- **NEGATIVE** (expected): `DynamicLibrary.open()` cannot find CBuilder output, same as A1
- CBuilder compiles successfully (~1s cold, ~0.3s warm), auto-sets RUNPATH=$ORIGIN
- Confirms loading mechanism (not build strategy) is the independent variable
- `native_toolchain_c` 0.17.5 works reliably despite EXPERIMENTAL status

## Experiment A2: Prebuilt + @Native Annotations (2026-03-10)

### Added
- Experiment package `exp_hooks_prebuilt_native` testing Dart build hooks with prebuilt native libraries and `@Native` annotation loading
- Build hook (`hook/build.dart`) declaring two `CodeAsset` entries with `DynamicLoadingBundled()`
- `@DefaultAsset` library directive + `@Native` external function declarations (no `DynamicLibrary.open()`)
- RUNPATH patching via `patchelf --set-rpath '$ORIGIN'` for DT_NEEDED resolution
- 9 automated tests (all pass)
- `lessons-learned.md` with empirical results and A1 vs A2 comparison

### Results
- **POSITIVE**: `@Native` + `@DefaultAsset` successfully resolves hook-bundled assets without `LD_LIBRARY_PATH`
- DT_NEEDED dependency (`libzenohc.so`) resolves via co-located RUNPATH=`$ORIGIN`
- CodeAsset names must use bare relative paths (constructor auto-prefixes `package:<name>/`)
- Post-test SEGV during VM teardown is cosmetic (zenoh cleanup ordering)

## Experiment A1: Both-Prebuilt + DynamicLibrary.open() (2026-03-10)

### Added
- Experiment package `exp_hooks_prebuilt_dlopen` testing Dart build hooks with prebuilt native libraries and `DynamicLibrary.open()` loading
- Build hook (`hook/build.dart`) declaring two `CodeAsset` entries with `DynamicLoadingBundled()` for `libzenoh_dart.so` and `libzenohc.so`
- 7 automated tests (2 pass, 5 skip with documented reasons)
- `lessons-learned.md` with empirical results for all 6 verification criteria

### Results
- **NEGATIVE** (expected): `DynamicLibrary.open()` cannot find hook-bundled assets — OS linker (`ld.so`) does not read hook metadata
- Hook builds succeed and register metadata, but no files are copied to linker-accessible locations
- Confirms Experiment A2 (`@Native` annotations) is required for hook-based native library resolution

## 0.6.1 (Unreleased)

### Added
- `Sample.payloadBytes` field (`Uint8List`): exposes raw payload bytes alongside the existing `payload` String field, enabling binary data consumers (Protobuf, CBOR, images) without breaking the string API
- 7 new tests (185 total) covering payloadBytes construction, binary round-trip, delete samples, and multi-sample sequences
## 0.6.0 (Unreleased)

### Added
- `ZenohId` class: 16-byte identifier with hex formatting, equality, and hashCode
- `WhatAmI` enum: router, peer, client values mapping zenoh-c bitmask (1, 2, 4)
- `Hello` class: scouting result with zid, whatami, and locators fields
- `Session.zid`: returns the session's own `ZenohId`
- `Session.routersZid()`: returns connected router ZIDs via synchronous buffer collection
- `Session.peersZid()`: returns connected peer ZIDs via synchronous buffer collection
- `Zenoh.scout()`: discovers zenoh entities on the network via NativePort callback bridge
- C shim: 6 new `zd_info_*`/`zd_scout`/`zd_id_to_string`/`zd_whatami_to_view_string` functions (62 total)
- CLI example `z_info.dart`: prints session ZID, router ZIDs, and peer ZIDs with `-e`/`--connect`, `-l`/`--listen` flags
- CLI example `z_scout.dart`: discovers zenoh entities with `-e`/`--connect`, `-l`/`--listen` flags
- 30 new tests (178 total) covering ZenohId/WhatAmI value types, session info queries, scout discovery, and CLI examples
## 0.5.0 (Unreleased)

### Added
- `ShmProvider` class: POSIX shared memory provider with `alloc()`, `allocGcDefragBlocking()`, `available`, and `close()`
- `ShmMutBuffer` class: mutable SHM buffer with `data` pointer (zero-copy write), `length`, `toBytes()` (zero-copy conversion to ZBytes), and `dispose()`
- SHM-published data received transparently by standard subscribers via existing `Publisher.putBytes()`
- C shim: 13 `zd_shm_*` functions guarded with `#if defined(Z_FEATURE_SHARED_MEMORY) && defined(Z_FEATURE_UNSTABLE_API)`
- `src/CMakeLists.txt`: `-DZ_FEATURE_SHARED_MEMORY -DZ_FEATURE_UNSTABLE_API` compile definitions
- ffigen.yaml: 6 SHM opaque type mappings (`z_owned_shm_provider_t`, `z_loaned_shm_provider_t`, `z_moved_shm_provider_t`, `z_owned_shm_mut_t`, `z_loaned_shm_mut_t`, `z_moved_shm_mut_t`)
- CLI example `z_pub_shm.dart`: SHM publisher with `-k`/`--key`, `-p`/`--payload`, `--add-matching-listener`, `-e`/`--connect`, `-l`/`--listen` flags
- 28 new tests (148 total) covering SHM provider lifecycle, buffer allocation/properties, data pointer/toBytes, SHM pub/sub integration, and CLI
## 0.4.0 (Unreleased)

### Added
- `Publisher` class: declared publisher with `put()`, `putBytes()`, `deleteResource()`, `keyExpr`, `hasMatchingSubscribers()`, `matchingStatus` stream, and `close()`
- `Encoding` class: MIME type wrapper with 10 predefined constants (textPlain, applicationJson, etc.) and custom constructor
- `CongestionControl` enum: `block` and `drop` congestion control strategies
- `Priority` enum: 7 priority levels from `realTime` to `background`
- `Session.declarePublisher()`: declare a publisher with optional encoding, congestionControl, priority, and enableMatchingListener
- `Sample.encoding` field: nullable String for received sample encoding (non-breaking)
- C shim subscriber callback updated to extract and post encoding as 5th Dart_CObject array element
- C shim `zd_publisher_sizeof()`, `zd_declare_publisher()`, `zd_publisher_loan()`, `zd_publisher_drop()`, `zd_publisher_put()`, `zd_publisher_delete()`, `zd_publisher_keyexpr()`, `zd_publisher_declare_background_matching_listener()`, `zd_publisher_get_matching_status()`
- CLI example `z_pub.dart`: publishes in a loop with `-k`/`--key`, `-p`/`--payload`, `-a`/`--attach`, `-e`/`--connect`, `-l`/`--listen`, `--add-matching-listener` flags
- 40 new tests (120 total) covering publisher lifecycle, put/putBytes, delete, encoding, matching status, QoS options, pub/sub integration, and CLI

## 0.3.0 (Unreleased)

### Added
- `Subscriber` class: callback-based subscriber with `Stream<Sample>` delivery via NativePort bridge pattern
- `Sample` class: received data with `keyExpr`, `payload`, `kind`, `attachment` fields
- `SampleKind` enum: `put` and `delete` sample kinds
- `Session.declareSubscriber(keyExpr)`: declare a subscriber on a key expression, returns `Subscriber`
- C shim `zd_declare_subscriber()`: declares subscriber with NativePort callback bridge (Dart_CObject array posted via Dart_PostCObject_DL)
- C shim `zd_subscriber_drop()`: undeclares and drops subscriber
- C shim `zd_subscriber_sizeof()`: returns sizeof(z_owned_subscriber_t)
- CLI example `z_sub.dart`: subscribes to key expression with `-k`/`--key`, `-e`/`--connect`, `-l`/`--listen` flags
- `-e`/`--connect` and `-l`/`--listen` flags added to `z_put.dart` for explicit endpoint configuration
- 22 new tests (80 total) covering subscriber lifecycle, NativePort bridge delivery, stream close, multi-subscriber independence, and CLI

## 0.2.0 (Unreleased)

### Added
- `Session.put(keyExpr, value)`: one-shot string publish on a key expression
- `Session.putBytes(keyExpr, payload)`: one-shot ZBytes publish with payload consumption semantics
- `Session.deleteResource(keyExpr)`: one-shot delete on a key expression (fire-and-forget)
- `Session._ensureOpen()` guard: throws `StateError` on operations after `close()`
- `ZBytes.markConsumed()` and consumed-state guard matching the `Config` pattern
- `ZBytes.nativePtr` getter with disposed/consumed guards for FFI interop
- `KeyExpr.nativePtr` getter for FFI interop
- C shim `zd_put()`: forwards to `z_put()` with default options and `z_bytes_move()` payload consumption
- C shim `zd_delete()`: forwards to `z_delete()` with default options
- CLI example `z_put.dart`: opens session, puts data with `--key`/`--payload` options, closes session
- CLI example `z_delete.dart`: opens session, deletes key with `--key` option, closes session
- 17 new tests (56 total) covering put/putBytes/deleteResource operations and CLI examples

## 0.1.0 (Unreleased)

### Added
- Build system: CMakeLists.txt compiles C shim with Dart SDK headers and links against libzenohc.so via three-tier discovery (Android jniLibs, Linux prebuilt, developer fallback) with RPATH set to $ORIGIN
- C shim (`src/zenoh_dart.{h,c}`): 29 `zd_`-prefixed FFI functions wrapping zenoh-c v1.7.2 APIs for config, session, keyexpr, bytes, and string operations
- Dart SDK headers (`src/dart/`) compiled into libzenoh_dart.so for Dart Native API DL support
- ffigen configuration (`ffigen.yaml`) with zenoh-c include paths and opaque type mappings for `z_owned_*`, `z_loaned_*`, `z_view_*`, `z_moved_*` types
- Auto-generated FFI bindings (`bindings.dart`) via dart:ffi ffigen
- Native library loader (`native_lib.dart`) with automatic Dart API DL initialization on first load
- `Config` class: default config creation, `insertJson5()` for mutable config modification, `dispose()`, consumed-state tracking with `StateError` guards
- `Session` class: `open()` factory (with optional config), graceful `close()` (z_close then z_session_drop), config consumption marking
- `KeyExpr` class: construct from string expression, `value` getter (data+len extraction, no null-termination assumption), `dispose()` freeing dual native allocations (struct + C string)
- `ZBytes` class: `fromString()`, `fromUint8List()`, `toStr()` round-trip with proper owned-string lifecycle, `dispose()`
- `ZenohException` class with message and return code for zenoh-c error propagation
- Barrel export (`package/lib/zenoh.dart`) for Config, Session, KeyExpr, ZBytes, ZenohException
- Logging initialization via `zd_init_log()` wrapping `zc_init_log_from_env_or()`
- Double-drop/double-close safety on all owned types (gravestone-state no-op pattern)
- Idempotent `dispose()`/`close()` guarded by `_disposed`/`_closed` flags
- 33 integration tests across 5 test files validating the full Dart → FFI → C shim → zenoh-c stack

## 0.0.1 (Unreleased)

- Initial scaffold: Melos monorepo with pure Dart `zenoh` package
