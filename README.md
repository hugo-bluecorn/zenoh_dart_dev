# Zenoh Dart — Development Workshop

> ## *Lasciate ogne speranza, voi ch'intrate*
>
> **This is the development workshop repository.** It contains phase specs, design documents, experiments, audits, LaTeX papers, 7 git submodules, and the full archaeological record of building zenoh-dart from scratch. It is a complicated mess by design.
>
> **Looking for the package?** Go to **[zenoh_dart](https://github.com/hugo-bluecorn/zenoh_dart)** — the clean product repository with a single submodule, `package/` publish boundary, and 193 passing tests.

Pure Dart FFI bindings for [Zenoh](https://zenoh.io/) — a pub/sub/query protocol for real-time, distributed systems. This package wraps [zenoh-c](https://github.com/eclipse-zenoh/zenoh-c) v1.7.2 through a thin C shim layer, giving Dart and Flutter applications access to zenoh's wire protocol without native plugin boilerplate.

It runs anywhere Dart runs: CLI tools, Serverpod backends, Flutter apps on Linux and Android.

## Architecture

```
┌─────────────────────────────────┐
│  Idiomatic Dart API              │  Session, Publisher, Subscriber, ShmProvider, ...
│  package/lib/src/         │
├─────────────────────────────────┤
│  Generated FFI Bindings          │  bindings.dart — class-based ZenohDartBindings(DynamicLibrary)
│  (auto-generated, never edited)  │
├─────────────────────────────────┤
│  C Shim (src/zenoh_dart.{h,c})   │  62 zd_* functions
├─────────────────────────────────┤
│  libzenohc.so (zenoh-c v1.7.2)   │  Rust-based zenoh — linked via DT_NEEDED
└─────────────────────────────────┘
```

### Why the C shim exists

zenoh-c's public API uses six constructs that cannot cross the Dart FFI barrier:

| Barrier | zenoh-c mechanism | Why `dart:ffi` can't call it |
|---------|-------------------|------------------------------|
| Generic macros | `z_open()`, `z_close()`, `z_drop()` are `_Generic` macros | Macros don't produce linkable symbols |
| Opaque struct sizes | `z_owned_session_t`, etc. | Dart needs `sizeof` at runtime to allocate |
| Closure callbacks | `z_owned_closure_*_t` across threads | Can't pass Dart closures as C function pointers |
| Move semantics | `z_*_move()` inline functions | Inline functions don't produce symbols |
| Options struct defaults | `z_*_options_default()` macros | Can't call macros or set fields on opaque structs |
| Loan pattern | `z_loan()` / `z_loan_mut()` macros | Macros, plus Dart `Pointer<Opaque>` erases const/mut |

The C shim flattens all six into plain C functions with scalar/pointer signatures that `dart:ffi` can bind directly. All symbols use the `zd_` prefix; `ffigen.yaml` filters on `zd_.*` so only shim functions appear in `bindings.dart`. The full audit with function-by-function analysis is in [`docs/c-shim/`](docs/c-shim/).

### How native libraries load

Only `libzenoh_dart.so` is loaded explicitly. The OS dynamic linker resolves `libzenohc.so` transitively via the `DT_NEEDED` entry in the ELF headers, with `RPATH=$ORIGIN` ensuring it finds the dependency in the same directory.

On **Linux desktop**, `native_lib.dart` resolves the absolute path via `Isolate.resolvePackageUriSync()`, preferring `native/linux/x86_64/` (developer prebuilts) over `.dart_tool/lib/` (build hook output), then calls `DynamicLibrary.open()` eagerly on the main thread.

On **Android**, a bare `DynamicLibrary.open('libzenoh_dart.so')` call is sufficient — the APK linker resolves from `lib/<abi>/` automatically.

Build hooks (`hook/build.dart`) register both `.so` files as `CodeAsset` entries for **distribution only** — they handle bundling into APKs via Flutter's native assets pipeline. The hooks do not participate in loading; that's handled entirely by `DynamicLibrary.open()` with manual path resolution.

> **Why not `@Native`?** A [2x2 experiment](experiments/hooks-bundling/) proved that `@Native` annotations are the only way to get Dart's build hook system to resolve libraries transparently — `DynamicLibrary.open()` delegates to the OS linker, which knows nothing about hook metadata. So we [migrated to `@Native`](experiments/hooks-bundling/synthesis.md) (PR #18, 185 tests). Then inter-process TCP testing discovered that `@Native`'s lazy loading wraps `dlopen` in `NoActiveIsolateScope` (thread-isolate detachment), which causes tokio's waker vtable to crash when two Dart processes connect via zenoh. The hybrid approach (pre-load via `DynamicLibrary.open()` then let `@Native` re-use the handle) also [failed](docs/design/fix-rtld-local-interprocess-crash.md) — `NoActiveIsolateScope` taints the handle regardless. So we [reverted `@Native` entirely](docs/reviews/interprocess-crash-fix-review.md) (PR #19) back to class-based `ZenohDartBindings(DynamicLibrary)` and kept the build hooks for Flutter distribution only. The hooks register orphaned `CodeAsset` IDs that no `@Native` annotation references — they serve purely as a file-copy mechanism. This is unconventional but functional.

## Current Status

**62 C shim functions, 18 Dart API classes, 193 integration tests, 7 CLI examples.**

| Phase | What it added | Tests |
|-------|---------------|-------|
| 0 — Bootstrap | `Config`, `Session`, `KeyExpr`, `ZBytes`, `ZenohException` | 33 |
| 1 — Put/Delete | `Session.put()`, `putBytes()`, `deleteResource()`; `z_put.dart`, `z_delete.dart` | 56 |
| 2 — Subscribe | `Subscriber` with `Stream<Sample>` via NativePort callback bridge; `z_sub.dart` | 80 |
| 3 — Publish | `Publisher`, `Encoding`, `CongestionControl`, `Priority`; matching listener; `z_pub.dart` | 120 |
| 4 — SHM Pub/Sub | `ShmProvider`, `ShmMutBuffer` — zero-copy shared memory; `z_pub_shm.dart` | 148 |
| 5 — Scout/Info | `ZenohId`, `WhatAmI`, `Hello`, `Zenoh.scout()`, `Session.zid`; `z_info.dart`, `z_scout.dart` | 185 |

Phases 6-18 (query, liveliness, throughput, storage, advanced) are [specified](development/phases/) but not yet implemented.

### Patches

| Version | What changed |
|---------|-------------|
| v0.6.2 | Inter-process crash fix — reverted `@Native` to `DynamicLibrary.open()` (see [Why not @Native?](#how-native-libraries-load) above); 13 new inter-process TCP tests (193 total) |
| v0.6.3 | Android native library support — target-aware build hook, `build_zenoh_android.sh` cross-compilation, SHM excluded on Android; validated E2E: C++ SHM pub -> zenohd -> WiFi -> Pixel 9a -> Flutter sub |

## Building from Source

> *Lasciate ogne speranza, voi ch'intrate* — Build system overhaul in progress. These instructions are being replaced by proper `cmake --install` targets.

### Prerequisites

| Tool | Why | Minimum |
|------|-----|---------|
| [FVM](https://fvm.app/) | Dart/Flutter version manager — `dart` and `flutter` are **not on PATH**; all commands use `fvm dart` / `fvm flutter` | any |
| Dart SDK | Installed via FVM | ^3.11.0 |
| clang/clang++ | C shim compilation | any recent |
| cmake | Build orchestration for zenoh-c (wraps Cargo) and C shim | 3.10+ |
| ninja | CMake backend | any |
| rustc/cargo | zenoh-c is a Rust crate; CMake invokes Cargo internally | stable, MSRV 1.75.0 |
| patchelf | Rewrite RUNPATH on the C shim `.so` — CMake bakes the build machine's absolute path into RUNPATH, which is meaningless at runtime; `patchelf` replaces it with `$ORIGIN` so the OS linker finds `libzenohc.so` in the same directory | any |

### 1. Clone and init submodules

```bash
git clone --recurse-submodules https://github.com/hugo-bluecorn/zenoh_dart.git
cd zenoh_dart

# Or if already cloned:
git submodule update --init extern/zenoh-c
```

Only `extern/zenoh-c` is required for building. The other submodules (`zenoh-cpp`, `zenoh-kotlin`, `zenoh-demos`, `cargo-ndk`, `zenoh`) are reference material and tooling.

### 2. Build zenoh-c

zenoh-c is a C API around Rust zenoh. CMake orchestrates Cargo underneath. `RUSTUP_TOOLCHAIN=stable` overrides `extern/zenoh-c/rust-toolchain.toml`, which pins an unreleased channel — safe because zenoh-c's MSRV is 1.75.0.

SHM and unstable API flags are required since Phase 4. Without them, the C shim's `#ifdef Z_FEATURE_SHARED_MEMORY` guards exclude SHM functions, and linking fails against test expectations.

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

RUSTUP_TOOLCHAIN=stable cmake --build extern/zenoh-c/build --config Release
```

First build takes ~2-10 minutes (full Rust compile). Subsequent builds are incremental. Output: `extern/zenoh-c/target/release/libzenohc.so`.

### 3. Build C shim

The C shim's `CMakeLists.txt` lives in `src/` and uses three-tier discovery to find `libzenohc.so`: Android jniLibs -> `native/linux/x86_64/` prebuilt -> `extern/zenoh-c/target/release/` developer fallback. On a fresh build, it finds the zenoh-c you just built via the fallback tier.

The C shim adds `-DZ_FEATURE_SHARED_MEMORY -DZ_FEATURE_UNSTABLE_API` compile definitions on non-Android builds, which must match the zenoh-c build flags above.

```bash
cmake -S src -B build -G Ninja \
  -DCMAKE_C_COMPILER=/usr/bin/clang \
  -DCMAKE_BUILD_TYPE=Release

cmake --build build
```

Output: `build/libzenoh_dart.so` (~49KB). It links against `libzenohc.so` via `DT_NEEDED` — the OS linker resolves the dependency at runtime using RUNPATH.

### 4. Place prebuilt libraries

`native_lib.dart` resolves libraries by looking in `package/native/linux/x86_64/` first, falling back to `.dart_tool/lib/`. Both `.so` files must be co-located — `libzenoh_dart.so` declares `DT_NEEDED: libzenohc.so`, and `RUNPATH=$ORIGIN` tells the OS linker to look in the same directory.

```bash
mkdir -p package/native/linux/x86_64/
cp build/libzenoh_dart.so package/native/linux/x86_64/
cp extern/zenoh-c/target/release/libzenohc.so package/native/linux/x86_64/
patchelf --set-rpath '$ORIGIN' package/native/linux/x86_64/libzenoh_dart.so
```

### 5. Run tests

```bash
cd package && fvm dart test
```

No `LD_LIBRARY_PATH` needed. `native_lib.dart` discovers the absolute path via `Isolate.resolvePackageUriSync()` and loads with `DynamicLibrary.open()`.

### 5. Try the CLI examples

```bash
cd package

# Put data on a key expression
fvm dart run example/z_put.dart -k demo/example/test -p 'Hello from Dart!'

# Delete a key expression
fvm dart run example/z_delete.dart -k demo/example/test

# Subscribe (runs until Ctrl-C; combine with z_put or z_pub in another terminal)
fvm dart run example/z_sub.dart -k 'demo/example/**'

# Publish in a loop (runs until Ctrl-C)
fvm dart run example/z_pub.dart -k demo/example/test -p 'Hello from Dart!'

# Publish via shared memory (runs until Ctrl-C)
fvm dart run example/z_pub_shm.dart -k demo/example/test -p 'Hello from SHM!'

# Print own session ZID and connected router/peer ZIDs
fvm dart run example/z_info.dart

# Discover zenoh entities on the network
fvm dart run example/z_scout.dart
```

CLI flags match zenoh-c's examples exactly (`-k`/`--key`, `-p`/`--payload`, `-e`/`--connect`, `-l`/`--listen`).

### Android

```bash
# Cross-compile for Android (requires NDK, cargo-ndk, Rust)
./scripts/build_zenoh_android.sh                  # arm64-v8a + x86_64
./scripts/build_zenoh_android.sh --abi arm64-v8a  # single ABI
```

Build hooks bundle the prebuilts into APKs automatically. SHM is excluded on Android — POSIX `shm_open` is absent from Bionic, and zenoh-c's cargo-ndk build omits the `shared-memory` feature. The C shim's SHM functions are `#ifdef`-guarded and cleanly omitted.

## Development Workflow

This project is developed with [Claude Code](https://claude.ai/code) using two layers of separation designed around the LLM context window constraint.

### Layer 1: TDD Workflow Plugin

The `tdd-workflow` plugin provides four specialized agents that run as autonomous subprocesses within Claude Code sessions. Each agent has a specific mode (read-only or read-write) and a defined scope:

| Agent | What it does | Mode |
|-------|-------------|------|
| **tdd-planner** | Reads phase specs + zenoh-c headers + zenoh-cpp wrappers; decomposes features into testable slices with Given/When/Then; writes `.tdd-progress.md` and `planning/` archive on approval | Read-write (approval-gated) |
| **tdd-implementer** | Takes one slice at a time through RED (failing test) -> GREEN (minimal code to pass) -> REFACTOR; writes C shim, Dart API, and tests | Read-write |
| **tdd-verifier** | Runs after each slice as blackbox validation — full test suite, static analysis, coverage check. Has no implementation context, only the code on disk | Read-only |
| **tdd-releaser** | Validates all slices are terminal, updates CHANGELOG, pushes branch, creates PR | Read-write (Bash only) |

A slice is one testable behavior — a C shim function, its Dart wrapper, and its test, bundled together. CLI examples get their own slices. The verifier runs proactively after each implementer slice, not just at the end.

### Layer 2: Session Roles

Each Claude Code instance runs in its own terminal with a dedicated role. The separation exists because Claude Code autocompacts conversation history as context fills. If architecture review and implementation share a session, the review history gets compacted away when build output fills the window. Isolating roles means:

- **CA** (Architect) keeps its full review history across multiple review cycles
- **CP** (Planner) keeps prior planning attempts and CA feedback across iterations
- **CI** (Implementer) keeps build output, test results, and refactoring decisions across all slices in a feature
- **CB** (Packaging) keeps cross-compilation research available without competing with other context

| Session | Runs these commands | Never does |
|---------|-------------------|------------|
| **CA** — Architect | (none — read-only for code) | Write code, run TDD commands, merge PRs |
| **CP** — Planner | `/tdd-plan` | Write code, make architecture calls |
| **CI** — Implementer | `/tdd-implement`, `/tdd-release` | Plan features, write memory |
| **CB** — Packaging | (advisory only) | Write code, run builds |

**Memory model:** CA is the sole writer to shared memory (`MEMORY.md` in the auto-memory directory). CP, CI, and CB read it but never write. Their outputs are all durable artifacts — plans in `planning/`, code in git, slice status in `.tdd-progress.md`. This eliminates state conflicts: one author, one truth.

**Feature lifecycle:** CA writes the issue and prompt -> CP runs `/tdd-plan` (spawns planner agent) -> CA reviews the plan -> CI runs `/tdd-implement` (spawns implementer + verifier per slice) -> CA verifies -> CI runs `/tdd-release` (spawns releaser) -> CA reviews PR.

### Key files

| What | Where |
|------|-------|
| Role skills (session initialization) | [`.claude/skills/role-{ca,ci,cp}/`](.claude/skills/) |
| Role prompts (full session docs) | [`docs/dev-roles/`](docs/dev-roles/) |
| TDD conventions and project rules | [`CLAUDE.md`](CLAUDE.md) |
| Phase specifications (source of truth) | [`development/phases/`](development/phases/) |
| Active TDD session state | `.tdd-progress.md` (when present) |
| Planning archive | [`planning/`](planning/) |
| Hooks experiment (2x2 matrix) | [`experiments/hooks-bundling/`](experiments/hooks-bundling/) |
| C shim audit (6 FFI barrier patterns) | [`docs/c-shim/`](docs/c-shim/) |

### Commands

```bash
# Bootstrap monorepo
fvm dart run melos bootstrap

# Run analysis
fvm dart analyze package

# Regenerate FFI bindings (after modifying src/zenoh_dart.h)
cd package && fvm dart run ffigen --config ffigen.yaml
```

## Phase Roadmap

| Phase | Name | Status |
|-------|------|--------|
| 0 | [Bootstrap](development/phases/phase-00-bootstrap.md) | **COMPLETE** |
| 1 | [Put / Delete](development/phases/phase-01-put-delete.md) | **COMPLETE** |
| 2 | [Subscribe](development/phases/phase-02-sub.md) | **COMPLETE** |
| 3 | [Publish](development/phases/phase-03-pub.md) | **COMPLETE** |
| 4 | [SHM Pub/Sub](development/phases/phase-04-shm-pub-sub.md) | **COMPLETE** |
| 5 | [Scout / Info](development/phases/phase-05-scout-info.md) | **COMPLETE** |
| 6 | [Get / Queryable](development/phases/phase-06-get-queryable.md) | |
| 7 | [SHM Get/Queryable](development/phases/phase-07-shm-get-queryable.md) | |
| 8 | [Channels](development/phases/phase-08-channels.md) | |
| 9 | [Pull](development/phases/phase-09-pull.md) | |
| 10 | [Querier](development/phases/phase-10-querier.md) | |
| 11 | [Liveliness](development/phases/phase-11-liveliness.md) | |
| 12 | [Ping/Pong](development/phases/phase-12-ping-pong.md) | |
| 13 | [SHM Ping](development/phases/phase-13-shm-ping.md) | |
| 14 | [Throughput](development/phases/phase-14-throughput.md) | |
| 15 | [SHM Throughput](development/phases/phase-15-shm-throughput.md) | |
| 16 | [Bytes](development/phases/phase-16-bytes.md) | |
| 17 | [Storage](development/phases/phase-17-storage.md) | |
| 18 | [Advanced](development/phases/phase-18-advanced.md) | |

## License

Apache 2.0 — see [LICENSE](LICENSE).
