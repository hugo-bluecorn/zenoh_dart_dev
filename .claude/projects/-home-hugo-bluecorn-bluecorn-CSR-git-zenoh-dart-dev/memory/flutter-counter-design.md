---
name: flutter-counter-design
description: zenoh-counter-flutter design decisions — MVVM, Riverpod 3.x, pure subscriber, network topology, risk items
type: project
---

## zenoh-counter-flutter Design (2026-03-12)

**Repo**: `/home/hugo-bluecorn/bluecorn/CSR/git/zenoh-counter-flutter/`
**Created**: `fvm flutter create -e zenoh_counter_flutter --org com.bluecorn`, renamed dir to kebab-case
**Branch**: `main`
**Design spec**: `docs/design/flutter-counter-design.md` (in flutter repo)
**Historical copy**: `development/design/flutter-counter-design-v2.md` (in zenoh-dart repo)

**Why:** This is a reference architecture template, not just a counter app. Proves package:zenoh works in Flutter, MVVM layering, Android deployment, and cross-device interop.

**How to apply:** All implementation decisions should trace back to this spec. CI uses it as the source of truth for slicing.

### Key Decisions
- **Pure subscriber** — no publisher code, C++ counter provides SHM stream
- **MVVM with Riverpod 3.x** (^3.3.1), NO codegen (no riverpod_annotation/generator/build_runner)
- **go_router** (^17.1.0) for navigation
- **shared_preferences** (^2.5.4) for endpoint persistence
- **very_good_analysis** (^10.2.0) for linting
- **Counter protocol**: key=`demo/counter`, payload=int64 LE, interval=1000ms
- **3 screens**: Connection, Counter, Settings
- **Only ZenohService imports package:zenoh** — clean boundary
- **No mocks** — real zenoh for service/repo tests, provider overrides for widget tests
- **Desktop**: peer mode (C++ pub listens, Flutter connects via TCP)
- **Android**: client mode via zenohd router (no multicast)
- **Run script**: `scripts/dev.sh` starts C++ pub (optionally with router)

### Risk Items
1. Flutter build hooks untested (only pure Dart consumer validated in PR #17)
2. `Isolate.resolvePackageUriSync()` may behave differently in Flutter
3. Android cross-compilation gaps for C shim
4. `DynamicLibrary.open()` path resolution on Android

### Dependency
- `zenoh: path: ../zenoh_dart/packages/zenoh` (relative path dep)
