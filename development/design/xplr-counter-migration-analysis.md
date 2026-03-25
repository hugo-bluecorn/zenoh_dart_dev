# dart_zenoh_xplr → zenoh_dart Counter Migration Analysis

> **Purpose**: Devil's advocate review of the exploration project at
> `/home/hugo-bluecorn/bluecorn/CSR/git/dart_zenoh_xplr`. This document maps
> the xplr's counter application against zenoh_dart's architecture to identify
> what works, what breaks, and what needs design decisions before reimplementing
> the counter as a Flutter app using the zenoh_dart package.
>
> **Audience**: CI (implementer role) building the new Flutter counter project.

## 1. What the Exploration Project Proved

The xplr was a valid proof-of-concept that confirmed:

1. **FFI works**: Dart can call zenoh-c via a C shim and receive data in real-time
2. **Flutter integration works**: Native zenoh data reaches Flutter widgets
3. **Network discovery works**: `z_scout()` finds routers via UDP multicast
4. **Two-way communication works**: Flutter sends JSON commands, C++ responds

These conclusions remain valid. The xplr succeeded as exploration.

## 2. Architecture Comparison

### xplr Architecture (What To Discard)

```
┌─────────────────────────────────────────────────────────┐
│  zenoh_wrapper.c   (global state, 1 session, 2 subs)   │
│  ┌──────────────────┐  ┌──────────────────────────────┐ │
│  │ zenoh_subscribe() │  │ zenoh_subscribe_string()     │ │
│  │ zenoh_recv()      │  │ zenoh_recv_string()          │ │
│  │ (blocking, FIFO)  │  │ (blocking, FIFO, 1024 buf)  │ │
│  └──────────────────┘  └──────────────────────────────┘ │
│  zenoh_put_string()    zenoh_scout()                    │
└─────────────┬───────────────────────────────────────────┘
              │ DynamicLibrary.open
┌─────────────┴───────────────────────────────────────────┐
│  dart_zenoh.dart   (helper isolates for blocking recv)  │
│  Zenoh.subscribe()  → Stream<int>    via Isolate.spawn  │
│  Zenoh.subscribeString() → Stream<String> via Isolate   │
│  Zenoh.putString()  → direct FFI call                   │
│  Zenoh.scout()      → blocking, returns List<ScoutResult│
└─────────────────────────────────────────────────────────┘
```

**Problems with xplr architecture**:
- Global singleton C wrapper: exactly 1 session, 1 int sub, 1 string sub
- Blocking `recv()` in helper isolates (manual Isolate.spawn, manual SendPort)
- Separate int/string subscription APIs with different C functions
- 1024-byte string buffer with silent truncation
- FIFO channel semantics (zenoh-c `z_fifo_channel`) instead of NativePort
- No SHM integration (the entire reason for building zenoh_dart)

### zenoh_dart Architecture (What To Use)

```
┌─────────────────────────────────────────────────────────┐
│  zenoh_dart.c   (stateless C shim, zd_ prefix)          │
│  zd_declare_subscriber() → Dart_PostCObject_DL          │
│  zd_put(), zd_declare_publisher() → synchronous          │
│  (NativePort callback bridge, no global state)           │
└─────────────┬───────────────────────────────────────────┘
              │ DynamicLibrary.open (single-load)
┌─────────────┴───────────────────────────────────────────┐
│  zenoh.dart   (idiomatic Dart API)                       │
│  Session.open() → Session instance (multi-instance OK)   │
│  Session.declareSubscriber() → Subscriber                │
│  Subscriber.stream → Stream<Sample>                      │
│  Session.put() → direct FFI call                         │
│  Session.declarePublisher() → Publisher (Phase 3)        │
│  Zenoh.scout() (Phase 5)                                 │
└─────────────────────────────────────────────────────────┘
```

**Advantages**:
- Multi-instance sessions (no global state)
- NativePort callback bridge (no helper isolates, no blocking recv)
- Multiple subscribers on the same session (each gets own Stream<Sample>)
- Unified Sample type for all subscriptions
- Clean resource lifecycle (close() on each entity)

## 3. Counter App Zenoh Operations Mapping

### What the C++ counter app does

| Operation | Key Expression | Data Format | Frequency |
|-----------|---------------|-------------|-----------|
| Publish counter | `demo/counter` | Raw int64_t bytes (8 bytes, memcpy) | Every 5s when PLAYING |
| Publish state | `demo/control/state` | JSON string `{"state":"playing","counter":42}` | On state change |
| Subscribe commands | `demo/control/command` | JSON string `{"action":"play"}` | On user action |

### What the Flutter app does

| Operation | Key Expression | Data Format | zenoh_dart API |
|-----------|---------------|-------------|----------------|
| Subscribe counter | `demo/counter` | Raw int64_t → int | **PROBLEM** (see Section 4) |
| Subscribe state | `demo/control/state` | JSON string → parse | `Session.declareSubscriber()` ✅ |
| Publish command | `demo/control/command` | JSON string | `Session.put()` ✅ |
| Scout routers | N/A | ScoutResult list | `Zenoh.scout()` (Phase 5) |
| Check connection | N/A | router count | `Session.routersZid()` (Phase 5) |

## 4. CRITICAL: Binary Payload Problem

### The Problem

The C++ counter publishes raw `int64_t` bytes:
```cpp
// cpp_app/src/main.cpp line 199-200
std::vector<uint8_t> bytes(sizeof(int64_t));
std::memcpy(bytes.data(), &counter, sizeof(int64_t));
counter_publisher.put(Bytes(bytes));
```

zenoh_dart's subscriber decodes ALL payloads as UTF-8 strings:
```dart
// zenoh_dart subscriber.dart line 48
payload: utf8.decode(payloadBytes),
```

**This WILL FAIL**. `utf8.decode` on arbitrary 8 bytes is undefined behavior
(throws or produces garbage). The raw bytes `[42, 0, 0, 0, 0, 0, 0, 0]` are
NOT valid UTF-8.

### The xplr's Approach (FIFO channel, raw memcpy)

The xplr C wrapper does raw `memcpy` to extract the int64:
```c
// zenoh_wrapper.c line 154-164
memcpy(&value, data, sizeof(int64_t));
z_fifo_handler_sample_recv(z_loan(g_handler), &sample); // blocking
```

This works because the xplr has separate int and string subscription
pipelines. It never tries to UTF-8-decode the counter bytes.

### Solutions (Ranked)

**Option A: Expose raw bytes on Sample (RECOMMENDED)**

Add `payloadBytes` field to Sample alongside the decoded `payload` string:

```dart
class Sample {
  final String keyExpr;
  final String payload;        // UTF-8 decoded (may be lossy for binary)
  final Uint8List payloadBytes; // NEW: raw bytes, always available
  final SampleKind kind;
  final String? attachment;
  final String? encoding;      // Phase 3
}
```

This is non-breaking, trivial to implement (the `Uint8List` is already
available in the ReceivePort listener at `message[1]`), and enables the
counter app to do:

```dart
subscriber.stream.listen((sample) {
  final bytes = sample.payloadBytes;
  final counter = ByteData.sublistView(bytes).getInt64(0, Endian.little);
});
```

**Effort**: ~10 lines of code change in `subscriber.dart` + `sample.dart`.
No C shim changes. Non-breaking addition to existing API.

**Option B: Change C++ counter to publish strings**

```cpp
// Instead of raw bytes:
counter_publisher.put(Bytes(std::to_string(counter)));
```

Then the Flutter app just does `int.parse(sample.payload)`.

**Pros**: No zenoh_dart changes needed.
**Cons**: Changes the C++ protocol. Loses the binary-data proof-of-concept
value. Doesn't solve the general problem for SHM (which IS binary data).

**Option C: Use encoding to auto-detect**

zenoh_dart Phase 3 adds `encoding` to both publish and receive. The counter
could publish with `encoding: "zenoh/int64"` and the subscriber could check
encoding to decide how to decode. But this is over-engineered for this case.

**RECOMMENDATION: Option A now, Option B never, Option C later if needed.**

Option A is the minimum viable fix. It takes 10 minutes to implement and
solves the binary payload problem permanently. It's also the right
architectural choice — every protocol needs raw byte access.

## 5. Phase Requirements for Counter App

### Minimum Viable Counter (Phases 0-3 only)

With **Option A** (raw bytes on Sample) and Phases 0-3 complete:

| Feature | zenoh_dart API | Phase |
|---------|---------------|-------|
| Open session | `Session.open(config)` | 0 ✅ |
| Subscribe to counter (int64) | `Session.declareSubscriber()` + `sample.payloadBytes` | 2 ✅ + Option A |
| Subscribe to state (JSON) | `Session.declareSubscriber()` + `sample.payload` | 2 ✅ |
| Publish command (JSON) | `Session.put(keyExpr, jsonString)` | 1 ✅ |
| Close session | `Session.close()` | 0 ✅ |

**Missing (not blocking for MVP)**:
- Scout discovery → hardcode endpoint or use peer mode
- Connection status check → catch ZenohException on operations
- Declared publisher for commands → use Session.put() (simpler, adequate)

### Full Feature Parity (Phases 0-5)

| Feature | zenoh_dart API | Phase |
|---------|---------------|-------|
| All MVP features | (above) | 0-3 |
| Scout for routers | `Zenoh.scout()` | 5 |
| Check connection to router | `Session.routersZid().isNotEmpty` | 5 |
| Session ZID | `Session.zid` | 5 |
| Declared publisher for commands | `Session.declarePublisher()` | 3 |

### SHM Counter (Phase 4 goal)

The ACTUAL goal — the reason zenoh_dart exists:

| Feature | zenoh_dart API | Phase |
|---------|---------------|-------|
| SHM publish counter | `ShmProvider.allocGcDefragBlocking()` → `buf.toBytes()` → `Publisher.putBytes()` | 4 |
| SHM detection on receive | Deferred to Phase 4.1 | 4.1 |

The C++ counter app would need to be modified to use SHM publishing.

## 6. Flutter App Architecture Mapping

### Layers to Keep (from xplr)

The xplr Flutter app has good architecture that should be preserved:

```
domain/                     # Abstract interfaces + entities
  entities/
    app_state.dart          # CounterAppState enum, ControlCommand, CounterStateMessage
    counter_value.dart      # CounterValue (value + timestamp)
    endpoint_option.dart    # EndpointOption (tcp/host:port)
  repositories/
    counter_repository.dart # Abstract CounterRepository interface

data/                       # Implementations
  repositories/
    counter_repository_impl.dart  # Uses ZenohService
  services/
    zenoh_service.dart            # Thin wrapper around dart_zenoh

ui/                         # Flutter widgets + ViewModels (Riverpod)
  counter/
  settings/
```

### Layers to Change

**`data/services/zenoh_service.dart`** → Complete rewrite:

```dart
// xplr: uses global Zenoh() instance with separate int/string APIs
class ZenohService {
  final Zenoh _zenoh;  // global singleton, init/subscribe/putString/dispose
}

// zenoh_dart: uses Session + multiple Subscribers
class ZenohService {
  Session? _session;
  Subscriber? _counterSub;
  Subscriber? _stateSub;

  Future<void> init({String? endpoint}) async {
    final config = Config();
    if (endpoint != null) {
      config.insertJson5('connect/endpoints', '["$endpoint"]');
    }
    _session = Session.open(config: config);
  }

  Stream<int> subscribeCounter(String keyExpr) {
    _counterSub = _session!.declareSubscriber(keyExpr);
    return _counterSub!.stream.map((sample) {
      // Binary int64 from C++ app
      return ByteData.sublistView(sample.payloadBytes)
          .getInt64(0, Endian.little);
    });
  }

  Stream<String> subscribeState(String keyExpr) {
    _stateSub = _session!.declareSubscriber(keyExpr);
    return _stateSub!.stream.map((sample) => sample.payload);
  }

  void putString(String keyExpr, String data) {
    _session!.put(keyExpr, data);
  }

  void dispose() {
    _counterSub?.close();
    _stateSub?.close();
    _session?.close();
  }
}
```

**`data/repositories/counter_repository_impl.dart`** → Minimal changes:

The repository interface (`CounterRepository`) stays the same. The
implementation changes only in how it calls `ZenohService` — the Dart
`Stream` APIs are identical.

Key change: `isConnectedToRouter` needs Phase 5 (`Session.routersZid()`).
For MVP, remove this check or always return true after session opens.

**`domain/entities/`** → Keep as-is:

- `CounterAppState` enum (playing/paused/stopped) — no change
- `ControlCommand` enum with `toJson()` — no change
- `CounterStateMessage` with `fromJson()` — no change
- `EndpointOption` with validation — no change (endpoint format is the same)
- `CounterValue` — no change

**`ui/`** → Minimal changes:

- `counter_viewmodel.dart` — unchanged (works with repository interface)
- `settings_viewmodel.dart` — scout section needs Phase 5, can be deferred
- Widget tree — unchanged (data binding is through Riverpod providers)

### Settings/Discovery (Phase 5 Dependent)

The xplr settings screen has four endpoint sources:
1. **Localhost** — hardcoded `tcp/127.0.0.1:7447` → works immediately
2. **Local network** — `NetworkInterface.list()` → pure Flutter, no zenoh
3. **Discovered routers** — `Zenoh.scout()` → needs Phase 5
4. **Custom** — user-entered text → works immediately

For MVP (Phases 0-3), options 1, 2, 4 work. Option 3 (scout) requires
Phase 5. The settings screen can show "Discovery unavailable" for the
scout section until Phase 5 is complete.

## 7. C++ Counter App: Keep, Modify, or Replace?

### Keep As-Is for Phase 0-3 MVP

The C++ counter app works independently. It uses zenoh-cpp directly (not
zenoh_dart). For the initial Flutter counter, the C++ app is the counterpart
— it publishes and receives. No changes needed.

### Modify for SHM (Phase 4)

When Phase 4 is ready, the C++ counter can be modified to use SHM:

```cpp
// Current: memcpy to vector
std::vector<uint8_t> bytes(sizeof(int64_t));
std::memcpy(bytes.data(), &counter, sizeof(int64_t));
counter_publisher.put(Bytes(bytes));

// SHM: allocate from shared memory
auto buf = provider.alloc_gc_defrag_blocking(sizeof(int64_t)).value();
std::memcpy(buf.data().data(), &counter, sizeof(int64_t));
counter_publisher.put(Bytes(std::move(buf)));
```

### Replace with Dart Publisher (Optional)

Once zenoh_dart has Publisher (Phase 3), the counter publisher could be
reimplemented in Dart, eliminating the C++ dependency entirely. But the
C++ app is useful for cross-language testing and the SHM use case.

## 8. What Must NOT Be Carried Over

| xplr Pattern | Why It's Wrong | zenoh_dart Equivalent |
|-------------|----------------|----------------------|
| Global `g_session` / `g_subscriber` / `g_handler` | Single-instance limitation | Multi-instance Session/Subscriber |
| `zenoh_recv()` blocking in helper Isolate | Unnecessarily complex, race-prone | NativePort callback bridge (automatic) |
| Separate int/string subscription C functions | Code duplication, inflexible | Unified `Stream<Sample>` with type-appropriate decode |
| 1024-byte string buffer | Silent truncation | zenoh_dart uses `z_bytes_to_string` (dynamic allocation) |
| `zenoh_is_connected()` / `zenoh_get_router_count()` | Custom C wrapper functions | `Session.routersZid().length` (Phase 5) |
| `zenoh_scout()` returning malloc'd array | Manual memory management | `Zenoh.scout()` returning `List<Hello>` (Phase 5) |
| `Isolate.spawn()` + `SendPort.send()` | Manual isolate management | Not needed — NativePort handles concurrency |
| `broadcast()` StreamController | Potential missed events | Single-subscription StreamController |

## 9. Recommended Implementation Order

### Step 1: Add `payloadBytes` to Sample (Pre-Phase 3)

This is the ONE blocking change. Without it, the counter app cannot receive
binary int64 payloads from the C++ publisher.

```dart
// sample.dart
class Sample {
  final String keyExpr;
  final String payload;
  final Uint8List payloadBytes;  // ADD THIS
  final SampleKind kind;
  final String? attachment;
  // ...
}

// subscriber.dart line 46-53
final sample = Sample(
  keyExpr: keyExpr,
  payload: utf8.decode(payloadBytes, allowMalformed: true),  // CHANGE: allowMalformed
  payloadBytes: payloadBytes,  // ADD THIS
  kind: kind == 0 ? SampleKind.put : SampleKind.delete,
  // ...
);
```

This can be added as a one-slice pre-Phase-3 change or folded into Phase 3
Slice 1.

### Step 2: Complete Phase 3 (Publisher)

Enables declared publisher for the command channel. Not strictly required
(Session.put works) but matches the C++ app's pattern of using declared
publishers for repeated publishing.

### Step 3: Build Flutter Counter MVP

Using Phases 0-3 only:
- Session open/close with config
- Two subscribers (counter + state)
- Session.put for commands
- No scout, no connection check, hardcode endpoint

### Step 4: Complete Phase 5 (Scout/Info)

Enables settings screen discovery features:
- Scout for routers
- Connection verification
- Session ZID display

### Step 5: Complete Phase 4 (SHM)

The actual goal. Modify C++ counter to use SHM, modify Flutter app to
detect and process SHM payloads.

## 10. Router Infrastructure (NOT in zenoh_dart design)

### The Problem

The zenoh router (`zenohd`) is **required infrastructure** for the counter
demo but is completely absent from our zenoh_dart project and design docs.

**Why the router is mandatory**:
- **Android**: No UDP multicast support — apps MUST connect via explicit
  TCP endpoint to a router
- **Cross-process**: WiFi multicast scouting is unreliable between
  separate processes (C++ counter ↔ Flutter app)
- **CI/Docker**: No multicast in containers
- **xplr lesson** (from `IMPLEMENTATION_LESSONS_v2.md`): "Router mode with
  explicit TCP endpoints is the only reliable approach for development and
  testing"

### What the xplr project has

```
extern/zenoh/              # Full Rust zenoh repo (submodule)
  target/release/zenohd    # Built router binary

scripts/
  start-zenoh.sh           # Interactive: zenohd -l tcp/0.0.0.0:7447 --no-multicast-scouting
  e2e_test.sh              # Starts router before E2E tests
```

### What zenoh_dart has

Nothing. We have `extern/zenoh-c` (C bindings) but not `extern/zenoh`
(Rust core that contains `zenohd`). No router binary, no scripts.

### Options for the Counter Demo

**Option 1: Add `extern/zenoh` submodule to zenoh_dart** (RECOMMENDED)

Add the Rust zenoh repo as a submodule (same v1.7.2 tag). Build `zenohd`
from source. This is what the xplr does.

```bash
git submodule add -b release/1.7.2 https://github.com/eclipse-zenoh/zenoh.git extern/zenoh
cd extern/zenoh && cargo build --release --package zenohd
# Produces: extern/zenoh/target/release/zenohd
```

Add scripts:
- `scripts/start_router.sh` — starts zenohd on configurable port
- Document in README.md under "Development Setup"

**Pros**: Self-contained, version-locked to same zenoh version.
**Cons**: Large submodule (~100MB source), requires Rust toolchain.

**Option 2: Download pre-built zenohd from GitHub releases**

zenoh publishes binaries for Linux/macOS/Windows on
[GitHub releases](https://github.com/eclipse-zenoh/zenoh/releases).

```bash
# Example for Linux x86_64
wget https://github.com/eclipse-zenoh/zenoh/releases/download/1.2.0/zenoh-1.2.0-x86_64-unknown-linux-gnu-standalone.zip
unzip -j zenoh-*.zip zenohd -d scripts/
```

**Pros**: No Rust toolchain needed, fast.
**Cons**: Version may not match zenoh-c v1.7.2 exactly (need compatible
release). No Android router (Android runs the client, not the router).

**Option 3: Docker image**

```bash
docker run --rm -p 7447:7447 eclipse/zenoh:1.2.0 --no-multicast-scouting
```

**Pros**: Zero setup, reproducible.
**Cons**: Requires Docker, not ideal for ad-hoc development.

**Option 4: Separate project concern**

The router is infrastructure, not part of the Dart package. The counter
demo project (separate from zenoh_dart) handles its own router deployment.

**Pros**: Clean separation of concerns.
**Cons**: Every developer must figure out router setup independently.

### Recommendation

**Option 1 for development, Option 4 for architecture**. The zenoh_dart
package should NOT include the router — it's a client library. But the
counter demo project (wherever it lives) should either:
- Include `extern/zenoh` submodule + build script, OR
- Document how to obtain `zenohd` with version compatibility notes

### Deployment Topology

```
┌───────────────────────────────────────────────────┐
│                Desktop/Server                      │
│                                                    │
│   zenohd router ←─── tcp/0.0.0.0:7447 ───→        │
│       ↕                                            │
│   C++ Counter App ──── client mode ────→ zenohd    │
│       ↕                                            │
│   Flutter App (Linux) ── client mode ──→ zenohd    │
│                                                    │
└───────────────────────────────────────────────────┘
         │
         │  tcp/<desktop-ip>:7447
         ↓
┌───────────────────────────────────────────────────┐
│              Android Device                        │
│                                                    │
│   Flutter App (Android) ── client mode ──→ zenohd  │
│   (manual endpoint entry or QR code)               │
│                                                    │
└───────────────────────────────────────────────────┘
```

### Android Connection Flow

1. User enters router endpoint in settings (e.g., `tcp/192.168.1.50:7447`)
   - Or scans QR code with endpoint
   - Or selects from saved endpoints
2. Flutter app opens Session with `connect/endpoints` config
3. Session connects to router via TCP
4. Subscribe/publish through router to reach C++ counter app

**No multicast scouting on Android** — the settings screen's "Discovered
Routers" section must be hidden or marked "Desktop only" on mobile.

## 11. Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| Binary payload breaks UTF-8 decode | **CERTAIN** | **HIGH** — app crashes or shows garbage | Option A (payloadBytes field) |
| Scout not available for settings | EXPECTED | MEDIUM — settings screen incomplete | Defer scout section, hardcode endpoint |
| SHM not available | EXPECTED | LOW — SHM is Phase 4, not MVP | Build counter without SHM first |
| C++ counter protocol changes | LOW | HIGH — breaks compatibility | Keep C++ app as-is, adapt Dart side |
| Multiple subscribers conflict | NONE | N/A | zenoh_dart supports multiple subs natively |
| Riverpod version mismatch | LOW | MEDIUM | Pin to same version as xplr (3.x) |

## 11. Files Reference (xplr)

**Must read before implementing**:
- `apps/cpp_app/src/main.cpp` — C++ counter protocol (key expressions, data formats)
- `apps/flutter_app/lib/domain/` — Domain entities and interfaces to reuse
- `apps/flutter_app/lib/data/repositories/counter_repository_impl.dart` — Repository pattern
- `apps/flutter_app/lib/data/services/zenoh_service.dart` — Service abstraction
- `apps/flutter_app/lib/ui/counter/counter_viewmodel.dart` — UI state management
- `apps/flutter_app/lib/domain/entities/endpoint_option.dart` — Endpoint validation

**Can ignore**:
- `packages/dart_zenoh/` — Entire FFI package (replaced by zenoh_dart)
- `apps/cpp_app/tests/shm_publisher_unit_test.cpp` — SHM exploration test (RED phase, unused)
- `docs/exploration/` — Historical exploration docs
