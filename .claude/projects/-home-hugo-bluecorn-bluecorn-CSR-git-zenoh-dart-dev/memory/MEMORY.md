# Memory Index

## Session Context
- User operates three-session workflow: CA (architect/reviewer), CP (planner), CI (implementer). Skills at `.claude/skills/role-{ca,cp,ci}/`
- CC (plain session in prod repo zenoh_dart) and CA2 (independent reviewer) used ad-hoc — no role skills
- `/rsync` skill spawns background agent to sync dev→prod and verify (193 tests)
- CA is sole memory writer; CP, CI read only
- This project uses fvm: Flutter 3.41.4, Dart 3.11.1
- Clang ecosystem throughout (CMake + Clang on Linux, NDK Clang on Android)
- FVM is the ONLY way to run dart/flutter — bare `dart`/`flutter` NOT on PATH

## Milestones
- **2026-03-11: The @Native saga ended over electric beers.** Three repos, one root cause, zero LD_LIBRARY_PATH. Cheers.
- **2026-03-12: The trilogy is complete.** C++ SHM publisher → zenohd router → WiFi hotspot → Pixel 9a → Flutter app → real-time counter. Full stack validated on real hardware. Build hooks bundle .so into APK, bare DynamicLibrary.open works on Android.
- **2026-03-24: Repo split done.** zenoh_dart (product, `package/` layout) + zenoh_dart_dev (workshop). 193/193 tests pass.
- **2026-03-25: Dev restructured to match prod.** `packages/zenoh/` → `package/`, Melos dropped, jniLibs eliminated, `native_lib.dart` Flutter desktop fix (bare DynamicLibrary.open fallback). Sync script `scripts/sync-to-prod.sh` created. Both repos 193/193 tests pass.

## User Preferences
- **Always show full TDD plans** — never present just a summary. Show the complete slice decomposition with all Given/When/Then, acceptance criteria, and phase tracking before asking for approval.
- **Faithful to zenoh-c/zenoh-cpp naming** — CLI flags, method names, and API surface should mirror the C/C++ zenoh conventions as closely as possible.
- **`context/` for Claude files, `docs/` for non-Claude files** — in counter repos, role docs go in `context/roles/`, planning/design goes in `docs/`. NOT `docs/dev-roles/` like zenoh-dart.
- **Use `very_good_analysis`** for linting in new projects (zenoh-dart still uses `lints` package).
- **Iterative proposal refinement** — Do 2-3 revision passes on proposals/design docs. First pass generates from research; subsequent passes catch gaps from the concrete artifact. See `memory/feedback_iterative_proposals.md`.
- **Revision cycle end detection** — Stop when findings shift from structural to execution-time details. "Add a note" fixes signal diminishing returns. See `memory/feedback_revision_cycles.md`.

## Repositories
- **zenoh_dart_dev** (workshop): `/home/hugo-bluecorn/bluecorn/CSR/git/zenoh_dart_dev/` — GitHub: `hugo-bluecorn/zenoh_dart_dev`
  - `package/` layout (matching prod), all 7 submodules, phase docs, experiments, audits, dev roles
  - Active development happens here. Code syncs to prod via `scripts/sync-to-prod.sh`
- **zenoh_dart** (product): `/home/hugo-bluecorn/bluecorn/CSR/git/zenoh_dart/` — GitHub: `hugo-bluecorn/zenoh_dart`
  - `package/` layout (publish boundary), single submodule (extern/zenoh-c), no Melos
  - Clean product repo. Receives code from dev via sync script. No direct commits.

## Project: zenoh-dart
- **Status**: Phases 0–5 + P1 ALL COMPLETE. 62 C shim functions, 193 tests. **Repo split COMPLETE (2026-03-24)**: product/workshop separated, 193/193 tests pass in new layout.
- **Dart API classes (18)**: Zenoh, Config, Session, KeyExpr, ZBytes, Publisher, Subscriber, Sample, SampleKind, Encoding, CongestionControl, Priority, ShmProvider, ShmMutBuffer, ZenohId, WhatAmI, Hello, ZenohException
- **CLI examples (7)**: z_put.dart, z_delete.dart, z_sub.dart, z_pub.dart, z_pub_shm.dart, z_info.dart, z_scout.dart (all support -e/--connect, -l/--listen)
- **Next phase**: Phase 6 (Get/Queryable). No design doc yet.

### Key Decisions
- **Pure Dart package** (not Flutter plugin) — works with Serverpod, CLI, any Dart runtime
- **Melos dropped**: Removed during repo split. Single `package/pubspec.yaml`, no workspace.
- **No `zenoh_flutter` needed**: Pure Dart FFI package works directly with Flutter — no separate Flutter plugin package required
- **Naming**: Dart package = `zenoh`, native C shim = `zenoh_dart` (avoids zenoh.h collision)
- **All commands via fvm**: `fvm dart`, `fvm flutter`
- **CLI examples in `example/`** — pub.dev convention (moved from `bin/` in 2cfdc1f)

## Project Architecture
- Three-layer: C shim (src/) → generated FFI bindings → idiomatic Dart API (package/lib/src/)
- DynamicLibrary.open() loading: ensureInitialized() resolves path via Isolate.resolvePackageUriSync(), falls back to bare DynamicLibrary.open() for Flutter desktop (RUNPATH=$ORIGIN/lib), then Android bare open. Build hooks bundle for distribution only.
- zenoh-c v1.7.2 submodule in extern/zenoh-c
- 7 submodules: zenoh (v1.7.2, for zenohd router), zenoh-c, zenoh-cpp, zenoh-kotlin, zenoh-demos, cargo-ndk (v4.1.2), cmake (v4.3.0-dev, RTFM reference only)

## Key Patterns (established in Phases 0-5)
- **NativePort callback bridge**: C shim stores Dart_Port in heap-allocated context struct, posts Dart_CObject array via Dart_PostCObject_DL. Context freed in closure _drop callback. Used by Subscriber and Publisher matching listener.
- **Dart_CObject format (subscriber)**: [keyexpr(string), payload(Uint8List), kind(int64), attachment(null|Uint8List), encoding(string)]
- **Flattened C shim params**: sentinels (-1 for default enums, NULL for optional strings/bytes). Never two functions for same operation.
- **Entity lifecycle**: sizeof → declare → loan → operations → drop/close. Idempotent close, StateError after close.
- **Two-session testing**: Peer-mode multicast unreliable in single process. Tests use explicit TCP listen/connect with unique ports per group.
- **String-passthrough encoding**: Pure Dart Encoding class, C shim receives const char*, calls z_encoding_from_str() internally.
- **QoS enums**: CongestionControl (block=0, drop=1), Priority (realTime=1..background=7, Dart index+1 = zenoh-c value).
- **Non-broadcast StreamController**: Single-subscription for subscriber and matching listener streams.
- **tdd-finalize-docs**: Guide in CLAUDE.md tells doc-finalizer exactly which sections to update. Verified working in Phase 3.
- **SHM feature guards**: All SHM C shim functions guarded with `#if defined(Z_FEATURE_SHARED_MEMORY) && defined(Z_FEATURE_UNSTABLE_API)`. CMakeLists.txt adds both `-DZ_FEATURE_SHARED_MEMORY -DZ_FEATURE_UNSTABLE_API`. zenoh-c must be rebuilt with `-DZENOHC_BUILD_WITH_SHARED_MEMORY=TRUE -DZENOHC_BUILD_WITH_UNSTABLE_API=TRUE`.
- **SHM alloc returns nullable**: `ShmProvider.alloc()` and `allocGcDefragBlocking()` return `ShmMutBuffer?` (null on failure), not throwing. Design doc said throw but plan revised to nullable — approved and implemented.
- **SHM zero-copy pattern**: alloc buffer → write via `buf.data.asTypedList(buf.length).setAll(0, data)` → `buf.toBytes()` (consumes buffer) → `publisher.putBytes(zbytes)`.
- **Scout NativePort pattern**: C shim posts [zid(Uint8List), whatami(int64), locators(string joined by ';')] per Hello, then null sentinel on completion. Dart side uses ReceivePort + Completer to collect into List<Hello>.
- **Synchronous ZID collection**: Session.routersZid/peersZid use buffer-based C closure (not NativePort). C shim fills caller-provided buffer (16 bytes × max_count), returns count.
- **Pure Dart ZenohId.toHexString**: Does hex conversion in Dart (no FFI call), even though zd_id_to_string exists in C shim. Simpler, no overhead.
- **Build hooks + DynamicLibrary.open() (post-interprocess-fix)**: `hook/build.dart` registers two CodeAssets for distribution. Actual loading uses `DynamicLibrary.open()` with class-based `ZenohDartBindings(DynamicLibrary)` — NOT @Native annotations. `ensureInitialized()` resolves path via `Isolate.resolvePackageUriSync()`, prefers `native/linux/x86_64/` over `.dart_tool/lib/`, falls back to bare `DynamicLibrary.open('libzenoh_dart.so')` for Flutter desktop (RUNPATH=$ORIGIN/lib). On Android, bare open only. @Native reverted because its `NoActiveIsolateScope` + lazy resolution caused inter-process TCP crashes. No LD_LIBRARY_PATH needed.

## Known Issues
- **FIXED — Android native lib gap (2026-03-12)**: native_lib.dart, hook/build.dart, and cross-compilation were Linux-only. Fixed on branch `feature/android-native-lib`: Platform.isAndroid short-circuit, target-aware hook, build script cross-compiles C shim. SHM excluded on Android (CMakeLists.txt `if(NOT ANDROID)`). Validated E2E on Pixel 9a: C++ SHM pub → router → WiFi → Flutter subscriber. See `memory/android-native-lib-gap.md`.
- **FIXED — @Native inter-process crash (2026-03-11)**: PR #19 MERGED. Reverted @Native to DynamicLibrary.open(). 193 tests. Post-merge tasks ALL DONE and pushed:
  - zenoh-counter-dart: LD_LIBRARY_PATH removed, dep updated to v0.6.2, status table updated, 29/29 tests pass, manual Dart-to-Dart pub/sub verified
  - zenoh-counter-cpp: LD_LIBRARY_PATH removed from interop scripts + CLAUDE.md, template README replaced with real content, implementer memory updated, both peer/router interop tests pass, manual C++-to-Dart verified
  - Zero LD_LIBRARY_PATH instructions remain across all three repos
- **Lesson learned — @Native is broken for Rust cdylib with tokio**: Do NOT use `@Native` ffi-native annotations with libraries containing Rust/tokio runtimes. The `NoActiveIsolateScope` thread detachment during dlopen causes tokio's waker vtable to fail on inter-process TCP connections. Use `DynamicLibrary.open()` with class-based bindings instead. Filed as potential Dart SDK bug (`dart-lang/sdk#50105` related). Dart SDK source at `extern/dart-sdk/runtime/lib/ffi_dynamic_library.cc:348-412`.
- **Style inconsistency**: zenoh.dart:32 uses calloc.free for malloc'd memory — works but inconsistent with config.dart pattern. Cosmetic only.
- **Default branch was wrong**: Was set to `feature/phase0-bootstrap` instead of `main`. Fixed 2026-03-07. Caused GitHub merge-base confusion (PR #10 DIRTY state). Always verify default branch is `main` after initial repo setup.
- **Delete feature branches after merge**: Stale remote feature branches cause GitHub merge-base issues. Delete immediately after PR merge.
- **FIXED — native_lib.dart Flutter desktop (2026-03-25)**: `_resolveLibraryPath()` returned null in Flutter desktop (Isolate.resolvePackageUriSync unsupported, CWD probing misses bundle). Added bare `DynamicLibrary.open('libzenoh_dart.so')` fallback — Flutter runner's RUNPATH=$ORIGIN/lib resolves it. Fix in both repos.
- **Android armeabi-v7a prebuilts missing**: Build hook fails for 32-bit ARM ABI. Workaround: `fvm flutter build apk --debug --target-platform android-arm64`. Not urgent — armeabi-v7a is legacy (pre-2015 phones).

## Design Documents (in `development/design/`)
- `cross-cutting-patterns.md` — Encoding, QoS, Attachment, Options mapping, Entity lifecycle, NativePort, Sample evolution, Testing conventions
- `phase-03-pub-revised.md` — Publisher spec (IMPLEMENTED)
- `phase-04-shm-revised.md` — 13 C shim functions (guarded by SHM flags), ShmProvider/ShmMutBuffer (IMPLEMENTED). Defers receive-side SHM detection, immutable buffer, aligned alloc to Phase 4.1
- `phase-05-scout-info-revised.md` — 6 C shim functions, ZenohId/WhatAmI/Hello, Zenoh.scout() + Session.zid/routersZid/peersZid (IMPLEMENTED)
- `dart-client-integration-testing.md` — 4-tier test architecture (Tier 1 in-process, Tier 2 router, Tier 3 E2E, Tier 4 Flutter)
- `flutter-counter-app-design.md` — Counter app migration plan from xplr
- ~~`flutter-package-analysis.md`~~ → moved to `experiments/hooks-bundling/prior-analysis.md` (superseded by hooks decision)
- `xplr-counter-migration-analysis.md` — Analysis of existing xplr FFI approach

## Audit & Reviews (in `development/reviews/`)
- `audit-phases-0-5-vs-zenoh-c-cpp.md` — Full audit of Phases 0-5 against zenoh-c structs + zenoh-cpp API (544fb3f). All pass, no blockers.

## C Shim Audit Documents (in `development/c-shim/`)
- **Three source documents** (produced by CA and CC sessions, kept for provenance):
  - `CA-C_shim_proof.md` — Patterns A-D (4 patterns), symbol table proofs, z_put end-to-end trace
  - `CA-C_shim_audit.md` — Function-by-function analysis, ownership model, thread safety, findings F1-F5
  - `CC-C_shim_audit.md` — Added Pattern 4 (callbacks/NativePort), Pattern Resolution Matrix, findings C-14/C-16
- **`C_shim_audit.md`** — Synthesized single document superseding all three. 5 parts (A-E), 7 findings (F1-F7), all refs verified against Dart 3.11.1.
- **`latex/C_shim_audit.tex`** — Expert LaTeX article version (23 pages, 485KB PDF). Kile-editable. Uses: listings (C/Dart/shell/YAML syntax), tcolorbox (finding/pattern/quote callouts), booktabs+tabularx, longtable (62-row pattern resolution matrix), hyperref, fancyhdr, sourcecodepro font, title page with metadata table.
  - **Clean build**: Zero warnings/errors after extensive overfull/underfull hbox fixes.
  - **LaTeX fix patterns used**: `\allowbreak{}` for monospace identifiers, `\-` hyphenation hints, `lcL` tabularx columns for conformance tables, `\footnotesize` for dense tables, rewording paragraphs starting with long `\fn{}` names, reformatting inline lists to `\begin{itemize}`.
- **Five FFI barrier patterns documented** (after deduplication across CA+CC sources):
  1. `static inline` move functions (56 functions, no exported symbols)
  2. C11 `_Generic` polymorphic macros (4 macros, 25-56 branches each)
  3. Options struct initialization (compound barrier with P1)
  4. Opaque type sizes (Dart FFI has no sizeof for foreign types)
  5. Closure callbacks across thread boundaries (NativePort bridge)
- **Six FFI barrier patterns** (corrected from 5 after discovering `development/reviews/c-shim-audit.md` listed 6):
  1. `static inline` move functions (34 shim functions)
  2. C11 `_Generic` polymorphic macros (14 shim functions)
  3. Options struct initialization (8 shim functions)
  4. Opaque type sizes (12 shim functions)
  5. Closure callbacks across thread boundaries (6 shim functions)
  6. **Loaning and const/mut enforcement** (8 shim functions) — per-type loan functions ARE exported symbols, but `z_loan`/`z_loan_mut` macros are not, AND Dart's `Pointer<Opaque>` erases const qualifier

## Counter App Context
- **Meta plan**: Three separate repos, each a template for its category. See `counter-meta-plan.md`.
  1. **zenoh-counter-dart** — COMPLETE (v0.1.1). GitHub: `hugo-bluecorn/zenoh-counter-dart`. 29 tests, 5 slices, manually verified all 3 topologies.
  2. **zenoh-counter-cpp** — COMPLETE (v0.2.0, 2026-03-09). GitHub: `hugo-bluecorn/zenoh-counter-cpp`. PR #1 merged. ShmCounterPublisher with RAII, SHM zero-copy int64 LE publish, CLI with -k/-e/-l/-i flags, signal handling, two-session TCP tests, sanitizer-clean.
  3. **zenoh-counter-flutter** — VALIDATED ON HARDWARE (2026-03-12, re-validated 2026-03-25 with debug APK). Location: `/home/hugo-bluecorn/bluecorn/CSR/git/zenoh-counter-flutter/`. Pure Flutter subscriber, MVVM + Riverpod 3.x, desktop Linux + Android. E2E validated: C++ SHM pub → zenohd → WiFi → Pixel 9a → Flutter counter. Dep path updated to `../zenoh_dart/package`. `scripts/dev.sh` uses `ZENOH_DART_DEV` for zenohd path. See `memory/flutter-counter-design.md`.
- **zenoh-counter-cpp decisions (2026-03-09)**:
  - No state machine — just simple incrementing publish loop (matches Dart counter_pub simplicity)
  - Header/source separation: `include/counter/publisher.hpp` + `src/publisher.cpp`
  - Own submodules in `ext/` (not shared with zenoh-dart)
  - Role docs reference `context/standards/` from template (not inline C++ guidelines)
  - Starter memory seeded at `~/.claude/projects/-home-hugo-bluecorn-bluecorn-CSR-git-zenoh-counter-cpp/memory/MEMORY.md`
  - Location: `/home/hugo-bluecorn/bluecorn/CSR/git/zenoh-counter-cpp/`
- **zenoh-counter-cpp completed (2026-03-09)**: 6 slices all done. CMake integration, ShmCounterPublisher (session+declare+SHM publish), two-session TCP tests, CLI with signals, publish loop. PR #1 merged to main.
- **Native lib progression**: ~~A→B→C~~ **REVISED 2026-03-09: Go straight to C (hooks)**. Build hooks stable since Dart 3.10, plugin_ffi deprecated-in-spirit, sqlite3 already migrated. No `zenoh_flutter` package needed — hooks go directly in `package/`. Design doc: `experiments/hooks-bundling/design.md`.
- **Hooks experiment design (CA, 2026-03-10)**: Scientific 2x2 matrix approach. See `memory/hooks-experiment-design.md` for full details.
  - **Dimension 1**: Build strategy — both-prebuilt vs CBuilder+prebuilt
  - **Dimension 2**: Loading mechanism — DynamicLibrary.open() vs @Native annotations
  - 4 experiment packages: exp_hooks_prebuilt_dlopen (A1), exp_hooks_prebuilt_native (A2), exp_hooks_cbuilder_dlopen (B1), exp_hooks_cbuilder_native (B2)
  - Control: `packages/zenoh/` untouched
  - **Critical finding**: `DynamicLibrary.open()` does NOT auto-find hook-bundled assets. `@Native` annotations resolve via asset ID mapping. This is why loading mechanism is a separate variable.
  - **RPATH**: Linux must set `$ORIGIN` at compile time (our CMake already does). Post-hoc patchelf unreliable.
  - **native_toolchain_c is EXPERIMENTAL** — affects B1/B2 stability
  - **cbl-dart**: Production-proven two-library precedent using CBuilder+prebuilt (our Approach B)
  - Packages: `hooks` ^1.0.0, `code_assets` ^1.0.0 (in deps, NOT dev_deps). `native_toolchain_c` ^0.17.5 only for B1/B2.
  - **Execution**: Sequential single-cohort A1→A2→B1→B2. Plain branches, no worktrees. /tdd-release creates branch + PR to main per experiment.
  - **Specs**: All 4 complete at `experiments/hooks-bundling/spec-{a1,a2,b1,b2}-*.md`. README.md renders on GitHub. Pushed to main.
  - **A1 COMPLETE (2026-03-10)**: NEGATIVE result — `DynamicLibrary.open()` incompatible with hooks. Hook registers metadata but ld.so can't read it. Only `@Native` reads hook metadata. Branch `experiment/a1-prebuilt-dlopen`, 4 commits, 7 tests (2 pass, 5 skip). Also found: prebuilt .so has absolute RUNPATH (need patchelf for A2).
  - **A2 COMPLETE (2026-03-10)**: POSITIVE result — @Native + @DefaultAsset works. 9/9 tests pass, no LD_LIBRARY_PATH. CodeAsset name must be bare relative path (auto-prefixed). RUNPATH=$ORIGIN via patchelf mandatory. PR #14 merged.
  - **B1 COMPLETE (2026-03-10)**: NEGATIVE result — confirms loading mechanism is the independent variable. CBuilder works (~1s cold, auto RUNPATH=$ORIGIN, 15 vendored headers). PR #15 merged.
  - **B2 COMPLETE (2026-03-10)**: POSITIVE result — CBuilder + @Native works. 10/10 tests pass. PR #16 merged.
  - **ALL 4 EXPERIMENTS COMPLETE**: A1 neg, A2 pos, B1 neg, B2 pos. Conclusion: @Native mandatory, build strategy irrelevant. PRs #13-#16 all merged.
  - **Consumer test PASS** (PR #17): External `dart create -t console` app with path dep on A2 — hooks fire transitively, @Native resolves from consumer context, no LD_LIBRARY_PATH. Methodology gap closed.
  - **Synthesis**: `experiments/hooks-bundling/synthesis.md` — full analysis, recommends A2 (prebuilt + @Native) for migration.
  - **Migration spec**: `experiments/hooks-bundling/spec-migration.md` — 12-step procedure for packages/zenoh/. Key: ffigen `ffi-native` config, 84 call sites across 10 files, 185 tests must pass without LD_LIBRARY_PATH. Branch: `feature/hooks-migration`.
  - **Migration COMPLETE (PR #18)**: 5 commits, 12-step spec executed. @Native + prebuilt (A2 approach). 185/185 tests pass without LD_LIBRARY_PATH. Bonus: fixed flaky z_sub_cli test (subprocess z_put → in-process put). CA reviewed, approved.
  - Two-library dependency problem SOLVED: dart-lang/native#190 closed, Flutter PR #153054 merged
  - FVM: Flutter 3.41.4 / Dart 3.11.x
- **xplr project**: `/home/hugo-bluecorn/bluecorn/CSR/git/dart_zenoh_xplr` — exploration project (architecture incompatible, must reimplement)
- **C++ template**: `https://github.com/hugo-bluecorn/claude-cpp-template.git` — Modern C++20, CMake 3.28+, GoogleTest, sanitizers, clang tooling.
- **Design docs**: `flutter-counter-app-design.md`, `flutter-package-analysis.md` (superseded), `hooks-native-bundling.md` (current), `dart-client-integration-testing.md`, `xplr-counter-migration-analysis.md`
- **Router (zenohd)**: `cd extern/zenoh && RUSTUP_TOOLCHAIN=stable cargo build --release --package zenohd`
- **zenohd also at**: `/home/hugo-bluecorn/bluecorn/CSR/git/dart_zenoh_xplr/extern/zenoh/target/release/zenohd`

## Cross-Project CA Role
- This CA session (zenoh-dart) also serves as **oversight CA for zenoh-counter-cpp**.
- The zenoh-counter-cpp repo has its own project-local CA, but this session retains the cross-project architectural context (counter protocol, interop requirements, meta-plan progression).
- After `/clear`, this session resumes as the zenoh-dart CA with cross-project oversight duties.
- Coordinate with the zenoh-counter-cpp CA on: plan review, interop verification, lessons learned.

## Key Research Files (in memory dir)
- `new-project-plan.md` — Full scaffold plan for zenoh-dart monorepo
- `phase-coordination.md` — Phase 0/P1/1 coordination analysis
- `cb-packaging-research.md` — Complete packaging/distribution research
- `tdd-finalize-docs-audit.md` — Full audit of doc finalizer for zenoh-dart
- `counter-app-architecture.md` — Counter template project architecture (separate repo, 3 topologies, SHM strategy)
- `counter-meta-plan.md` — Three-repo meta plan: zenoh-counter-dart → zenoh-counter-cpp → zenoh-counter-flutter
- `prior-analysis.md` (at `experiments/hooks-bundling/`) — zenoh_flutter vs pure Dart vs native_assets analysis. Two-library problem. **SUPERSEDED** by hooks decision (2026-03-09).
- `hooks-native-bundling.md` — Comprehensive design doc for Dart build hooks approach. Both-prebuilt strategy, CodeAsset API, reference projects, implementation plan (H1-H4).
- `beamer-presentation.md` — Kile/Beamer presentation at `/home/hugo-bluecorn/Documents/zenoh/zenoh-status.tex`. 35 slides, Madrid theme, 10 sections. Full structure, font sizing history, research sources.
- `c-shim-audit.md` — C shim audit document details: synthesis process, LaTeX production, five FFI barrier patterns, open 6th-pattern question.
- `android-native-lib-gap.md` — Android native lib loading gap: three fixes needed (native_lib.dart, hook, cross-compilation). Discovered 2026-03-12.
- `android-shm-conditional.md` — Full Android SHM analysis: upstream blocker (POSIX shm_open missing in Bionic), four-layer exclusion workaround, how SHM works today (Linux vs Android transparent fallback), what upstream/local changes needed if zenoh adds Android SHM support.
- `android-shm-ipc-research.md` — Proposed zenoh-counter-shm-android monorepo using Android-native ASharedMemory (independent from zenoh SHM): writer + 2 readers, AIDL fd sharing, Dart FFI mmap.
- `cmake-superbuild-proposal.md` — Unified CMake superbuild: COMPLETE (PR #20 merged). Root CMakeLists.txt + presets, `add_subdirectory(extern/zenoh-c)`. Rust pinned to +1.85.0 (>=1.86 breaks zenoh-c 1.7.2).
- `product-workshop-split-proposal.md` — Repo split: zenoh_dart (product, package/ boundary) + zenoh_dart_dev (workshop). **COMPLETE (2026-03-24).**
- ~~`split-handoff.md`~~ — Deleted (one-time use, split complete).
- ~~`split-execution-prompt.md`~~ — Deleted (one-time use, split complete).
- `split-rationale.md` — Why the dev/prod split exists: AI-assisted development generates too many artifacts for a product repo.
- Dev restructured to match prod layout (2026-03-25). Sync via `scripts/sync-to-prod.sh`. Proposal: `development/proposals/dev-prod-sync.md` **COMPLETE.**
