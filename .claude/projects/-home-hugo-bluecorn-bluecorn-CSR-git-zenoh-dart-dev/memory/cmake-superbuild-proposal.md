---
name: cmake-superbuild-proposal
description: Unified CMake superbuild proposal for zenoh-dart — replaces haphazard multi-step build with root CMakeLists.txt + presets
type: project
---

Proposal for unified CMake build system at `development/proposals/cmake-unified-build-system.md`. Pushed to main 2026-03-24, revised pass 2.

**Why:** Current build is 8 manual commands (build zenoh-c, build C shim, copy, patchelf) documented across CLAUDE.md. No root CMakeLists.txt. Android script disconnected from Linux flow.

**How to apply:**
- Root `CMakeLists.txt` uses `add_subdirectory(extern/zenoh-c)` to get `zenohc::lib` target directly (zenoh-c supports this natively via subdirectory mode)
- `CMakePresets.json` provides `linux-x64`, `linux-x64-shim-only`, `android-arm64`, `android-x86_64` presets
- `src/CMakeLists.txt` modified to dual-mode: uses `zenohc::lib` target (superbuild) or 3-tier discovery (standalone/Android)
- Linux: 2 commands (`cmake --preset linux-x64 && cmake --build --preset linux-x64 --target install`)
- Android: hybrid — `cargo-ndk` for Rust (Stage 1), cmake preset for C shim (Stage 2), cmake install for placement (Stage 3). Bash script still orchestrates.
- Install target handles copy + patchelf automatically
- Dart-side (native_lib.dart, hook/build.dart, ffigen, bindings.dart) completely untouched

**Key risks:**
1. `add_subdirectory(extern/zenoh-c)` from parent project is UNTESTED — must spike first
2. Root project needs `LANGUAGES C CXX` (zenoh-c requires both)
3. Android improvement is modest (preset cleanup only, cargo-ndk still required)

**Decision: KEEP `extern/cmake`** — 166MB CMake source repo serves as local RTFM reference for agents (no web bandwidth for CMake module lookups). Not used in build pipeline.

**Submodules (7 total):** zenoh-c, zenoh-cpp, zenoh-kotlin, zenoh-demos, cargo-ndk, zenoh, cmake

**Status:** COMPLETE. PR #20 merged (7aa1bd3). Docs updated (b680eb4). 193/193 tests pass.

**Discovery during implementation:** Rust 1.94 (current stable) breaks zenoh-c 1.7.2 — `static_init` 1.0.3's `parking_lot` resolution fails on Rust >= 1.86. Pinned to `+1.85.0` via `ZENOHC_CARGO_CHANNEL`. This is pre-existing (old manual builds only worked because of cached cargo artifacts). Proposal's `+stable` must be `+1.85.0`.
