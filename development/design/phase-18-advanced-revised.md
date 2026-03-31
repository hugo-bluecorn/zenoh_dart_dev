# Phase 18: Advanced Pub/Sub — Revised Design Spec

**Status:** DRAFT (rev 2 — incorporates CA2/Data review)
**Author:** CA (Riker)
**Date:** 2026-03-30
**Reviewed by:** CA2 (Data) — 2026-03-30
**Predecessor:** Phase 17 (Storage, PR #30)
**Original spec:** `development/phases/phase-18-advanced.md` (obsolete — written before deep API analysis)

---

## Goal

Implement advanced publisher and advanced subscriber — zenoh entities with
caching, history recovery, publisher/subscriber detection, and sample miss
detection. These are the most complex zenoh entities with the richest
configuration surface.

**Reference examples:**
- `extern/zenoh-c/examples/z_advanced_pub.c`
- `extern/zenoh-c/examples/z_advanced_sub.c`

**Reference tests:**
- `extern/zenoh-c/tests/z_int_advanced_pub_sub_test.c`
- `extern/zenoh-cpp/tests/universal/network/advanced_pub_sub.cxx`

## Scope Summary

| Metric | Before | After | Delta |
|--------|--------|-------|-------|
| C shim functions | 144 | 156 | +12 |
| Dart API classes/enums | 30 | 36 | +6 |
| CLI examples | 24 | 26 | +2 |
| Integration tests | 473 | ~500+ | ~+25-30 |

New types: `AdvancedPublisher`, `AdvancedPublisherOptions`, `HeartbeatMode` (enum),
`AdvancedSubscriber`, `AdvancedSubscriberOptions`, `MissEvent`.

This is the **most complex feature phase** in the project — more configuration
options than any prior phase, a new callback type (miss closure), and the
`ze_` unstable API namespace.

## Feature Flag Requirements

All `ze_*` advanced APIs are guarded by `Z_FEATURE_UNSTABLE_API` in zenoh-c.

**Build system (already in place):**
- Root `CMakeLists.txt`: `ZENOHC_BUILD_WITH_UNSTABLE_API=TRUE` (cargo build)
- `src/CMakeLists.txt`: `Z_FEATURE_UNSTABLE_API` compile definition (non-Android only)

**C shim guards:** All new functions MUST be wrapped in:
```c
#if defined(Z_FEATURE_UNSTABLE_API)
// ... advanced pub/sub functions ...
#endif
```

**Android:** Advanced features are unavailable on Android (same as SHM).
The Dart API should throw `UnsupportedError` on Android, or the functions
should simply not be exposed. Follow the SHM pattern.

## Configuration Prerequisite

Advanced features require timestamps enabled on the publisher's session:
```dart
config.insertJson5('timestamping/enabled', 'true');
```
The key is `Z_CONFIG_ADD_TIMESTAMP_KEY` = `"timestamping/enabled"`.

The subscriber session does NOT need this configuration — only the publisher.

## C Shim Functions to Add

### Advanced Publisher (7 functions)

```c
#if defined(Z_FEATURE_UNSTABLE_API)

/// Declare an advanced publisher with options.
///
/// @param session  Loaned session pointer.
/// @param publisher  Out: owned advanced publisher.
/// @param keyexpr  Loaned key expression.
/// @param enable_cache  Enable sample cache.
/// @param cache_max_samples  Max samples to cache (ignored if !enable_cache).
/// @param publisher_detection  Enable liveliness detection.
/// @param sample_miss_detection  Enable sequence numbering for miss detection.
/// @param heartbeat_mode  0=none, 1=periodic, 2=sporadic (ignored if !sample_miss_detection).
/// @param heartbeat_period_ms  Heartbeat period in ms (ignored if heartbeat_mode==0).
/// @return 0 on success, negative on failure.
FFI_PLUGIN_EXPORT int zd_declare_advanced_publisher(
    const z_loaned_session_t* session,
    ze_owned_advanced_publisher_t* publisher,
    const z_loaned_keyexpr_t* keyexpr,
    bool enable_cache,
    size_t cache_max_samples,
    bool publisher_detection,
    bool sample_miss_detection,
    int heartbeat_mode,
    uint64_t heartbeat_period_ms);

/// Publish a payload through an advanced publisher.
///
/// @param publisher  Loaned advanced publisher.
/// @param payload  Moved owned bytes (consumed on success).
/// @return 0 on success, negative on failure.
FFI_PLUGIN_EXPORT int zd_advanced_publisher_put(
    const ze_loaned_advanced_publisher_t* publisher,
    z_owned_bytes_t* payload);

/// Publish a DELETE through an advanced publisher.
///
/// @param publisher  Loaned advanced publisher.
/// @return 0 on success, negative on failure.
FFI_PLUGIN_EXPORT int zd_advanced_publisher_delete(
    const ze_loaned_advanced_publisher_t* publisher);

/// Loan the advanced publisher (owned -> loaned).
FFI_PLUGIN_EXPORT const ze_loaned_advanced_publisher_t* zd_advanced_publisher_loan(
    const ze_owned_advanced_publisher_t* publisher);

/// Drop the advanced publisher.
FFI_PLUGIN_EXPORT void zd_advanced_publisher_drop(
    ze_owned_advanced_publisher_t* publisher);

/// Return the key expression of an advanced publisher as a C string.
/// Caller must NOT free the returned string — it is loaned from the publisher.
FFI_PLUGIN_EXPORT const char* zd_advanced_publisher_keyexpr(
    const ze_loaned_advanced_publisher_t* publisher);

/// Return sizeof(ze_owned_advanced_publisher_t) for FFI allocation.
FFI_PLUGIN_EXPORT size_t zd_advanced_publisher_sizeof(void);

#endif // Z_FEATURE_UNSTABLE_API
```

### Advanced Subscriber (5 functions)

```c
#if defined(Z_FEATURE_UNSTABLE_API)

/// Declare an advanced subscriber with options.
///
/// Uses the NativePort callback bridge (same pattern as zd_declare_subscriber).
/// The sample callback posts [keyexpr, payload, kind, attachment, encoding] to dart_port.
///
/// @param session  Loaned session pointer.
/// @param subscriber  Out: owned advanced subscriber.
/// @param keyexpr  Loaned key expression.
/// @param dart_port  Dart NativePort for sample callbacks.
/// @param history  Enable history retrieval on connect.
/// @param history_detect_late_publishers  Detect late-joining publishers (requires publisher_detection on pub side).
/// @param recovery  Enable lost sample recovery.
/// @param recovery_last_sample_miss_detection  Enable last-sample miss detection within recovery.
/// @param recovery_periodic_queries_period_ms  Period for periodic queries (0 = use heartbeat).
/// @param subscriber_detection  Enable liveliness detection.
/// @return 0 on success, negative on failure.
FFI_PLUGIN_EXPORT int zd_declare_advanced_subscriber(
    const z_loaned_session_t* session,
    ze_owned_advanced_subscriber_t* subscriber,
    const z_loaned_keyexpr_t* keyexpr,
    int64_t dart_port,
    bool history,
    bool history_detect_late_publishers,
    bool recovery,
    bool recovery_last_sample_miss_detection,
    uint64_t recovery_periodic_queries_period_ms,
    bool subscriber_detection);

/// Declare a background sample miss listener on an advanced subscriber.
///
/// Miss events are posted to dart_port as [zid_raw_bytes (Uint8List, 16 bytes), nb_missed].
/// Uses ze_owned_closure_miss_t with NativePort bridge.
/// The ZID is posted as raw bytes (matching the scout callback pattern),
/// NOT as a hex string — ZenohId is constructed from raw bytes on the Dart side.
///
/// @param subscriber  Loaned advanced subscriber.
/// @param dart_port  Dart NativePort for miss event callbacks.
/// @return 0 on success, negative on failure.
FFI_PLUGIN_EXPORT int zd_advanced_subscriber_declare_background_sample_miss_listener(
    const ze_loaned_advanced_subscriber_t* subscriber,
    int64_t dart_port);

/// Loan the advanced subscriber (owned -> loaned).
FFI_PLUGIN_EXPORT const ze_loaned_advanced_subscriber_t* zd_advanced_subscriber_loan(
    const ze_owned_advanced_subscriber_t* subscriber);

/// Drop the advanced subscriber.
FFI_PLUGIN_EXPORT void zd_advanced_subscriber_drop(
    ze_owned_advanced_subscriber_t* subscriber);

/// Return sizeof(ze_owned_advanced_subscriber_t) for FFI allocation.
FFI_PLUGIN_EXPORT size_t zd_advanced_subscriber_sizeof(void);

#endif // Z_FEATURE_UNSTABLE_API
```

**Function count summary:** 7 publisher + 5 subscriber = 12 new C shim functions (144→156).
The sizeof functions are needed because these are opaque types — Dart must
allocate the right amount of memory via `calloc<Uint8>(sizeof)`.

## zenoh-c APIs Wrapped

| C shim function | zenoh-c function(s) |
|----------------|---------------------|
| `zd_declare_advanced_publisher` | `ze_declare_advanced_publisher`, `ze_advanced_publisher_options_default`, `ze_advanced_publisher_cache_options_default`, `ze_advanced_publisher_sample_miss_detection_options_default` |
| `zd_advanced_publisher_put` | `ze_advanced_publisher_put` (NULL options = defaults) |
| `zd_advanced_publisher_delete` | `ze_advanced_publisher_delete` (NULL options = defaults) |
| `zd_advanced_publisher_loan` | `ze_advanced_publisher_loan` |
| `zd_advanced_publisher_drop` | `ze_advanced_publisher_drop` |
| `zd_advanced_publisher_keyexpr` | `ze_advanced_publisher_keyexpr` → `z_keyexpr_as_view_string` |
| `zd_advanced_publisher_sizeof` | `sizeof(ze_owned_advanced_publisher_t)` |
| `zd_declare_advanced_subscriber` | `ze_declare_advanced_subscriber`, `ze_advanced_subscriber_options_default`, `ze_advanced_subscriber_history_options_default`, `ze_advanced_subscriber_recovery_options_default`, `ze_advanced_subscriber_last_sample_miss_detection_options_default` |
| `zd_advanced_subscriber_declare_background_sample_miss_listener` | `ze_advanced_subscriber_declare_background_sample_miss_listener`, `ze_owned_closure_miss_t` |
| `zd_advanced_subscriber_loan` | `ze_advanced_subscriber_loan` |
| `zd_advanced_subscriber_drop` | `ze_advanced_subscriber_drop` |
| `zd_advanced_subscriber_sizeof` | `sizeof(ze_owned_advanced_subscriber_t)` |

## Dart API Surface

### New file: `package/lib/src/advanced_publisher.dart`

```dart
/// Options for configuring an advanced publisher.
class AdvancedPublisherOptions {
  /// Enable sample cache. When enabled, late-joining advanced subscribers
  /// can retrieve cached history.
  /// - `null` = no cache (disabled)
  /// - `> 0` = cache with max N samples per resource
  /// - `0` = cache with unlimited samples per resource (zenoh-c semantics)
  final int? cacheMaxSamples;

  /// Enable publisher detection via liveliness. Allows advanced subscribers
  /// to detect this publisher.
  final bool publisherDetection;

  /// Enable sample miss detection with sequence numbering.
  /// Subscribers can detect gaps in the sequence.
  final bool sampleMissDetection;

  /// Heartbeat mode for miss detection: none, periodic, or sporadic.
  /// Only relevant when sampleMissDetection is true.
  final HeartbeatMode heartbeatMode;

  /// Heartbeat period in milliseconds. Only meaningful when
  /// heartbeatMode is periodic or sporadic. Ignored when mode is none.
  /// Default 500ms matches the zenoh-c example.
  final int heartbeatPeriodMs;

  const AdvancedPublisherOptions({
    this.cacheMaxSamples,
    this.publisherDetection = false,
    this.sampleMissDetection = false,
    this.heartbeatMode = HeartbeatMode.none,
    this.heartbeatPeriodMs = 0,
  });
}

/// Heartbeat mode for advanced publisher sample miss detection.
enum HeartbeatMode {
  /// No heartbeat.
  none(0),
  /// Periodic heartbeat — always sends sequence number at interval.
  periodic(1),
  /// Sporadic heartbeat — sends only when sequence number changed.
  sporadic(2);

  final int value;
  const HeartbeatMode(this.value);
}

/// An advanced publisher with caching, detection, and miss detection.
class AdvancedPublisher {
  /// Publish a string value.
  void put(String value);

  /// Publish raw bytes (ZBytes consumed on success).
  void putBytes(ZBytes payload);

  /// Publish a DELETE on this publisher's key expression.
  void deleteResource();

  /// The key expression this publisher is declared on.
  String get keyExpr;

  /// Close the advanced publisher and release native resources.
  void close();
}
```

### New file: `package/lib/src/advanced_subscriber.dart`

```dart
/// Options for configuring an advanced subscriber.
class AdvancedSubscriberOptions {
  /// Enable history retrieval on connect. Late-joining subscribers
  /// receive cached samples from advanced publishers.
  final bool history;

  /// Detect publishers that start after this subscriber.
  /// Requires publisherDetection on the publisher side.
  final bool detectLatePublishers;

  /// Enable lost sample recovery via retransmission from publisher cache.
  final bool recovery;

  /// Enable last-sample miss detection within recovery.
  /// When false, subscriber cannot detect/request retransmission of the
  /// last missed sample until a newer one arrives.
  final bool lastSampleMissDetection;

  /// Period for periodic queries for unreceived samples (ms).
  /// 0 = rely on publisher heartbeat instead of periodic queries.
  final int periodicQueriesPeriodMs;

  /// Enable subscriber detection via liveliness.
  final bool subscriberDetection;

  /// Enable miss event listener (Stream<MissEvent>).
  final bool enableMissListener;

  const AdvancedSubscriberOptions({
    this.history = false,
    this.detectLatePublishers = false,
    this.recovery = false,
    this.lastSampleMissDetection = false,
    this.periodicQueriesPeriodMs = 0,
    this.subscriberDetection = false,
    this.enableMissListener = false,
  });
}

/// An advanced subscriber with history recovery and miss detection.
class AdvancedSubscriber {
  /// Stream of received samples (includes recovered history).
  Stream<Sample> get stream;

  /// Stream of miss events (sample gaps detected).
  /// Only available when enableMissListener is true in options.
  Stream<MissEvent>? get missEvents;

  /// Close the advanced subscriber and release native resources.
  void close();
}

/// Information about missed samples.
class MissEvent {
  /// Zenoh ID of the source publisher that had gaps.
  final ZenohId sourceId;

  /// Number of missed samples.
  final int count;

  const MissEvent({required this.sourceId, required this.count});
}
```

### Modify `package/lib/src/session.dart`

```dart
class Session {
  /// Declare an advanced publisher with caching and miss detection.
  ///
  /// Requires `config.insertJson5('timestamping/enabled', 'true')` on the
  /// session config for advanced features to function correctly.
  AdvancedPublisher declareAdvancedPublisher(
    String keyExpr, {
    AdvancedPublisherOptions options = const AdvancedPublisherOptions(),
  });

  /// Declare an advanced subscriber with history recovery and miss detection.
  AdvancedSubscriber declareAdvancedSubscriber(
    String keyExpr, {
    AdvancedSubscriberOptions options = const AdvancedSubscriberOptions(),
  });
}
```

### Modify `package/lib/zenoh.dart`

Add exports for `AdvancedPublisher`, `AdvancedPublisherOptions`,
`HeartbeatMode`, `AdvancedSubscriber`, `AdvancedSubscriberOptions`, `MissEvent`.

## CLI Examples

### `package/example/z_advanced_pub.dart`

Mirrors `extern/zenoh-c/examples/z_advanced_pub.c`.

```
Usage: z_advanced_pub [OPTIONS]

Options:
    -k, --key <KEYEXPR>         Key expression (default: 'demo/example/zenoh-dart-advanced-pub')
    -p, --payload <VALUE>       Payload string (default: 'Advanced Pub from Dart!')
    -i, --history <N>           Cache size / history (default: 1)
    -e, --connect <ENDPOINT>    Connect endpoint
    -l, --listen <ENDPOINT>     Listen endpoint
```

**Behavior:**
1. Create config with `timestamping/enabled: true`
2. Open session
3. Declare advanced publisher with cache (max_samples from `-i`),
   publisher_detection=true, sample_miss_detection with periodic heartbeat
4. Loop: publish `"[<idx>] <payload>"` every second
5. Print `Declaring AdvancedPublisher on '<keyexpr>'...` and `Press CTRL-C to quit...`
6. Run until SIGINT, close publisher and session

### `package/example/z_advanced_sub.dart`

Mirrors `extern/zenoh-c/examples/z_advanced_sub.c`.

```
Usage: z_advanced_sub [OPTIONS]

Options:
    -k, --key <KEYEXPR>         Key expression (default: 'demo/example/**')
    -e, --connect <ENDPOINT>    Connect endpoint
    -l, --listen <ENDPOINT>     Listen endpoint
```

**Note:** The default key expression is `demo/example/**` (wildcard), matching
the zenoh-c `z_advanced_sub.c` example. This allows the subscriber to catch
any publisher under `demo/example/`. The zenoh-c example hardcodes all options
(history, recovery, subscriber_detection, miss listener) — it does not expose
them as CLI flags. Our Dart example should match this: enable everything by
default.

**Behavior:**
1. Open session (no timestamp config needed on subscriber)
2. Declare advanced subscriber with history (detect_late_publishers=true),
   recovery (last_sample_miss_detection with periodic queries period=1000ms),
   subscriber_detection=true
3. Declare background miss listener, print miss events
4. Print received samples: `>> [Subscriber] Received PUT ('keyexpr': 'value')`
5. Print miss events: `>> [Subscriber] Missed N samples from 'zid'`
6. Run until SIGINT, close subscriber and session

### Usage Scenario

```bash
# Terminal 1: Start advanced publisher (publishes with cache of 10)
cd package && fvm dart run example/z_advanced_pub.dart -i 10

# Wait a few seconds (publisher caches samples)

# Terminal 2: Start advanced subscriber (retrieves history + live)
cd package && fvm dart run example/z_advanced_sub.dart
# → Should receive cached history samples, then live samples
# → Miss events printed if gaps detected
```

## Callback Patterns

### Sample Callback (reuse existing)

The advanced subscriber uses the same `z_owned_closure_sample_t` as the
regular subscriber. The existing `_zd_sample_callback` function in
`zenoh_dart.c` can be reused directly — it posts
`[keyexpr, payload, kind, attachment, encoding]` to the Dart port.

### Miss Callback (new)

The miss listener uses `ze_owned_closure_miss_t`. The C shim callback:

1. Receives `const ze_miss_t* miss` with `miss->source` (`z_entity_global_id_t`)
   and `miss->nb` (`uint32_t`)
2. Extracts ZID: `z_id_t zid = z_entity_global_id_zid(&miss->source)`
3. Copies raw 16-byte ZID into a buffer (same pattern as the scout callback)
4. Posts `[zid_raw_bytes (Uint8List, 16 bytes), nb_missed (int)]` to Dart port
   via `Dart_PostCObject_DL`

**Important:** Post raw ZID bytes, NOT a hex string. The `ZenohId` class
constructs from raw bytes — this matches the established scout callback
pattern. There is no `ZenohId.fromHexString()` constructor.

The Dart side receives the array, constructs `MissEvent(sourceId, count)`
from the raw bytes, and adds it to the miss events stream controller.

## Build Prerequisites

### ffigen.yaml opaque type mappings

After adding the new C shim functions to `src/zenoh_dart.h`, verify that
`ffigen.yaml` includes opaque type mappings for:
- `ze_owned_advanced_publisher_t`
- `ze_loaned_advanced_publisher_t`
- `ze_owned_advanced_subscriber_t`
- `ze_loaned_advanced_subscriber_t`

Our existing SHM types required explicit mappings. The `ze_*` types are
guarded by `Z_FEATURE_UNSTABLE_API` — verify the ffigen config passes
this define (it should, since SHM types also require it). If the types
aren't in the ffigen scan scope, `bindings.dart` won't contain them.

### Two-step declaration for miss listener

The miss listener is a separate C call after subscriber creation:
```
Step 1: zd_declare_advanced_subscriber(session, &sub, ke, sample_port, ...)
Step 2: zd_advanced_subscriber_declare_background_sample_miss_listener(loan(sub), miss_port)
```

The Dart `Session.declareAdvancedSubscriber()` must internally:
1. Create two `ReceivePort`/`NativePort` pairs (samples + miss events)
2. Call `zd_declare_advanced_subscriber` with the sample port
3. If `options.enableMissListener`, call the miss listener with the miss port
4. **If step 3 fails, drop the subscriber from step 2** — cleanup is required

This two-step pattern has error cleanup implications the implementer must
handle. If the miss listener declaration fails after a successful subscriber
declaration, the subscriber must be dropped to avoid a resource leak.

## Deferred / Out of Scope

The following zenoh-c API surface exists but is NOT included in this phase:

| Feature | Why Deferred |
|---------|-------------|
| `publisher_detection_metadata` (keyexpr) | Niche use case, adds complexity |
| `subscriber_detection_metadata` (keyexpr) | Niche use case, adds complexity |
| `ze_advanced_publisher_put_options_t` (encoding, attachment) | Matches regular Publisher deferral pattern |
| `ze_advanced_publisher_delete_options_t` | No fields beyond base delete options |
| Cache `congestion_control`, `priority`, `is_express` | Expose as defaults, match regular Publisher pattern |
| `query_timeout_ms` on subscriber | Use zenoh-c default (0 = internal default) |
| History `max_samples` and `max_age_ms` on subscriber | Use zenoh-c defaults (0 = no limit) |
| `ze_advanced_subscriber_detect_publishers()` | Separate from declare — manual publisher detection |
| `ze_advanced_publisher_declare_matching_listener()` | Matching status for advanced publisher |
| `ze_declare_background_advanced_subscriber()` | Background variant — defer to future need |

These can be added incrementally in patch releases without breaking changes.

## Verification Criteria

1. `fvm dart analyze package` — no issues
2. All 473 existing tests still pass (regression)
3. ~25-30 new tests pass covering:
   - AdvancedPublisher: declare, put, putBytes, deleteResource, close
   - AdvancedSubscriber: declare, stream receives samples, close
   - History: pub caches N samples → sub with history receives them
   - Miss listener: miss events stream works (callback bridge)
   - Config: timestamp config on publisher session
   - Options: various option combinations
   - Error: operations after close throw
4. CLI examples start and produce expected output
5. End-to-end: z_advanced_pub → z_advanced_sub with history retrieval
6. C shim functions guarded by `#if defined(Z_FEATURE_UNSTABLE_API)`
7. ffigen regenerated after header changes

## Key Architectural Decisions

### 1. Flat C shim parameters vs options struct

The C shim flattens the hierarchical zenoh-c options into scalar parameters
(booleans, integers). This matches our established pattern (see
`zd_declare_advanced_publisher` signature) and avoids exposing nested C
structs through FFI. The Dart options classes provide the structured interface.

### 2. Reuse sample callback

The advanced subscriber's sample callback is identical to the regular
subscriber's — same `z_owned_closure_sample_t`, same payload format. We reuse
`_zd_sample_callback` and `_zd_sample_drop` directly.

### 3. Separate miss callback

The miss listener requires a separate `ze_owned_closure_miss_t` with a
different payload format (`[zid_raw_bytes, count]`). This gets its own Dart
port and stream controller in the `AdvancedSubscriber` class. The ZID is
posted as raw 16 bytes (matching the scout callback pattern), not as a hex
string.

### 4. HeartbeatMode as enum

Rather than exposing a raw integer, we create a proper Dart enum matching
the three zenoh-c values (NONE=0, PERIODIC=1, SPORADIC=2). This is
type-safe and self-documenting.
