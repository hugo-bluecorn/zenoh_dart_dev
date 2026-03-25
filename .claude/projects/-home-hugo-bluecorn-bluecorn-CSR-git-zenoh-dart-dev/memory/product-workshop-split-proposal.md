---
name: product-workshop-split-proposal
description: Product/workshop repo split proposal — zenoh_dart (product with package/ boundary) and zenoh_dart_dev (frozen archive)
type: project
---

Proposal for repository split at `development/proposals/product-workshop-split.md`. Pushed to main 2026-03-24, pass 3 with CA2 review.

**Why:** Current repo conflates product (Dart API, C shim, prebuilts) with workshop (phase docs, experiments, audits, LaTeX, 7 submodules). Melos is vestigial (no melos.yaml, one package). `packages/zenoh/` indirection unnecessary.

**How to apply:**
- Rename current repo to `zenoh_dart_dev` (frozen archive, full history)
- Create fresh `zenoh_dart` with `package/` directory as publish boundary
- `package/` contains publishable Dart package (lib/, hook/, native/, example/, test/, pubspec.yaml)
- Build infrastructure at repo root (src/, extern/zenoh-c, CMakeLists.txt, scripts/)
- No `.pubignore` needed — structural allow-list
- Single submodule (extern/zenoh-c only)
- Drop Melos, drop workspace, flat pubspec in package/
- Eliminate jniLibs intermediate — cargo-ndk outputs directly to package/native/android/

**Execution: CI direct-edit task (not TDD)**
- Recommended after CMake superbuild completes (avoids double path-rewriting)
- But not a hard dependency — works with existing standalone build
- 15 execution steps, verification gate: 193 tests pass from package/

**Status:** Proposal approved by CA2. Not yet implemented.
