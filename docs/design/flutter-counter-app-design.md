# Flutter Counter App Design

> **Purpose**: Define how to build the new Flutter counter app using
> `package:zenoh` from the zenoh_dart monorepo.
>
> **Audience**: CI (implementer), CA (architect review).
>
> **Companion docs**:
> - `docs/design/xplr-counter-migration-analysis.md` — xplr analysis
> - `docs/design/dart-client-integration-testing.md` — testing framework
>
> **Prerequisites**: Phase 3 (publisher + payloadBytes fix) must be complete
> before the Flutter app can receive binary counter data.

## 1. Overview

The new Flutter counter app replaces the xplr's Flutter app. It uses the
`zenoh` package (from zenoh_dart monorepo) instead of the xplr's
`dart_zenoh` package.

**What changes**: ZenohService layer completely rewritten. Repository
implementation adapted. Build dependencies change.

**What stays**: Domain entities (CounterAppState, ControlCommand,
CounterStateMessage, CounterValue), repository interface, UI/ViewModel
layer, settings/endpoint management.

## 2. Architecture

```
+-----------------------------------------------------+
|  UI Layer (keep from xplr)                          |
|  CounterPage -> CounterViewModel (Riverpod Notifier)|
|  SettingsPage -> SettingsViewModel                  |
+----------------------+------------------------------+
                       |
+----------------------+------------------------------+
|  Domain Layer (keep from xplr)                      |
|  CounterRepository (abstract)                       |
|  CounterValue, CounterAppState, ControlCommand      |
|  CounterStateMessage                                |
+----------------------+------------------------------+
                       |
+----------------------+------------------------------+
|  Data Layer (REWRITE)                               |
|  ZenohService -> uses package:zenoh Session/Sub     |
|  CounterRepositoryImpl -> uses new ZenohService     |
+-----------------------------------------------------+
```

## 3. New ZenohService (Complete Rewrite)

The xplr's ZenohService wraps a global-state `Zenoh` class with blocking
`recv()` in helper isolates. The new service uses zenoh_dart's
multi-instance `Session`/`Subscriber` pattern.

```dart
import 'dart:async';
import 'dart:typed_data';

import 'package:zenoh/zenoh.dart';

class ZenohService {
  Session? _session;
  final List<Subscriber> _subscribers = [];

  bool get isInitialized => _session != null;

  /// Open a zenoh session.
  ///
  /// [endpoint] -- router endpoint (e.g., "tcp/192.168.1.1:7447").
  /// If null, opens in peer mode (not recommended for Android).
  Future<void> connect({String? endpoint}) async {
    if (_session != null) return;

    Zenoh.initLog('error');

    final config = Config();
    if (endpoint != null) {
      config.insertJson5('mode', '"client"');
      config.insertJson5(
        'connect/endpoints', '["$endpoint"]');
    }

    _session = Session.open(config: config);
  }

  /// Subscribe to a key expression, receiving raw bytes.
  ///
  /// Returns a Stream of Sample. Caller decodes payload as needed.
  Stream<Sample> subscribe(String keyExpr) {
    final session = _session;
    if (session == null) throw StateError('Not connected');

    final subscriber = session.declareSubscriber(keyExpr);
    _subscribers.add(subscriber);
    return subscriber.stream;
  }

  /// Publish a string value on a key expression.
  void put(String keyExpr, String value) {
    final session = _session;
    if (session == null) throw StateError('Not connected');
    session.put(keyExpr, value);
  }

  /// Disconnect and release all resources.
  void dispose() {
    for (final sub in _subscribers) {
      sub.close();
    }
    _subscribers.clear();
    _session?.close();
    _session = null;
  }
}
```

**Key differences from xplr's ZenohService**:
- No helper isolates -- subscriber uses NativePort (non-blocking)
- No separate `subscribe()` / `subscribeString()` -- one `subscribe()`
  returns `Stream<Sample>` with both `payload` (String) and `payloadBytes`
  (Uint8List)
- No `isConnected` polling for router -- connection verification deferred
  to Phase 5 (`session.routersZid()`)
- No `initWithTimeout()` blocking pattern -- session opens immediately,
  router connectivity checked separately

## 4. New CounterRepositoryImpl

```dart
class CounterRepositoryImpl implements CounterRepository {
  CounterRepositoryImpl(this._zenohService);

  final ZenohService _zenohService;
  final _counterController = StreamController<CounterValue>.broadcast();
  final _stateController = StreamController<CounterStateMessage>.broadcast();
  StreamSubscription<Sample>? _counterSub;
  StreamSubscription<Sample>? _stateSub;

  @override
  Stream<CounterValue> get counterStream => _counterController.stream;

  @override
  Stream<CounterStateMessage> get stateStream => _stateController.stream;

  @override
  bool get isConnected => _zenohService.isInitialized;

  @override
  Future<void> connect({String? endpoint}) async {
    await _zenohService.connect(endpoint: endpoint);

    // Subscribe to binary counter values
    _counterSub = _zenohService.subscribe('demo/counter').listen((sample) {
      if (sample.payloadBytes.length == 8) {
        final value = sample.payloadBytes.buffer
            .asByteData()
            .getInt64(0, Endian.little);
        _counterController.add(CounterValue(
          value: value,
          timestamp: DateTime.now(),
        ));
      }
    });

    // Subscribe to JSON state messages
    _stateSub = _zenohService
        .subscribe('demo/control/state')
        .listen((sample) {
      try {
        _stateController.add(
          CounterStateMessage.fromJson(sample.payload));
      } catch (_) {
        // Ignore malformed state messages
      }
    });
  }

  @override
  Future<void> disconnect() async {
    await _counterSub?.cancel();
    await _stateSub?.cancel();
    _counterSub = null;
    _stateSub = null;
    _zenohService.dispose();
  }

  @override
  Future<void> sendCommand(ControlCommand command) async {
    if (!isConnected) return;
    _zenohService.put('demo/control/command', command.toJson());
  }

  void dispose() {
    _counterSub?.cancel();
    _stateSub?.cancel();
    _counterController.close();
    _stateController.close();
  }
}
```

**Key difference**: Counter subscription decodes `payloadBytes` as
little-endian int64 instead of relying on the xplr's separate
`subscribe()` -> `Stream<int>` FFI path.

## 5. What to Keep from xplr (Copy Directly)

These files can be copied with minimal or no changes:

| File | Changes Needed |
|------|----------------|
| `domain/entities/app_state.dart` | None -- pure Dart enums + JSON parsing |
| `domain/entities/counter_value.dart` | None -- pure data class |
| `domain/entities/endpoint_option.dart` | None -- TCP validation |
| `domain/repositories/counter_repository.dart` | Remove `isConnectedToRouter` (defer to Phase 5) |
| `ui/counter/counter_viewmodel.dart` | Minimal -- adjust for removed `isConnectedToRouter` |
| `ui/counter/counter_page.dart` | None -- pure Flutter widgets |
| `ui/settings/` | None -- pure Flutter settings UI |

## 6. What NOT to Carry Over

| xplr Component | Reason |
|----------------|--------|
| `dart_zenoh` package | Replaced by `package:zenoh` |
| `zenoh_wrapper.c` / `zenoh_wrapper.h` | Global state, separate int/string APIs |
| `ZenohService.initWithTimeout()` | Blocking poll pattern; replace with Phase 5 routersZid |
| `isConnected` (router detection) | Defer to Phase 5 `session.routersZid().isNotEmpty` |
| Helper isolate pattern | NativePort eliminates the need |
| Separate `subscribe()` / `subscribeString()` | One `subscribe()` with `payloadBytes` |

## 7. Phased Feature Availability

| Feature | Requires | Available When |
|---------|----------|---------------|
| Connect, subscribe, send commands | Phases 0-2 | Now |
| Publisher (declared) | Phase 3 | Next |
| Binary payloadBytes on Sample | Phase 3 (Sample update) | Next |
| Router connection verification | Phase 5 (session.routersZid) | Later |
| Network discovery (scout) | Phase 5 (Zenoh.scout) | Later |
| SHM zero-copy publish | Phase 4 | Later |

**MVP** (minimum to run the counter demo):
1. Phase 3 complete (publisher + payloadBytes fix)
2. ZenohService rewrite
3. CounterRepositoryImpl adaptation
4. Copy domain + UI layers

Router connection verification and network discovery are nice-to-have but
not required for the MVP -- the user manually enters the endpoint.

## 8. Project Structure

```
zenoh-dart/
  apps/
    flutter_counter/              # NEW Flutter app
      lib/
        data/
          services/
            zenoh_service.dart    # REWRITE using package:zenoh
          repositories/
            counter_repository_impl.dart  # ADAPT for Sample.payloadBytes
        domain/
          entities/               # COPY from xplr
            app_state.dart
            counter_value.dart
            endpoint_option.dart
          repositories/
            counter_repository.dart  # COPY (minor trim)
        ui/                       # COPY from xplr
          counter/
          settings/
      pubspec.yaml
        dependencies:
          zenoh: { path: ../../package }
          flutter_riverpod: ...
    cpp_counter/                  # COPY from xplr apps/cpp_app
      CMakeLists.txt
      src/main.cpp
      include/state_machine.h
      include/connection.h
  scripts/
    start-zenoh.sh               # ADAPT from xplr (update paths)
```

## 9. C++ Counter App

The C++ counter app (`apps/cpp_app` in xplr) is kept as-is for the MVP.
It uses zenoh-cpp (which wraps the same zenoh-c v1.7.2) and implements:

- State machine: stopped -> playing -> paused -> stopped
- Publishes raw int64 counter on `demo/counter` (when playing)
- Publishes JSON state on `demo/control/state`
- Subscribes to JSON commands on `demo/control/command`

**Build**: Requires zenoh-cpp headers from `extern/zenoh-cpp`.

The `start-zenoh.sh` script from xplr handles launching zenohd + C++ app
together. It needs path updates to reference `extern/zenoh/target/release/zenohd`
(new submodule location) and `apps/cpp_counter/build/zenoh_cpp_app`.

## 10. Android Deployment Topology

```
+-------------------------+
| Desktop/Server          |
| +---------+ +---------+ |
| | zenohd  | | C++ app | |
| | :7447   | | (client)| |
| +----+----+ +----+----+ |
|      | tcp       | tcp  |
|      +-----+-----+      |
|            |             |
+------------+-------------+
             | tcp (WiFi)
+------------+-------------+
| Android    |             |
| +----------+-----------+ |
| | Flutter counter app  | |
| | (zenoh client mode)  | |
| +----------------------+ |
+--------------------------+
```

Android has no reliable UDP multicast support. The Flutter app **must**
connect to zenohd in client mode via an explicit TCP endpoint. The user
enters the endpoint in the settings screen (persisted).

## 11. Flutter Testing Strategy

### Widget Tests (mocked, no network)
- Mock `CounterRepository` interface
- Test ViewModel state transitions (connecting, connected, error)
- Test UI renders counter value, state changes, button states
- No zenoh dependency needed

### Integration Tests (real network)
- Requires zenohd + C++ counter running on host
- Flutter integration_test package on Android emulator
- Connect to host via `tcp/10.0.2.2:7447` (emulator host loopback)
- Verify full play/pause/stop/reset cycle

See `docs/design/dart-client-integration-testing.md` for the testing
framework that supports these integration tests.

## 12. Implementation Steps

1. **Create `apps/flutter_counter/`** -- `fvm flutter create` with
   Riverpod, path dependency on `package:zenoh`

2. **Copy domain layer** -- entities + repository interface from xplr

3. **Write ZenohService** -- new implementation per Section 3

4. **Write CounterRepositoryImpl** -- adapted per Section 4

5. **Copy UI layer** -- counter page, settings page, viewmodels from xplr

6. **Copy C++ counter app** -- move to `apps/cpp_counter/`, adapt paths

7. **Adapt `start-zenoh.sh`** -- update paths for new repo structure

8. **Test on desktop** -- `start-zenoh.sh` + `fvm flutter run`

9. **Test on Android** -- deploy to device, connect to desktop zenohd
