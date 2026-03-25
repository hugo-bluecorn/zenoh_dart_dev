# Flutter Counter Subscriber — Design Specification

> **Version**: 1.0
> **Date**: 2026-03-12
> **Author**: CA (Architect)
> **Repo**: `zenoh-counter-flutter` (separate repo)
> **Audience**: CI (implementer), CP (planner), CA (review)

## 1. Purpose

A pure Flutter subscriber app that receives real-time counter values from
the `zenoh-counter-cpp` SHM publisher and displays them in a clean UI.
This is the third and final project in the counter template trilogy:

1. **zenoh-counter-dart** (COMPLETE) — Pure Dart CLI subscriber
2. **zenoh-counter-cpp** (COMPLETE) — C++ SHM publisher
3. **zenoh-counter-flutter** (this project) — Flutter subscriber UI

**This is a reference architecture**, not just a counter app. It proves:

- `package:zenoh` works in Flutter (desktop + Android)
- Dart build hooks fire transitively in Flutter's build pipeline
- MVVM layering with zenoh as a real-time data source
- Android deployment with cross-compiled native libraries
- Cross-device interop (desktop C++ pub → Android Flutter sub via zenohd)

## 2. Counter Protocol

Defined by `zenoh-counter-cpp`. The Flutter app is a pure consumer.

| Property | Value |
|----------|-------|
| Key expression | `demo/counter` (default, configurable) |
| Payload format | Raw int64, little-endian (8 bytes) |
| Publish interval | 1000ms (C++ side) |
| Transport | SHM zero-copy (transparent to subscribers) |
| Control plane | None — simple increment-and-publish |

**Decoding in Dart:**
```dart
final bytes = sample.payloadBytes; // Uint8List, 8 bytes
final value = bytes.buffer.asByteData().getInt64(0, Endian.little);
```

## 3. Network Topology

### Desktop (Linux) — Peer Mode

```
┌─────────────────────────────────┐
│ Linux Host                      │
│ ┌─────────────┐ ┌────────────┐ │
│ │ C++ SHM Pub │ │ Flutter    │ │
│ │ -l tcp://    │ │ Subscriber │ │
│ │  0.0.0.0:   │ │ -e tcp://  │ │
│ │  7447       │ │  localhost: │ │
│ │             │ │  7447      │ │
│ └──────┬──────┘ └─────┬──────┘ │
│        └──────┬───────┘        │
│           TCP direct           │
└─────────────────────────────────┘
```

No router needed. C++ pub listens, Flutter sub connects.

### Android — Router Mode

```
┌─────────────────────────────────┐
│ Linux Host                      │
│ ┌────────┐ ┌─────────────────┐ │
│ │ zenohd │ │ C++ SHM Pub     │ │
│ │ :7447  │ │ -e tcp://       │ │
│ │        │ │  localhost:7447  │ │
│ └───┬────┘ └───────┬─────────┘ │
│     └──────┬───────┘           │
│            │ TCP               │
└────────────┼───────────────────┘
             │ WiFi (TCP)
┌────────────┼───────────────────┐
│ Android    │                   │
│ ┌──────────┴────────────────┐  │
│ │ Flutter Subscriber        │  │
│ │ -e tcp://<host-ip>:7447   │  │
│ │ (client mode)             │  │
│ └───────────────────────────┘  │
└────────────────────────────────┘
```

Android has no reliable UDP multicast. The Flutter app **must** connect
to zenohd in client mode via an explicit TCP endpoint. The user enters
the endpoint in the settings screen (persisted across sessions).

## 4. Architecture — MVVM with Riverpod 3.x

### Layer Diagram

```
┌──────────────────────────────────────────────┐
│  UI Layer (organized by feature)             │
│  ConnectionScreen ← ConnectionViewModel      │
│  CounterScreen    ← CounterViewModel         │
│  SettingsScreen   ← SettingsViewModel        │
├──────────────────────────────────────────────┤
│  ViewModel Layer (Riverpod 3.x Notifiers)    │
│  connectionViewModelProvider                 │
│  counterViewModelProvider                    │
│  settingsViewModelProvider                   │
├──────────────────────────────────────────────┤
│  Data Layer (organized by type)              │
│  CounterRepository (abstract → impl)         │
│  SettingsRepository (abstract → impl)        │
│  ZenohService (wraps package:zenoh)          │
├──────────────────────────────────────────────┤
│  package:zenoh (external dependency)         │
│  Session, Subscriber, Sample, Config, etc.   │
└──────────────────────────────────────────────┘
```

**Key rule:** Only `ZenohService` imports `package:zenoh`. ViewModels
never touch FFI types. The UI receives plain Dart types (`int`, `String`,
`DateTime`, enums).

### Directory Structure

```
lib/
├── main.dart                          # ProviderScope + runApp
├── app.dart                           # MaterialApp.router + theme
├── ui/
│   ├── core/
│   │   ├── themes/
│   │   │   └── app_theme.dart         # App-wide theme
│   │   └── widgets/
│   │       └── status_indicator.dart   # Reusable connection dot
│   ├── connection/
│   │   ├── connection_screen.dart     # Endpoint entry + connect
│   │   └── connection_viewmodel.dart  # Connection lifecycle
│   ├── counter/
│   │   ├── counter_screen.dart        # Real-time counter display
│   │   └── counter_viewmodel.dart     # Subscription + decode
│   └── settings/
│       ├── settings_screen.dart       # Endpoint config (persisted)
│       └── settings_viewmodel.dart    # SharedPreferences access
├── data/
│   ├── repositories/
│   │   ├── counter_repository.dart         # Abstract interface
│   │   ├── counter_repository_impl.dart    # ZenohService consumer
│   │   ├── settings_repository.dart        # Abstract interface
│   │   └── settings_repository_impl.dart   # SharedPreferences
│   ├── services/
│   │   └── zenoh_service.dart              # THE zenoh boundary
│   └── models/
│       ├── connection_config.dart          # Endpoints + key expr
│       └── counter_value.dart              # Value + timestamp
├── providers/
│   └── providers.dart                      # All Riverpod providers
└── routing/
    └── app_router.dart                     # go_router config

test/
├── ui/
│   ├── counter/
│   │   └── counter_screen_test.dart        # Widget test
│   └── connection/
│       └── connection_screen_test.dart      # Widget test
├── data/
│   ├── services/
│   │   └── zenoh_service_test.dart         # Integration test
│   └── repositories/
│       └── counter_repository_test.dart    # Integration test
└── helpers/
    └── test_data.dart                      # Shared fixtures

integration_test/
└── counter_flow_test.dart                  # Full E2E flow
```

## 5. Data Layer

### 5.1 ZenohService

The sole boundary to `package:zenoh`. No other file imports zenoh types.

```dart
import 'dart:async';
import 'dart:typed_data';
import 'package:zenoh/zenoh.dart';

class ZenohService {
  Session? _session;
  Subscriber? _subscriber;

  bool get isConnected => _session != null;

  /// Open a zenoh session.
  ///
  /// [connectEndpoints] — TCP endpoints to connect to (client mode).
  /// [listenEndpoints] — TCP endpoints to listen on (peer mode).
  /// If both are empty, opens in default peer mode.
  void connect({
    List<String> connectEndpoints = const [],
    List<String> listenEndpoints = const [],
  }) {
    if (_session != null) return;

    Zenoh.initLog('error');
    final config = Config();

    if (connectEndpoints.isNotEmpty) {
      config.insertJson5('mode', '"client"');
      final json = connectEndpoints.map((e) => '"$e"').join(', ');
      config.insertJson5('connect/endpoints', '[$json]');
    }
    if (listenEndpoints.isNotEmpty) {
      final json = listenEndpoints.map((e) => '"$e"').join(', ');
      config.insertJson5('listen/endpoints', '[$json]');
    }

    _session = Session.open(config: config);
  }

  /// Subscribe to a key expression.
  /// Returns a Stream<Sample> — caller decodes payload.
  Stream<Sample> subscribe(String keyExpr) {
    final session = _session;
    if (session == null) throw StateError('Not connected');

    _subscriber?.close();
    _subscriber = session.declareSubscriber(keyExpr);
    return _subscriber!.stream;
  }

  /// Disconnect and release all resources.
  void dispose() {
    _subscriber?.close();
    _subscriber = null;
    _session?.close();
    _session = null;
  }
}
```

### 5.2 Models

```dart
// data/models/counter_value.dart
class CounterValue {
  const CounterValue({required this.value, required this.timestamp});
  final int value;
  final DateTime timestamp;
}

// data/models/connection_config.dart
class ConnectionConfig {
  const ConnectionConfig({
    this.connectEndpoint = '',
    this.listenEndpoint = '',
    this.keyExpr = 'demo/counter',
  });

  final String connectEndpoint;
  final String listenEndpoint;
  final String keyExpr;

  ConnectionConfig copyWith({
    String? connectEndpoint,
    String? listenEndpoint,
    String? keyExpr,
  }) {
    return ConnectionConfig(
      connectEndpoint: connectEndpoint ?? this.connectEndpoint,
      listenEndpoint: listenEndpoint ?? this.listenEndpoint,
      keyExpr: keyExpr ?? this.keyExpr,
    );
  }
}
```

### 5.3 CounterRepository

```dart
// data/repositories/counter_repository.dart (abstract)
abstract class CounterRepository {
  bool get isConnected;
  Stream<CounterValue> get counterStream;
  void connect(ConnectionConfig config);
  void disconnect();
  void dispose();
}

// data/repositories/counter_repository_impl.dart
class CounterRepositoryImpl implements CounterRepository {
  CounterRepositoryImpl(this._zenohService);

  final ZenohService _zenohService;
  final _controller = StreamController<CounterValue>.broadcast();
  StreamSubscription<Sample>? _subscription;

  @override
  bool get isConnected => _zenohService.isConnected;

  @override
  Stream<CounterValue> get counterStream => _controller.stream;

  @override
  void connect(ConnectionConfig config) {
    _zenohService.connect(
      connectEndpoints: config.connectEndpoint.isNotEmpty
          ? [config.connectEndpoint]
          : [],
      listenEndpoints: config.listenEndpoint.isNotEmpty
          ? [config.listenEndpoint]
          : [],
    );

    _subscription = _zenohService.subscribe(config.keyExpr).listen(
      (sample) {
        final bytes = sample.payloadBytes;
        if (bytes.length == 8) {
          final value = bytes.buffer.asByteData().getInt64(0, Endian.little);
          _controller.add(CounterValue(
            value: value,
            timestamp: DateTime.now(),
          ));
        }
      },
    );
  }

  @override
  void disconnect() {
    _subscription?.cancel();
    _subscription = null;
    _zenohService.dispose();
  }

  @override
  void dispose() {
    disconnect();
    _controller.close();
  }
}
```

### 5.4 SettingsRepository

```dart
// data/repositories/settings_repository.dart (abstract)
abstract class SettingsRepository {
  Future<ConnectionConfig> load();
  Future<void> save(ConnectionConfig config);
}

// data/repositories/settings_repository_impl.dart
class SettingsRepositoryImpl implements SettingsRepository {
  SettingsRepositoryImpl(this._prefs);
  final SharedPreferences _prefs;

  static const _connectKey = 'connect_endpoint';
  static const _listenKey = 'listen_endpoint';
  static const _keyExprKey = 'key_expr';

  @override
  Future<ConnectionConfig> load() async {
    return ConnectionConfig(
      connectEndpoint: _prefs.getString(_connectKey) ?? '',
      listenEndpoint: _prefs.getString(_listenKey) ?? '',
      keyExpr: _prefs.getString(_keyExprKey) ?? 'demo/counter',
    );
  }

  @override
  Future<void> save(ConnectionConfig config) async {
    await _prefs.setString(_connectKey, config.connectEndpoint);
    await _prefs.setString(_listenKey, config.listenEndpoint);
    await _prefs.setString(_keyExprKey, config.keyExpr);
  }
}
```

## 6. ViewModel Layer — Riverpod 3.x

**Riverpod 3.x, no codegen.** Manual `NotifierProvider` definitions.
No `riverpod_annotation`, no `riverpod_generator`, no `build_runner`.

### 6.1 Provider Definitions

```dart
// providers/providers.dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

// --- Infrastructure ---

final sharedPreferencesProvider = Provider<SharedPreferences>((ref) {
  throw UnimplementedError('Override in main()');
});

final zenohServiceProvider = Provider<ZenohService>((ref) {
  final service = ZenohService();
  ref.onDispose(service.dispose);
  return service;
});

// --- Repositories ---

final settingsRepositoryProvider = Provider<SettingsRepository>((ref) {
  final prefs = ref.watch(sharedPreferencesProvider);
  return SettingsRepositoryImpl(prefs);
});

final counterRepositoryProvider = Provider<CounterRepository>((ref) {
  final service = ref.watch(zenohServiceProvider);
  final repo = CounterRepositoryImpl(service);
  ref.onDispose(repo.dispose);
  return repo;
});

// --- ViewModels ---

final connectionViewModelProvider =
    NotifierProvider<ConnectionViewModel, ConnectionState>(
  ConnectionViewModel.new,
);

final counterViewModelProvider =
    NotifierProvider<CounterViewModel, CounterState>(
  CounterViewModel.new,
);

final settingsViewModelProvider =
    AsyncNotifierProvider<SettingsViewModel, ConnectionConfig>(
  SettingsViewModel.new,
);
```

### 6.2 ConnectionViewModel

```dart
enum ConnectionStatus { disconnected, connecting, connected, error }

class ConnectionState {
  const ConnectionState({
    this.status = ConnectionStatus.disconnected,
    this.error,
  });

  final ConnectionStatus status;
  final String? error;

  ConnectionState copyWith({ConnectionStatus? status, String? error}) {
    return ConnectionState(
      status: status ?? this.status,
      error: error,
    );
  }
}

class ConnectionViewModel extends Notifier<ConnectionState> {
  @override
  ConnectionState build() => const ConnectionState();

  void connect(ConnectionConfig config) {
    state = state.copyWith(
      status: ConnectionStatus.connecting,
      error: null,
    );
    try {
      ref.read(counterRepositoryProvider).connect(config);
      state = state.copyWith(status: ConnectionStatus.connected);
    } catch (e) {
      state = state.copyWith(
        status: ConnectionStatus.error,
        error: e.toString(),
      );
    }
  }

  void disconnect() {
    ref.read(counterRepositoryProvider).disconnect();
    state = const ConnectionState();
  }
}
```

### 6.3 CounterViewModel

```dart
class CounterState {
  const CounterState({this.value, this.lastUpdate, this.isSubscribed = false});

  final int? value;
  final DateTime? lastUpdate;
  final bool isSubscribed;

  CounterState copyWith({int? value, DateTime? lastUpdate, bool? isSubscribed}) {
    return CounterState(
      value: value ?? this.value,
      lastUpdate: lastUpdate ?? this.lastUpdate,
      isSubscribed: isSubscribed ?? this.isSubscribed,
    );
  }
}

class CounterViewModel extends Notifier<CounterState> {
  StreamSubscription<CounterValue>? _subscription;

  @override
  CounterState build() {
    ref.onDispose(() => _subscription?.cancel());
    return const CounterState();
  }

  void startListening() {
    _subscription?.cancel();
    _subscription = ref
        .read(counterRepositoryProvider)
        .counterStream
        .listen((counterValue) {
      state = state.copyWith(
        value: counterValue.value,
        lastUpdate: counterValue.timestamp,
        isSubscribed: true,
      );
    });
    state = state.copyWith(isSubscribed: true);
  }

  void stopListening() {
    _subscription?.cancel();
    _subscription = null;
    state = const CounterState();
  }
}
```

### 6.4 SettingsViewModel

```dart
class SettingsViewModel extends AsyncNotifier<ConnectionConfig> {
  @override
  FutureOr<ConnectionConfig> build() async {
    return await ref.read(settingsRepositoryProvider).load();
  }

  Future<void> save(ConnectionConfig config) async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(() async {
      await ref.read(settingsRepositoryProvider).save(config);
      return config;
    });
  }
}
```

## 7. UI Layer

### 7.1 Screen Flow

```
App Launch
    │
    ▼
ConnectionScreen
    │ (connect button)
    ▼
CounterScreen ──── (gear icon) ──── SettingsScreen
    │ (disconnect)                      │ (back)
    ▼                                   ▼
ConnectionScreen                   CounterScreen
```

### 7.2 Navigation — go_router

```dart
// routing/app_router.dart
final routerProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    initialLocation: '/connect',
    routes: [
      GoRoute(
        path: '/connect',
        builder: (context, state) => const ConnectionScreen(),
      ),
      GoRoute(
        path: '/counter',
        builder: (context, state) => const CounterScreen(),
      ),
      GoRoute(
        path: '/settings',
        builder: (context, state) => const SettingsScreen(),
      ),
    ],
  );
});
```

### 7.3 ConnectionScreen

- Text fields for connect endpoint and listen endpoint
- Key expression field (defaults to `demo/counter`)
- "Load saved" button (populates from SharedPreferences)
- "Connect" button (calls ConnectionViewModel.connect)
- Connection status indicator
- Error message display
- On successful connect → navigate to `/counter`

### 7.4 CounterScreen

- Large centered counter value (animated text transitions)
- "Last update" timestamp below the counter
- Connection status indicator in app bar
- Gear icon → navigate to `/settings`
- Disconnect button → navigate to `/connect`
- Auto-starts subscription on screen entry via CounterViewModel

### 7.5 SettingsScreen

- Same endpoint fields as ConnectionScreen
- "Save" button (persists to SharedPreferences)
- "Reset to defaults" button
- Back navigation to CounterScreen

## 8. Dependencies

```yaml
# pubspec.yaml
name: zenoh_counter_flutter
description: >
  Flutter subscriber for the zenoh counter protocol.
  Receives real-time counter values from zenoh-counter-cpp's SHM publisher.
publish_to: 'none'
version: 0.1.0+1

environment:
  sdk: ^3.11.1

dependencies:
  flutter:
    sdk: flutter
  flutter_riverpod: ^3.3.1
  go_router: ^17.1.0
  shared_preferences: ^2.5.4
  zenoh:
    path: ../zenoh_dart/package

dev_dependencies:
  flutter_test:
    sdk: flutter
  integration_test:
    sdk: flutter
  very_good_analysis: ^10.2.0
```

### Linting

Replace `flutter_lints` with `very_good_analysis`:

```yaml
# analysis_options.yaml
include: package:very_good_analysis/analysis_options.yaml

analyzer:
  exclude:
    - '**/*.g.dart'

linter:
  rules:
    public_member_api_docs: false
```

## 9. Native Library Strategy

### The Unknown: Flutter + Build Hooks + DynamicLibrary.open()

The `package:zenoh` uses:
- **Build hooks** (`hook/build.dart`) to register `CodeAsset` entries for
  `libzenoh_dart.so` and `libzenohc.so`
- **`DynamicLibrary.open()`** for runtime loading with path resolution via
  `Isolate.resolvePackageUriSync()`

This was validated for pure Dart consumers (PR #17). **Flutter's build
pipeline is untested.** Potential issues:

1. Flutter may not invoke Dart build hooks during its build
2. `Isolate.resolvePackageUriSync()` may resolve differently in a Flutter
   app vs standalone Dart
3. Flutter bundles native libs differently per platform (Linux: `lib/`,
   Android: `jniLibs/`)

**Mitigation strategy:** Try it. If hooks work, great. If not, we have
fallback options:
- Manual native lib placement in Flutter's platform directories
- Flutter plugin wrapper (deferred — adds complexity)
- `LD_LIBRARY_PATH` for desktop dev (last resort, not for production)

### Linux Desktop

Expected: build hooks bundle `.so` files into the app's `lib/` directory.
RPATH is `$ORIGIN` (set at CMake compile time via `package/`'s
build system).

If hooks don't work: copy `libzenoh_dart.so` and `libzenohc.so` into
`linux/` build output manually.

### Android

Required artifacts per ABI:
- `libzenoh_dart.so` — C shim (must be cross-compiled)
- `libzenohc.so` — zenoh-c (must be cross-compiled via cargo-ndk)

**Cross-compilation:**
```bash
# From zenoh_dart repo
./scripts/build_zenoh_android.sh --abi arm64-v8a
```

Placement: `android/app/src/main/jniLibs/arm64-v8a/`

The C shim (`libzenoh_dart.so`) also needs cross-compilation for Android.
This is a gap in the current build scripts — `src/CMakeLists.txt` handles
it via NDK toolchain, but the script is desktop-only. This gap will be
closed during implementation.

## 10. Testing Strategy

### Principles

- **No mocks for ZenohService.** Real zenoh, real network. Mocks miss
  network nuances — this is consistent with zenoh-dart's testing philosophy.
- **Provider overrides for widget tests.** Override repository providers
  with fixed state — this isn't mocking zenoh, it's controlling UI state.
- **Integration tests with real C++ publisher.** The acceptance criteria
  require receiving from `zenoh-counter-cpp`.

### Widget Tests

Test UI rendering given known states. Use Riverpod `ProviderScope.overrides`
to inject fixed states — no network, no zenoh.

```dart
testWidgets('counter screen shows value', (tester) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        counterViewModelProvider.overrideWith(() => FakeCounterViewModel()),
      ],
      child: const MaterialApp(home: CounterScreen()),
    ),
  );
  expect(find.text('42'), findsOneWidget);
});
```

### Integration Tests

Require the C++ publisher and optionally zenohd running on the host.

```dart
// integration_test/counter_flow_test.dart
testWidgets('receives counter from C++ publisher', (tester) async {
  // Assumes: counter_pub running on localhost:7447
  // ...connect, wait for samples, verify incrementing values
});
```

### Test Matrix

| Test Type | Needs zenoh? | Needs C++ pub? | Location |
|-----------|-------------|----------------|----------|
| Widget (UI rendering) | No | No | `test/ui/` |
| Widget (ViewModel state) | No | No | `test/ui/` |
| Service integration | Yes | No | `test/data/services/` |
| Repository integration | Yes | Yes | `test/data/repositories/` |
| E2E flow | Yes | Yes | `integration_test/` |

## 11. Local Development

### Run Script

A `scripts/dev.sh` script for local development:

```bash
#!/bin/bash
# Start the C++ counter publisher for local Flutter development.
#
# Usage:
#   ./scripts/dev.sh                          # peer mode (desktop)
#   ./scripts/dev.sh --router                 # start zenohd + client mode
#   ./scripts/dev.sh --router --ip 192.168.x  # router on specific IP

ZENOH_COUNTER_CPP="${ZENOH_COUNTER_CPP:-../zenoh-counter-cpp}"
ZENOH_DART="${ZENOH_DART:-../zenoh_dart}"

case "$1" in
  --router)
    echo "Starting zenohd router..."
    "${ZENOH_DART}/extern/zenoh/target/release/zenohd" &
    ROUTER_PID=$!
    sleep 1
    echo "Starting C++ counter publisher (client mode)..."
    "${ZENOH_COUNTER_CPP}/build/counter_pub" -e tcp/localhost:7447
    kill $ROUTER_PID 2>/dev/null
    ;;
  *)
    echo "Starting C++ counter publisher (peer mode, listen)..."
    "${ZENOH_COUNTER_CPP}/build/counter_pub" -l tcp/0.0.0.0:7447
    ;;
esac
```

### Developer Workflow

**Desktop:**
```bash
# Terminal 1: Start C++ publisher
./scripts/dev.sh

# Terminal 2: Run Flutter app
fvm flutter run -d linux
# Enter endpoint: tcp/localhost:7447
```

**Android (via router):**
```bash
# Terminal 1: Start router + publisher
./scripts/dev.sh --router

# Terminal 2: Run Flutter app on device
fvm flutter run -d <device-id>
# Enter endpoint: tcp://<host-ip>:7447
```

## 12. Acceptance Criteria

1. **Desktop Linux**: Flutter app connects to C++ SHM publisher via TCP,
   displays incrementing counter in real-time
2. **Android**: Flutter app connects via zenohd router, receives and
   displays counter values
3. **Settings persistence**: Endpoint config survives app restart
4. **MVVM layering**: Only `ZenohService` imports `package:zenoh`
5. **No mocks in test suite**: All zenoh tests use real sessions
6. **Widget tests pass without zenoh**: UI tests use provider overrides
7. **Clean analysis**: `fvm flutter analyze` reports zero issues with
   `very_good_analysis`
8. **Interop verified**: C++ SHM publisher → Flutter subscriber works
   on both desktop and Android

## 13. Risk Register

| Risk | Impact | Likelihood | Mitigation |
|------|--------|------------|------------|
| Flutter build hooks don't fire | High | Medium | Manual native lib placement fallback |
| `Isolate.resolvePackageUriSync()` fails in Flutter | High | Medium | Platform-specific path resolution |
| Android cross-compilation gaps | Medium | High | Extend existing build scripts |
| `DynamicLibrary.open()` path differs on Android | High | Medium | Android-specific path in `native_lib.dart` |
| Riverpod 3.x breaking changes (4.0 announced) | Low | Low | Pin to ^3.3.1, upgrade later |

## 14. Out of Scope

- Publisher functionality in the Flutter app (C++ handles publishing)
- SHM API on the receive side (transparent to standard subscribers)
- iOS/macOS/Windows/Web support (desktop Linux + Android only)
- Control commands (play/pause/stop) — the C++ pub has no control plane
- Animations beyond basic text transitions
- Theming beyond Material 3 defaults
- Offline mode / local storage of counter history

## 15. Package Versions (as of 2026-03-12)

| Package | Version | Purpose |
|---------|---------|---------|
| flutter_riverpod | ^3.3.1 | State management (no codegen) |
| go_router | ^17.1.0 | Declarative navigation |
| shared_preferences | ^2.5.4 | Settings persistence |
| very_good_analysis | ^10.2.0 | Linting (dev dependency) |
| zenoh | path dep | Zenoh FFI bindings |
| integration_test | SDK | E2E tests |
