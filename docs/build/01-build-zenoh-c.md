# Build zenoh-c and C shim (Linux)

## Context

The `zenoh_dart` package has a `extern/zenoh-c` git submodule (v1.7.2, eclipse-zenoh/zenoh-c). zenoh-c is a C API wrapper around Rust zenoh — CMake orchestrates Cargo underneath. The root `CMakeLists.txt` is a superbuild that builds both zenoh-c and the C shim in one step.

## Prerequisites

| Tool | Minimum version | Tested version |
|------|----------------|---------------|
| clang/clang++ | any recent | 18.1.3 |
| cmake | 3.16+ (3.21+ for presets) | 3.28.3 |
| ninja | any | 1.11.1 |
| rustc/cargo | 1.85.0 (pinned) | 1.85.0 |

## Rust version constraint

zenoh-c 1.7.2's transitive dependency `static_init` 1.0.3 fails to compile on Rust >= 1.86 (unresolved `parking_lot` crate error). The superbuild preset pins `+1.85.0` via `ZENOHC_CARGO_CHANNEL`, which makes cargo invoke `cargo +1.85.0 build ...`. This overrides `extern/zenoh-c/rust-toolchain.toml` (which pins an unreleased channel).

Install with:
```bash
rustup toolchain install 1.85.0
```

## Superbuild (recommended)

The superbuild configures, builds, and installs everything in two commands:

```bash
cmake --preset linux-x64
cmake --build --preset linux-x64 --target install
```

This:
1. Builds zenoh-c from source via `add_subdirectory(extern/zenoh-c)` (cargo, automated)
2. Builds the C shim (`src/zenoh_dart.c`) against the `zenohc::lib` target
3. Installs both `.so` files to `packages/zenoh/native/linux/x86_64/` with `RPATH=$ORIGIN`

First build takes ~3 minutes (cargo). Subsequent builds are incremental (~2s for C shim-only changes).

### C shim only

If zenoh-c is already built and you only changed `src/zenoh_dart.{h,c}`:

```bash
cmake --preset linux-x64-shim-only
cmake --build --preset linux-x64-shim-only --target install
```

This uses 3-tier discovery to find the existing `libzenohc.so` (prebuilt in `native/` or developer fallback in `extern/zenoh-c/target/release/`).

## Manual build (advanced)

For building zenoh-c standalone without the superbuild (e.g., debugging cargo issues):

### 1. Configure

```bash
cmake \
  -S extern/zenoh-c \
  -B extern/zenoh-c/build \
  -G Ninja \
  -DCMAKE_C_COMPILER=/usr/bin/clang \
  -DCMAKE_CXX_COMPILER=/usr/bin/clang++ \
  -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=TRUE \
  -DZENOHC_BUILD_IN_SOURCE_TREE=TRUE
```

Key flags:
- `-DZENOHC_BUILD_IN_SOURCE_TREE=TRUE` — places `target/` inside the submodule (not a detached build dir)
- `-DBUILD_SHARED_LIBS=TRUE` — produces `libzenohc.so` (needed for FFI)

### 2. Build

```bash
RUSTUP_TOOLCHAIN=1.85.0 cmake --build extern/zenoh-c/build --config Release
```

### 3. Verify

```bash
# Check shared library
file extern/zenoh-c/target/release/libzenohc.so
# Expected: ELF 64-bit LSB shared object, x86-64

# Check exported symbols
nm -D extern/zenoh-c/target/release/libzenohc.so | grep "T z_" | wc -l
# Expected: ~477 symbols

# Check headers compile
clang -fsyntax-only -I extern/zenoh-c/include -xc - <<< '#include "zenoh.h"'
```

### 4. Run tests

```bash
RUSTUP_TOOLCHAIN=1.85.0 cmake --build extern/zenoh-c/build --target tests
ctest --test-dir extern/zenoh-c/build -R "^(unit|build)_" --output-on-failure
```

Expected: 12/14 pass. Two tests (`unit_z_api_alignment_test`, `unit_z_api_liveliness`) are known flaky due to timing-dependent assertions in the upstream zenoh-c test suite.

## Build artifacts

### Superbuild

| Artifact | Path |
|----------|------|
| Shared library (zenoh-c) | `build/linux-x64/extern/zenoh-c/release/target/release/libzenohc.so` |
| Shared library (C shim) | `build/linux-x64/src/libzenoh_dart.so` |
| Installed prebuilts | `packages/zenoh/native/linux/x86_64/libzenohc.so`, `libzenoh_dart.so` |

### Manual (standalone)

| Artifact | Path |
|----------|------|
| Shared library | `extern/zenoh-c/target/release/libzenohc.so` |
| Static library | `extern/zenoh-c/target/release/libzenohc.a` |
| Headers | `extern/zenoh-c/include/zenoh.h` (umbrella) |
| CMake build dir | `extern/zenoh-c/build/` |
| Cargo target dir | `extern/zenoh-c/target/` |

All build artifacts are in `.gitignore`.

## Clean build

```bash
# Superbuild
rm -rf build/linux-x64

# Manual (standalone)
rm -rf extern/zenoh-c/build extern/zenoh-c/target
```
