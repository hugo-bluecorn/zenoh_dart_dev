# Why We're Building `package:zenoh` Instead of Using `zenoh_dart` from pub.dev

> **Date**: 2026-03-06
> **Authors**: Hugo + Claude Code (CA role)
> **Decision**: Build our own `package:zenoh` Dart FFI bindings for zenoh-c

## The Question

There is an existing [`zenoh_dart`](https://pub.dev/packages/zenoh_dart)
package on pub.dev (v0.2.0, published by M-PIA/salimpia). Why not use it
instead of building our own?

## Executive Summary

The existing `zenoh_dart` package lacks shared memory (SHM) support, has
no working Android binaries, uses an architecture that cannot support SHM
or reliable async callbacks, and has near-zero community adoption (26
downloads, 0 likes). Our primary motivation for building FFI bindings is
SHM zero-copy data transfer -- the existing package cannot deliver this
without a fundamental architecture rewrite.

## Comparison

| Criteria | `zenoh_dart` (pub.dev) | Our `package:zenoh` |
|----------|----------------------|---------------------|
| **Version** | 0.2.0 | 0.2.0 (Phase 2 complete) |
| **Publisher** | M-PIA (unverified) | Bluecorn |
| **Downloads** | 26 | Internal use |
| **Likes** | 0 | N/A |
| **Pub points** | 150 | N/A |
| **zenoh-c version** | Unspecified | Pinned to v1.7.2 |
| **SHM support** | None | Phase 4 (designed) |
| **Android binaries** | "Build from source" | Cross-compilation script ready |
| **Test count** | Unknown | 80 integration tests |
| **C shim functions** | 0 (direct ffigen) | 34 |

## Architecture Difference

This is the fundamental technical reason. Both packages use `dart:ffi` +
`ffigen`, but the binding architecture is different.

### `zenoh_dart` (pub.dev): Direct ffigen

```
Dart API  -->  ffigen-generated bindings  -->  libzenohc.so
```

ffigen generates Dart bindings directly from zenoh-c's C headers. The Dart
code calls zenoh-c functions through the generated layer.

### Our `package:zenoh`: C shim layer

```
Dart API  -->  ffigen bindings  -->  libzenoh_dart.so (C shim)  -->  libzenohc.so
```

A custom C shim (`src/zenoh_dart.c`) sits between Dart and zenoh-c. ffigen
generates bindings for the shim, not for zenoh-c directly.

### Why the C shim is essential

**1. Async callbacks across threads**

zenoh-c delivers subscriber callbacks on Rust's internal threads, not on
the Dart isolate thread. Dart's ffigen cannot generate C closure function
pointers that safely cross thread boundaries back into Dart.

Our C shim solves this with `Dart_PostCObject_DL` -- a thread-safe
mechanism that posts structured data from any thread to a Dart
`ReceivePort`. The shim:
- Receives the callback on Rust's thread
- Packs the data into a `Dart_CObject` array
- Posts it to Dart's event loop via the NativePort

Without this, subscribers either don't work across threads or require
unsafe workarounds.

**2. Macros are invisible to ffigen**

zenoh-c relies heavily on C macros for its ownership model:
- `z_loan()` -- borrow a reference
- `z_move()` -- transfer ownership
- `z_drop()` -- release a resource

ffigen only processes function declarations, not macros. Our C shim
expands these into real functions (`zd_session_loan()`,
`zd_publisher_drop()`) that ffigen can see and Dart can call.

**3. Complex structs stay in C**

Some zenoh-c types have internal unions, nested structs, or
platform-dependent layouts that are difficult to handle correctly from
Dart's FFI. Examples:
- `z_buf_layout_alloc_result_t` (SHM allocation result with status +
  buffer + error unions)
- `z_closure_sample_t` (callback closure with function pointer + context +
  drop)

Our C shim handles these internally and exposes simple interfaces to Dart
(int return codes, output pointers).

**4. SHM requires it**

Shared memory operations involve:
- Raw pointer manipulation (`z_shm_mut_data_mut()`)
- Buffer lifecycle management (mutable -> immutable -> bytes conversion)
- Provider pool management with allocation strategies
- Feature-flag guards (`Z_FEATURE_SHARED_MEMORY`)

These are inherently C-level operations. A pure ffigen approach would need
to expose all the internal SHM types to Dart and handle their lifecycles
correctly across the FFI boundary -- effectively reimplementing a C shim
in Dart, which is both harder and more error-prone.

## Why SHM is the dealbreaker

SHM (Shared Memory) is the primary reason we chose to build dart:ffi
bindings rather than use a higher-level approach (REST API, WebSocket
bridge, pure Dart protocol implementation).

SHM enables **zero-copy data transfer** between zenoh peers on the same
machine. For our use case (high-frequency data exchange between a C++
application and a Flutter client on the same device), SHM eliminates the
serialization/deserialization overhead entirely.

The existing `zenoh_dart` package:
- Has no SHM support
- Cannot add SHM support without introducing a C shim layer
- Adding a C shim would be a fundamental architecture change

We designed SHM support from day one (Phase 4 spec complete, C shim
functions defined, Dart API designed).

## Other Risk Factors

### No version pinning
The existing package downloads zenoh-c binaries from GitHub releases
without specifying a version. zenoh has strict version compatibility
requirements -- a zenohd router at v1.7.2 cannot reliably communicate
with a client built against v1.6.x. We pin all components (zenoh-c,
zenoh-cpp, zenohd) to v1.7.2.

### No Android story
Their package lists Android as requiring "build from source." Our project
includes a cross-compilation script (`scripts/build_zenoh_android.sh`)
using cargo-ndk and has a CMake 3-tier library discovery system designed
for Android deployment.

### Unknown test coverage
We have 80 integration tests covering session lifecycle, pub/sub across
sessions, stream behavior, cleanup, and CLI examples. Their test coverage
is unknown.

### Single maintainer risk
Published by an unverified account with near-zero adoption. If the
maintainer stops updating, we'd need to fork and maintain it anyway --
at which point we'd need to add the C shim layer for SHM.

## Dart/Flutter Ecosystem Integration

Our `package:zenoh` is a **pure Dart FFI package**, not a Flutter plugin.
This is a deliberate design choice that makes zenoh available across the
entire Dart ecosystem, not just Flutter:

- **Serverpod** -- server-side Dart applications can use zenoh for
  pub/sub communication between microservices
- **Dart CLI tools** -- standalone command-line applications (our
  `z_put.dart`, `z_sub.dart` examples run without Flutter)
- **Dart backends** -- any Dart server framework (shelf, dart_frog, etc.)
- **Flutter apps** -- mobile, desktop, and web (via a future
  `zenoh_flutter` convenience wrapper)
- **Dart isolates** -- works in any isolate, enabling background
  processing patterns

The existing `zenoh_dart` package does not clearly separate Flutter
concerns from core Dart FFI functionality, limiting its reuse outside
Flutter contexts.

By keeping the core package pure Dart, we enable zenoh adoption across
the full Dart runtime spectrum -- from embedded CLI tools to Serverpod
backends to Flutter mobile apps -- all sharing the same battle-tested
FFI bindings.

## Conclusion

Building `package:zenoh` is the correct approach because:

1. **SHM requires a C shim** -- the existing package can't support it
2. **Reliable callbacks require a C shim** -- NativePort is the safe pattern
3. **We control the roadmap** -- features ship when we need them
4. **Version-locked components** -- no silent incompatibilities
5. **Android-ready** -- cross-compilation infrastructure in place
6. **Tested** -- 80 integration tests, growing with each phase
7. **Full Dart ecosystem** -- works with Serverpod, CLI, any Dart runtime,
   not just Flutter

The existing `zenoh_dart` package is a valid proof-of-concept for simple
use cases, but it cannot serve as the foundation for a production system
that requires SHM, reliable Android support, version-controlled
deployments, and broad Dart ecosystem compatibility.
