# Cross-Cutting Design Patterns for Phases 3-5+

This document establishes patterns that span multiple phases of zenoh-dart
development. All patterns are derived from zenoh-c v1.7.2 and zenoh-cpp v1.7.2
reference implementations. CP and CI should reference this document when
planning and implementing any phase from 3 onwards.

## 1. C Shim Conventions

Established in Phases 0-2 and mandatory for all future phases.

### 1.1 `zd_` Prefix

All C shim symbols use the `zd_` prefix. ffigen.yaml filters on `zd_.*`.

### 1.2 sizeof Helpers

Every owned zenoh type needs a sizeof helper for Dart FFI allocation:

```c
FFI_PLUGIN_EXPORT size_t zd_<type>_sizeof(void);
// Implementation: return sizeof(z_owned_<type>_t);
```

Dart allocates with `calloc.allocate(bindings.zd_<type>_sizeof())`.

**Required for**: publisher, queryable, query, reply, shm_provider, shm_mut,
shm, encoding (if owned), hello, and any future owned type.

### 1.3 loan/drop Pattern

Every owned type needs at minimum:

```c
FFI_PLUGIN_EXPORT const z_loaned_<type>_t* zd_<type>_loan(const z_owned_<type>_t* t);
FFI_PLUGIN_EXPORT void zd_<type>_drop(z_owned_<type>_t* t);
```

The drop implementation always follows:
```c
z_<type>_drop(z_<type>_move(t));
```

### 1.4 Flattened Parameters (No Struct Passing)

C options structs (`z_publisher_options_t`, `z_get_options_t`, etc.) are NOT
passed through FFI. Instead, the C shim receives individual parameters and
constructs the options struct internally:

```c
// WRONG: passing options struct through FFI
FFI_PLUGIN_EXPORT int zd_declare_publisher(session, publisher, keyexpr,
    const z_publisher_options_t* options);

// RIGHT: flattened parameters
FFI_PLUGIN_EXPORT int zd_declare_publisher(session, publisher, keyexpr,
    const char* encoding,       // NULL = default
    int congestion_control,     // -1 = default
    int priority);              // -1 = default
```

**Rationale**: Dart FFI cannot easily construct C structs with nested pointers
and move semantics. The C shim handles defaults, `z_encoding_from_str()`,
`z_bytes_move()`, etc. internally.

### 1.5 Sentinel Values for Defaults

Use sentinel values when a parameter should mean "use the default":

| Type | Sentinel | Meaning |
|------|----------|---------|
| `const char*` | `NULL` | No encoding / no value |
| `int` (enum) | `-1` | Use zenoh-c default |
| `z_owned_bytes_t*` | `NULL` | No attachment |
| `int64_t` (port) | `0` | No callback |
| `uint64_t` (timeout) | `0` | Use default timeout |

### 1.6 Return Code Convention

All C shim functions returning `int` follow: `0` = success, `!= 0` = failure.
Dart checks `!= 0` (not `< 0`) defensively.

---

## 2. Encoding Pattern

**Decision: String-passthrough. No FFI functions for Encoding.**

### 2.1 Rationale

zenoh-c has 55 predefined encoding constants plus `z_encoding_from_str()` for
custom encodings. Exposing individual constants as C shim functions would
require 55+ wrappers. Instead:

- The C shim receives encoding as `const char*` (MIME type string)
- Internally calls `z_encoding_from_str()` to create a temporary
  `z_owned_encoding_t`
- Passes it as `z_move(encoding)` to the options struct (consumed)
- If the string is NULL, no encoding is set (uses default)

### 2.2 Dart API

```dart
/// Content encoding for zenoh payloads.
///
/// Predefined constants cover common MIME types. Custom encodings
/// can be created with the default constructor: `Encoding('custom/type')`.
class Encoding {
  final String mimeType;
  const Encoding(this.mimeType);

  // Zenoh-specific
  static const zenohBytes = Encoding('zenoh/bytes');
  static const zenohString = Encoding('zenoh/string');

  // Common MIME types (subset -- users can create any with constructor)
  static const textPlain = Encoding('text/plain');
  static const applicationJson = Encoding('application/json');
  static const applicationOctetStream = Encoding('application/octet-stream');
  static const applicationProtobuf = Encoding('application/protobuf');
  static const textHtml = Encoding('text/html');
  static const textCsv = Encoding('text/csv');
  static const imagePng = Encoding('image/png');
  static const imageJpeg = Encoding('image/jpeg');

  @override
  String toString() => mimeType;
}
```

**Note**: This class has ZERO FFI dependencies. It is pure Dart. The C shim
receives `encoding.mimeType` as a `const char*` via `toNativeUtf8()`.

### 2.3 C Shim Pattern

```c
// Inside any C shim function that accepts encoding:
if (encoding_str != NULL) {
    z_owned_encoding_t enc;
    z_encoding_from_str(&enc, encoding_str);
    opts.encoding = z_encoding_move(&enc);
}
```

### 2.4 Where Encoding Appears

| Phase | Operation | Encoding parameter |
|-------|-----------|-------------------|
| 3 | `zd_declare_publisher` | Default encoding for publisher |
| 3 | `zd_publisher_put` | Per-put encoding override |
| 6 | `zd_get` | Query encoding |
| 6 | `zd_query_reply` | Reply encoding |
| 6 | `zd_query_reply_err` | Error encoding |
| Future | `zd_put` (enhanced) | Session-level put encoding |

### 2.5 Sample.encoding (Receive Side)

When receiving a Sample (subscriber or get reply), the encoding is extracted
from `z_sample_encoding()` and converted to a string via
`z_encoding_to_string()`. See Section 8 (Sample Evolution).

---

## 3. QoS Enums

### 3.1 CongestionControl

```dart
/// Congestion control strategy for message routing.
enum CongestionControl {
  /// Block until the message can be sent (default).
  block,   // Z_CONGESTION_CONTROL_BLOCK = 0

  /// Drop the message if the outgoing queue is full.
  drop,    // Z_CONGESTION_CONTROL_DROP = 1
}
```

Maps to C: `block` = 0, `drop` = 1. Sentinel `-1` = use default (block).

### 3.2 Priority

```dart
/// Message priority. Lower numeric values = higher priority.
enum Priority {
  realTime,        // Z_PRIORITY_REAL_TIME = 1
  interactiveHigh, // Z_PRIORITY_INTERACTIVE_HIGH = 2
  interactiveLow,  // Z_PRIORITY_INTERACTIVE_LOW = 3
  dataHigh,        // Z_PRIORITY_DATA_HIGH = 4
  data,            // Z_PRIORITY_DATA = 5 (default)
  dataLow,         // Z_PRIORITY_DATA_LOW = 6
  background,      // Z_PRIORITY_BACKGROUND = 7
}
```

Maps to C: `realTime` = 1, ..., `background` = 7. Sentinel `-1` = use default
(data = 5).

**Note**: Verify exact enum values from `z_priority_t` in
`extern/zenoh-c/include/zenoh_commons.h` during implementation. The names
above match zenoh-cpp's `Priority` enum.

### 3.3 Where QoS Appears

| Phase | Operation | Has QoS? |
|-------|-----------|----------|
| 3 | `z_publisher_options_t` | YES (set at declaration) |
| 3 | `z_publisher_put_options_t` | NO (inherited from publisher) |
| 6 | `z_get_options_t` | YES |
| 6 | `z_query_reply_options_t` | YES |
| 6 | `z_query_reply_del_options_t` | YES |
| Future | `z_put_options_t` | YES (currently using defaults) |

**Key insight**: Publisher-level put/delete operations inherit QoS from the
publisher declaration. Session-level operations set QoS per-call.

### 3.4 Deferred QoS Fields

These exist in zenoh-c but are explicitly NOT exposed:

| Field | Reason | Future Phase |
|-------|--------|--------------|
| `is_express` | Optimization knob, not core | Phase 9+ |
| `reliability` | Unstable API | TBD |
| `allowed_destination` | Locality, feature-gated | TBD |

---

## 4. Attachment Pattern

### 4.1 Send Side

Attachment is an optional `ZBytes` that rides alongside the main payload.
It is CONSUMED (moved) by the operation.

```dart
// Dart API pattern:
publisher.put('hello', attachment: ZBytes.fromString('metadata'));
```

```c
// C shim pattern:
// attachment parameter is z_owned_bytes_t* (NULL = no attachment)
if (attachment != NULL) {
    opts.attachment = z_bytes_move(attachment);
}
```

### 4.2 Receive Side

Already implemented in Phase 2. The subscriber callback extracts attachment
from `z_sample_attachment()` and includes it in the Dart_CObject array.

### 4.3 Where Attachment Appears

| Phase | Operation | Attachment? |
|-------|-----------|-------------|
| 3 | `zd_publisher_put` | YES (optional) |
| 6 | `zd_get` | YES (query attachment) |
| 6 | `zd_query_reply` | YES (reply attachment) |
| 6 | `zd_query_reply_del` | YES (delete reply attachment) |
| Future | `zd_put` (enhanced) | YES |

---

## 5. Options Mapping

### 5.1 Pattern

For every zenoh-c options struct, the Dart API uses named parameters and the
C shim receives flattened individual values:

```
zenoh-c:  z_publisher_options_t { encoding, congestion_control, priority, ... }

Dart API: Session.declarePublisher(keyExpr, {
            Encoding? encoding,
            CongestionControl congestionControl = CongestionControl.block,
            Priority priority = Priority.data,
          })

C shim:   zd_declare_publisher(session, publisher, keyexpr,
            const char* encoding,   // Encoding.mimeType or NULL
            int congestion_control, // enum index or -1
            int priority)           // enum value or -1
```

### 5.2 Dart Enum to C Int Mapping

```dart
// In Dart, convert enum to C int:
final ccInt = congestionControl?.index ?? -1;  // block=0, drop=1, null=-1
final prioInt = priority != null ? priority.index + 1 : -1;  // realTime=1..background=7, null=-1
```

**Important**: Priority enum values are 1-indexed in zenoh-c (1-7), not
0-indexed. The Dart enum `Priority.realTime.index` returns 0, so add 1 for
the C value.

### 5.3 Which Options Structs Are Split vs Unified

| zenoh-c options | C shim approach |
|-----------------|-----------------|
| `z_publisher_options_t` | Flattened into `zd_declare_publisher` params |
| `z_publisher_put_options_t` | Flattened into `zd_publisher_put` params |
| `z_publisher_delete_options_t` | No meaningful params, pass NULL internally |
| `z_queryable_options_t` | Flattened into `zd_declare_queryable` params |
| `z_get_options_t` | Flattened into `zd_get` params |
| `z_query_reply_options_t` | Flattened into `zd_query_reply` params |

**Never create two C shim functions** (one with opts, one without) for the
same operation. Use one function with sentinel values for defaults.

---

## 6. Entity Lifecycle

### 6.1 Declared Entities

Publisher (Phase 3), Subscriber (Phase 2), Queryable (Phase 6), and
ShmProvider (Phase 4) all follow this lifecycle:

```
Session.declare<Entity>(keyExpr, options)  →  Entity instance
Entity.operations(...)                     →  use the entity
Entity.close()                            →  undeclare + free
```

### 6.2 Dart Implementation Pattern

```dart
class Publisher {
  final Pointer<Void> _ptr;
  bool _closed = false;

  void _ensureLive() {
    if (_closed) throw StateError('Publisher has been closed');
  }

  void put(String value, ...) {
    _ensureLive();
    // ... FFI call ...
  }

  void close() {
    if (_closed) return;  // Idempotent
    _closed = true;
    bindings.zd_publisher_drop(_ptr.cast());
    // Close any ReceivePort / StreamController
    calloc.free(_ptr);
  }
}
```

### 6.3 Invariants

1. **Idempotent close**: `close()` is safe to call multiple times (no-op after first)
2. **StateError after close**: All operations throw `StateError` after close
3. **Native memory freed**: `calloc.free(_ptr)` always called in close
4. **NativePort cleanup**: If entity has a callback (matching listener, subscriber),
   close ReceivePort and StreamController in close()
5. **Session.declare* checks**: `_ensureOpen()` before creating entities

### 6.4 Entity-Session Independence

Entities hold a copy of the loaned session pointer at declaration time.
Closing the session does NOT automatically close entities (zenoh-c handles
this internally — the entity's drop will be a no-op if session is gone).
However, operations on the entity after session close may fail.

---

## 7. NativePort Callback Bridge

### 7.1 Established Pattern (Phase 2)

```
zenoh Rust thread → C callback → Dart_PostCObject_DL → ReceivePort → StreamController → Stream
```

Context struct:
```c
typedef struct {
  Dart_Port_DL dart_port;
} zd_<feature>_context_t;
```

Callback: extracts data from loaned zenoh type, builds Dart_CObject array,
posts via `Dart_PostCObject_DL`.

Drop: `free(context)`.

### 7.2 Dart_CObject Formats

Each callback type has a defined serialization format:

**Subscriber sample** (Phase 2):
```
[keyexpr(String), payload(Uint8List), kind(Int64), attachment(Null|Uint8List)]
```

**Matching status** (Phase 3):
```
Int64: 1 = matching, 0 = not matching
```

**Queryable query** (Phase 6 — future):
```
[query_ptr(Int64), keyexpr(String), parameters(String), payload(Null|Uint8List),
 attachment(Null|Uint8List), encoding(Null|String)]
```

**Get reply** (Phase 6 — future):
```
OK:    [is_ok(Int64=1), keyexpr(String), payload(Uint8List), kind(Int64),
        attachment(Null|Uint8List), encoding(Null|String)]
Error: [is_ok(Int64=0), err_payload(Uint8List), err_encoding(Null|String)]
Done:  Null (sentinel)
```

### 7.3 When NOT to Use NativePort

Some callbacks are **synchronous/blocking** — they complete before the
C function returns:

- `z_scout()` — blocks for timeout_ms, callbacks fire during execution
- `z_info_peers_zid()` — iterates internal state synchronously
- `z_info_routers_zid()` — same

For these, the NativePort pattern still works but the C function blocks
the calling isolate. Solutions:
- **Short operations** (info): call directly, acceptable blocking
- **Long operations** (scout): run on a helper isolate via `Isolate.run()`

### 7.4 Query Clone-and-Post (Phase 6)

Queryable callbacks receive `z_loaned_query_t*` which is only valid during
the callback. The C shim must clone the query and post a handle:

```c
static void _zd_query_callback(z_loaned_query_t* query, void* ctx) {
    z_owned_query_t* owned = malloc(sizeof(z_owned_query_t));
    z_query_clone(owned, query);

    // Post: [query_ptr, keyexpr, parameters, payload, attachment, encoding]
    // query_ptr is the heap pointer cast to int64

    Dart_PostCObject_DL(ctx->dart_port, &array);
}
```

Dart holds the pointer and passes it back for `zd_query_reply()` and
`zd_query_drop()`. This is the **clone-and-post** pattern from Phase 6 spec.

---

## 8. Sample Evolution

### 8.1 Current Sample (Phase 2)

```dart
class Sample {
  final String keyExpr;
  final String payload;
  final SampleKind kind;
  final String? attachment;
}
```

### 8.2 Phase 3 Addition: encoding

```dart
class Sample {
  final String keyExpr;
  final String payload;
  final SampleKind kind;
  final String? attachment;
  final String? encoding;    // NEW: MIME type string, null = default
}
```

The C shim subscriber callback must be updated to extract encoding via
`z_sample_encoding()` → `z_encoding_to_string()` and include it as a 5th
element in the Dart_CObject array.

**This is a non-breaking change**: the `encoding` parameter is optional with
a null default. The Dart_CObject format change is internal (C shim +
ReceivePort handler, not public API).

### 8.3 Phase 4 Addition: SHM detection

ZBytes (which is the underlying type for payload) gains SHM detection:

```dart
class ZBytes {
  bool get isShmBacked;        // NEW
  ShmMutBuffer? asShmMut();    // NEW
}
```

Sample.payload remains a `String` (UTF-8 decoded). For SHM-aware subscribers,
the raw ZBytes would need to be accessible. This may require Sample to carry
the raw ZBytes in addition to the decoded string. **Decision deferred to
Phase 4 planning** — the Phase 4 spec already addresses this.

### 8.4 Future Fields (Not Yet)

zenoh-c's `z_sample_*` accessors expose 7+ metadata fields. These are
explicitly deferred:

| Field | Accessor | Phase |
|-------|----------|-------|
| timestamp | `z_sample_timestamp` | Phase 9+ |
| congestion_control | `z_sample_congestion_control` | Phase 9+ |
| priority | `z_sample_priority` | Phase 9+ |
| is_express | `z_sample_express` | Phase 9+ |
| source_info | `z_sample_source_info` | TBD (unstable) |
| reliability | `z_sample_reliability` | TBD (unstable) |

---

## 9. Testing Conventions

### 9.1 Two-Session Testing

Multi-endpoint tests (pub/sub, queryable/get) open two sessions in the same
process with explicit TCP listen/connect:

```dart
final session1 = Session.open(config: Config()
  ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:$port"]'));
final session2 = Session.open(config: Config()
  ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:$port"]'));
```

### 9.2 Port Allocation

Each test group uses unique ports to avoid conflicts:

| Phase | Port Range |
|-------|-----------|
| Phase 2 (subscriber) | 17448-17450, 18551 |
| Phase 3 (publisher) | 17451-17455, 18552 |
| Phase 4 (SHM) | 17456-17460, 18553 |
| Phase 5 (scout/info) | 17461-17465, 18554 |
| Phase 6 (queryable/get) | 17466-17470, 18555 |

### 9.3 Timing

Pub/sub tests need delays for routing propagation:
- 1s after subscriber/queryable declaration
- Short delay (100-500ms) between puts for ordering tests
- 5s timeout for stream expectations

### 9.4 Test File Placement

```
package/test/
  publisher_test.dart       # Phase 3
  encoding_test.dart        # Phase 3 (if encoding has testable logic)
  shm_provider_test.dart    # Phase 4
  scout_test.dart           # Phase 5
  queryable_test.dart       # Phase 6
  z_pub_cli_test.dart       # Phase 3 CLI
  z_pub_shm_cli_test.dart   # Phase 4 CLI
```

---

## 10. Phase Applicability Matrix

| Pattern | Phase 3 (Publisher) | Phase 4 (SHM) | Phase 5 (Scout) | Phase 6 (Get/Queryable) |
|---------|:--:|:--:|:--:|:--:|
| sizeof helper | YES | YES | YES | YES |
| loan/drop | YES | YES | -- | YES |
| Flattened params | YES | YES | YES | YES |
| Encoding (string-passthrough) | YES | -- | -- | YES |
| QoS enums | YES | -- | -- | YES |
| Attachment | YES | -- | -- | YES |
| Entity lifecycle | Publisher | ShmProvider | -- | Queryable |
| NativePort callback | Matching listener | -- | Scout (blocking) | Query + Reply callbacks |
| Sample evolution | Add encoding | Add SHM detection | -- | Reuse in Reply |
| Two-session testing | YES | YES | -- | YES |

---

## 11. Retroactive Improvements

Phase 3 introduces patterns that could improve existing Phase 1 code.
These are **not** required for Phase 3 but should be noted for a future
cleanup phase:

| Current | Improvement | When |
|---------|-------------|------|
| `Session.put(keyExpr, value)` | Add `{Encoding? encoding, CongestionControl? cc, Priority? p, ZBytes? attachment}` | Phase 9+ or when needed |
| `Session.deleteResource(keyExpr)` | Add `{CongestionControl? cc, Priority? p}` | Phase 9+ or when needed |
| `zd_put(session, keyexpr, payload)` | Add encoding, attachment, QoS params | Phase 9+ or when needed |

These are deferred to avoid scope creep. Phase 1's simple API remains
correct — it uses zenoh-c defaults for all options.
