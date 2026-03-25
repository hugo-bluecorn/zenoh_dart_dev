# Counter Meta Plan (2026-03-07)

## Strategy
Three separate repos, each validating one concern, each serving as a template for its category.

## Repos (in implementation order)

### 1. zenoh-counter-dart -- COMPLETE (v0.1.0, 2026-03-07)
- **GitHub**: `hugo-bluecorn/zenoh-counter-dart`
- **Result**: 29 tests (18 unit + 11 integration), 5 TDD slices, all 3 topologies verified
- **Contents**: counter_pub.dart (SHM publisher), counter_sub.dart (subscriber), shared codec + args
- **Validated**: Session, Publisher, Subscriber, ShmProvider, ShmMutBuffer, payloadBytes, CLI flags
- **Dependency**: `package:zenoh` via git ref (`hugo-bluecorn/zenoh_dart.git`, underscore!)
- **Native lib approach**: A (manual LD_LIBRARY_PATH)
- **Docs**: README, user-manual.md with Mermaid diagrams, CLAUDE.md, role docs in context/roles/

### 2. zenoh-counter-cpp (SECOND)
- **Purpose**: C++ SHM publisher — proves cross-language interop (C++ SHM → Dart subscriber)
- **Based on**: hugo-bluecorn/claude-cpp-template (GitHub template repo)
- **Contents**:
  - `include/counter/state_machine.hpp` — state machine (from xplr cpp_app)
  - `src/state_machine.cpp` — implementation
  - `app/counter_pub.cpp` — SHM publisher CLI
  - `tests/test_state_machine.cpp` — GoogleTest unit tests
  - zenoh-cpp as dependency (submodule in `ext/` or FetchContent)
- **Validates**: C++ SHM publish, Dart transparent SHM receive, binary payload compatibility
- **Key benefit**: tdd-tsan preset catches concurrency bugs in mutex-protected state machine

### 3. zenoh-counter-flutter (THIRD)
- **Purpose**: Flutter counter app — proves Flutter + zenoh on desktop and Android
- **Contents**: Flutter app with ZenohService, CounterRepositoryImpl, Riverpod UI
- **Dependency**: `package:zenoh` via git ref (Approach A initially, refactor to B later)
- **Validates**: Flutter desktop + Android, native lib placement, cross-platform deployment
- **Native lib approach**: Start with A (manual .so in jniLibs), then refactor to B (zenoh_flutter plugin)

## Cross-Repo Interop
- Dart subscriber from repo 1 works unchanged with C++ publisher from repo 2
- Flutter subscriber from repo 3 works unchanged with either publisher
- The subscriber doesn't know or care whether publisher is Dart or C++ — zenoh transparency

## Each Repo Gets
- Own CLAUDE.md with project-specific instructions
- Own CA/CP/CI role docs in context/roles/ (scoped to that project type)
- Own lessons-learned.md (living doc, populated during development)
- These become the template material for future projects

## Native Library Distribution Progression
- **Now**: Approach A — manual LD_LIBRARY_PATH (Dart CLI), manual jniLibs (Flutter)
- **After Flutter MVP**: Approach B — zenoh_flutter plugin package in zenoh-dart monorepo
- **Long term**: Approach C — native_assets hook/build.dart (when native_toolchain_cmake lands)

## Dependencies
- All three repos depend on zenoh-dart (package:zenoh) being at Phase 5+ (DONE)
- Repo 2 depends on zenoh-cpp headers (submodule from extern/zenoh-cpp in zenoh-dart, or independent)
- Repo 3 depends on learnings from repos 1 and 2
- zenoh-dart Phase 6+ (Get/Queryable) is independent and can proceed in parallel

## Template Value
Each repo is designed to be copied as a starting point for real applications:
- zenoh-counter-dart → any Dart CLI + zenoh + SHM project
- zenoh-counter-cpp → any C++ + zenoh-cpp + SHM project (via claude-cpp-template)
- zenoh-counter-flutter → any Flutter + zenoh app (desktop + Android)
