# Dart Client Integration Testing Framework

> **Purpose**: Define how to validate that `package:zenoh` actually works
> against a real zenohd router and cross-language peers.
>
> **Audience**: CI (implementer), CP (planner), CA (architect review).
>
> **Companion docs**:
> - `development/design/xplr-counter-migration-analysis.md` — xplr analysis
> - `development/design/flutter-counter-app-design.md` — Flutter app design

## 1. Current Test Landscape (Phases 0-2)

All 80 existing tests are **in-process integration tests**. They call through
real FFI into `libzenohc.so` — no mocks. Two patterns:

| Pattern | Example | Sessions | Network |
|---------|---------|----------|---------|
| **Single-session** | `session_test.dart` (open/close) | 1 | None |
| **Two-session TCP** | `subscriber_test.dart` (pub/sub) | 2, explicit TCP listen/connect | Loopback only |

Two-session tests use unique TCP ports per test group (17448-17450, 18551) to
avoid conflicts. Sessions connect via `tcp/127.0.0.1:<port>` — multicast
scouting doesn't work within a single process.

**What these tests prove**: FFI bindings, C shim correctness, Dart API
semantics, stream lifecycle, cleanup.

**What they don't prove**: Router routing, cross-process communication,
cross-language interop, network discovery, Android deployment.

## 2. Test Tier Architecture

```
Tier 1: In-Process (existing)           -- fvm dart test
  Dart <--> FFI <--> libzenohc.so
  Two peer sessions in same process
  Proves: API contracts, stream behavior, cleanup

Tier 2: Router Integration (NEW)        -- scripts/test-with-router.sh
  zenohd <--> Dart client
  Proves: client-mode works, router routing works

Tier 3: Cross-Language E2E (NEW)        -- scripts/test-e2e.sh
  zenohd <--> C++ counter app <--> Dart client
  Proves: real protocol interop (binary int64, JSON commands)

Tier 4: Flutter Integration (DEFERRED)  -- flutter test / flutter drive
  Flutter app <--> zenohd <--> C++ counter
  Proves: UI + network end-to-end
  (Covered in flutter-counter-app-design.md)
```

## 3. Building zenohd from extern/zenoh

The `extern/zenoh` submodule at v1.7.2 provides the zenohd router binary.
Tiers 2+ require it.

```bash
# One-time build (requires Rust stable toolchain)
cd extern/zenoh
RUSTUP_TOOLCHAIN=stable cargo build --release --package zenohd

# Binary location
extern/zenoh/target/release/zenohd

# Verify
extern/zenoh/target/release/zenohd --version
```

**Important**: zenohd version must match zenoh-c version (both v1.7.2).
Mismatched versions cause protocol incompatibilities.

## 4. Tier 2: Router Integration Tests

**Goal**: Validate that zenoh_dart clients work correctly when connecting
through a zenohd router rather than direct peer-to-peer.

**Prerequisites**:
- `extern/zenoh` submodule (already added)
- zenohd built (Section 3)
- `libzenohc.so` and `libzenoh_dart.so` built

### 4.1 Test Script

**`scripts/test-with-router.sh`**

```bash
#!/bin/bash
# Starts zenohd, runs Dart tests that require a router, stops zenohd.
set -euo pipefail

ZENOHD="extern/zenoh/target/release/zenohd"
PORT=17460  # unique port to avoid conflicts with Tier 1

# Start zenohd in background
$ZENOHD -l "tcp/127.0.0.1:$PORT" --no-multicast-scouting &
ZENOHD_PID=$!
trap "kill $ZENOHD_PID 2>/dev/null; wait $ZENOHD_PID 2>/dev/null" EXIT
sleep 2

# Run router-dependent tests
cd package
LD_LIBRARY_PATH=../../extern/zenoh-c/target/release:../../build \
  ZENOH_TEST_ROUTER="tcp/127.0.0.1:$PORT" \
  fvm dart test --tags router
```

### 4.2 Dart Test Pattern

```dart
@Tags(['router'])
void main() {
  final routerEndpoint = Platform.environment['ZENOH_TEST_ROUTER'];

  group('Client-mode session via router', () {
    late Session session;

    setUpAll(() {
      final config = Config();
      config.insertJson5('mode', '"client"');
      config.insertJson5(
        'connect/endpoints', '["$routerEndpoint"]');
      session = Session.open(config: config);
    });

    tearDownAll(() {
      session.close();
    });

    test('session.zid returns valid ZenohId', () {
      expect(session.zid.bytes, hasLength(16));
    });

    test('put through router reaches subscriber', () async {
      // Second client session
      final config2 = Config();
      config2.insertJson5('mode', '"client"');
      config2.insertJson5(
        'connect/endpoints', '["$routerEndpoint"]');
      final session2 = Session.open(config: config2);

      final sub = session2.declareSubscriber('test/router/put');
      await Future.delayed(Duration(seconds: 1));

      session.put('test/router/put', 'via router');

      final sample = await sub.stream.first
          .timeout(Duration(seconds: 5));
      expect(sample.payload, equals('via router'));

      sub.close();
      session2.close();
    });
  });
}
```

### 4.3 Key Behaviors to Test

**Available now (Phases 0-2)**:
- Client-mode session opens successfully
- Put/subscribe routes through router (not direct peer)
- Multiple clients see each other's publications
- Subscriber stream lifecycle works through router

**After Phase 3 (publisher)**:
- Publisher.put routes through router
- Publisher.deleteResource routes through router
- Matching listener fires through router
- Publisher with encoding option works through router

**After Phase 5 (scout/info)**:
- `session.zid` returns valid ZenohId
- `session.routersZid()` returns the router's ZID
- `session.peersZid()` returns empty list (client mode has no peers)
- `Zenoh.scout()` discovers the running router

## 5. Tier 3: Cross-Language E2E Tests

**Goal**: Validate the actual counter protocol — C++ app publishes raw
`int64_t` bytes on `demo/counter` and JSON on `demo/control/state`; Dart
client subscribes and sends JSON commands on `demo/control/command`.

**Prerequisites**:
- zenohd built (Section 3)
- C++ counter app built: `cmake --build apps/cpp_counter/build`
- Phase 3 (publisher) implemented in zenoh_dart
- `payloadBytes` field on Sample (see Section 7)

### 5.1 Test Script

**`scripts/test-e2e.sh`**

```bash
#!/bin/bash
# Full E2E: zenohd + C++ counter + Dart test client
set -euo pipefail

PORT=17470
ZENOHD="extern/zenoh/target/release/zenohd"
CPP_APP="apps/cpp_counter/build/zenoh_cpp_app"

# Start zenohd
$ZENOHD -l "tcp/127.0.0.1:$PORT" --no-multicast-scouting &
ZENOHD_PID=$!
sleep 2

# Start C++ counter (2s interval, client mode)
$CPP_APP -e "tcp/127.0.0.1:$PORT" -i 2000 --no-multicast-scouting &
CPP_PID=$!
sleep 2

trap "kill $CPP_PID $ZENOHD_PID 2>/dev/null; wait" EXIT

# Run E2E Dart tests
cd package
LD_LIBRARY_PATH=../../extern/zenoh-c/target/release:../../build \
  ZENOH_TEST_ROUTER="tcp/127.0.0.1:$PORT" \
  fvm dart test --tags e2e
```

### 5.2 Dart E2E Test Pattern

```dart
@Tags(['e2e'])
void main() {
  final router = Platform.environment['ZENOH_TEST_ROUTER']!;

  group('Counter protocol E2E', () {
    late Session session;

    setUpAll(() {
      final config = Config();
      config.insertJson5('mode', '"client"');
      config.insertJson5('connect/endpoints', '["$router"]');
      session = Session.open(config: config);
    });

    tearDownAll(() {
      session.close();
    });

    test('receives binary counter value from C++ app', () async {
      // Send play command
      session.put('demo/control/command', '{"action":"play"}');

      // Subscribe to counter (raw int64 bytes)
      final sub = session.declareSubscriber('demo/counter');
      await Future.delayed(Duration(seconds: 1));

      final sample = await sub.stream.first
          .timeout(Duration(seconds: 10));

      // Decode raw int64 from payloadBytes
      final bytes = sample.payloadBytes;
      expect(bytes.length, equals(8));
      final value = bytes.buffer.asByteData().getInt64(0, Endian.little);
      expect(value, greaterThan(0));

      sub.close();
    });

    test('receives JSON state from C++ app', () async {
      final sub = session.declareSubscriber('demo/control/state');
      await Future.delayed(Duration(seconds: 1));

      session.put('demo/control/command', '{"action":"play"}');

      final sample = await sub.stream.first
          .timeout(Duration(seconds: 10));

      final json = jsonDecode(sample.payload) as Map<String, dynamic>;
      expect(json['state'], equals('playing'));
      expect(json['counter'], isA<int>());

      sub.close();
    });

    test('stop command stops counter', () async {
      final sub = session.declareSubscriber('demo/control/state');
      await Future.delayed(Duration(seconds: 1));

      session.put('demo/control/command', '{"action":"stop"}');

      final sample = await sub.stream.first
          .timeout(Duration(seconds: 10));

      final json = jsonDecode(sample.payload) as Map<String, dynamic>;
      expect(json['state'], equals('stopped'));

      sub.close();
    });
  });
}
```

### 5.3 Counter Protocol Reference

The C++ counter app implements this protocol:

| Key Expression | Direction | Format | Description |
|---------------|-----------|--------|-------------|
| `demo/counter` | C++ -> Dart | raw int64 (8 bytes, little-endian) | Counter value |
| `demo/control/state` | C++ -> Dart | JSON `{"state":"playing","counter":42}` | State broadcast |
| `demo/control/command` | Dart -> C++ | JSON `{"action":"play"}` | Control commands |

Valid actions: `play`, `pause`, `stop`, `reset`.
State machine: stopped -> playing -> paused -> stopped.

## 6. Test Tag Convention

| Tag | Tier | Requires | Run with |
|-----|------|----------|----------|
| (none) | 1 | libzenohc + libzenoh_dart | `fvm dart test` |
| `router` | 2 | + zenohd running | `scripts/test-with-router.sh` |
| `e2e` | 3 | + zenohd + C++ app | `scripts/test-e2e.sh` |

Untagged tests (Tier 1) run in CI without any external processes.
Tagged tests require scripts that manage process lifecycle.

**Dart test tag configuration** (`package/dart_test.yaml`):

```yaml
tags:
  router:
    skip: "Requires zenohd. Run via scripts/test-with-router.sh"
  e2e:
    skip: "Requires zenohd + C++ app. Run via scripts/test-e2e.sh"
```

This ensures `fvm dart test` (without tags) skips router/e2e tests
automatically, while the scripts pass `--tags` to include them.

## 7. CRITICAL: The payloadBytes Prerequisite

The C++ counter publishes raw `int64_t` bytes on `demo/counter`:

```cpp
std::vector<uint8_t> bytes(sizeof(int64_t));
std::memcpy(bytes.data(), &counter, sizeof(int64_t));
counter_publisher.put(Bytes(bytes));
```

Current zenoh_dart `Sample.payload` is a `String` decoded via
`utf8.decode(payloadBytes)` at `subscriber.dart:48`. This **will crash**
on arbitrary binary data (invalid UTF-8 sequences).

**Fix**: Add `payloadBytes: Uint8List` field to `Sample`:

```dart
class Sample {
  final String keyExpr;
  final String payload;         // UTF-8 decoded (empty string if binary)
  final Uint8List payloadBytes; // Raw bytes, always available
  final SampleKind kind;
  final String? attachment;
  final String? encoding;       // Added in Phase 3
}
```

And update `subscriber.dart` to handle binary data gracefully:

```dart
final payloadBytes = message[1] as Uint8List;
String payload;
try {
  payload = utf8.decode(payloadBytes);
} catch (_) {
  payload = '';  // Binary data -- use payloadBytes instead
}
```

**Timing**: This fix should be part of Phase 3 (publisher), since that phase
already modifies the Sample class (adds `encoding` field) and the subscriber
callback (adds 5th element). CP must include this as an explicit slice in the
Phase 3 plan.

## 8. CI Pipeline Roadmap

### Stage 1 (current): Tier 1 only
- Only `fvm dart test` in CI
- No external processes required
- All 80+ tests run

### Stage 2 (after zenohd build validated): Add Tier 2
1. Cache `extern/zenoh/target/release/zenohd` (large Rust build)
2. Start zenohd as a CI service
3. Run `fvm dart test --tags router`
4. Requires: zenohd binary in CI artifacts

### Stage 3 (after C++ app and payloadBytes): Add Tier 3
1. Cache C++ counter app binary
2. Start zenohd + C++ app as CI services
3. Run `fvm dart test --tags e2e`
4. Requires: C++ app binary in CI artifacts

### Stage 4 (after Flutter app): Add Tier 4
- Flutter widget tests (mocked repository, no network)
- Flutter integration tests on Android emulator (real network)
- Requires: Android emulator in CI

## 9. Implementation Order

1. **Phase 3 (publisher)** — Includes `payloadBytes` fix on Sample.
   After this, Tier 2 tests can be written for pub/sub through router.

2. **Write Tier 2 tests + script** — `test-with-router.sh` +
   `test/router_test.dart`. Validates `package:zenoh` works through
   zenohd. This is the first proof that the package works beyond
   in-process peer mode.

3. **Copy C++ counter app** — Move from xplr to `apps/cpp_counter/`.
   Adapt CMakeLists.txt paths for new repo structure.

4. **Write Tier 3 tests + script** — `test-e2e.sh` +
   `test/e2e_counter_test.dart`. Validates the full counter protocol.

5. **Phase 5 (scout/info)** — Extends Tier 2 tests with ZenohId,
   routersZid, scout.

Each step is independently valuable and testable.
