# Counter App Architecture Assessment (2026-03-07)

## Purpose
Template project for Flutter + C++ + Zenoh + SHM applications. The counter is the vehicle; the real deliverable is a reusable pattern.

## Goals
1. Most basic SHM + Zenoh example
2. Desktop + Android developed together (prove Flutter cross-platform with zenoh)
3. Capture "what works, what doesn't, lessons learned, gotchas" as reference material
4. CA/CP/CI role docs scoped to the counter project serve as template for future apps
5. KISS / MVP

## Repository Structure (Proposed)
Separate repo from zenoh-dart. Future projects copy this repo as starting point.

```
zenoh-counter/
  apps/
    flutter_counter/              # Flutter app (desktop + Android)
    cpp_counter/                  # C++ counter (SHM publisher)
  scripts/
    start-zenoh.sh
    build_cpp.sh
  docs/
    dev-roles/                    # CA/CP/CI prompts (counter-specific)
    lessons-learned.md            # living doc
    topology.md                   # deployment diagrams per platform
  CLAUDE.md
  README.md
```

Flutter app depends on package:zenoh via git ref.

## SHM Strategy
- C++ side: always publishes via SHM (that's the template's purpose)
- Dart/Flutter side: standard subscriber (transparent SHM receive, Phase 4 proved this)
- 8-byte int64 counter payload is fine for MVP; pattern scales to any size

## Three Topologies (All MVP)

| Topology | C++ | Flutter | Router | SHM? |
|----------|-----|---------|--------|------|
| Desktop + router | client -> router | client -> router | yes | yes (same machine) |
| Desktop peer | peer, listens TCP | peer, connects | no | yes (same machine) |
| Android + router | client -> router (desktop) | client -> router (WiFi) | yes | no (cross-machine) |

## Key Constraints
- SHM only works same-machine (shared memory = local IPC)
- Android: no reliable UDP multicast, must use client mode + explicit TCP
- SHM degrades gracefully to standard transport on Android (no code change needed)

## C++ Counter (from xplr)
- StateMachine: stopped -> playing -> paused -> stopped
- Publishes int64 on demo/counter (when playing)
- Publishes JSON state on demo/control/state
- Subscribes to JSON commands on demo/control/command
- Already supports -e/--connect, --no-multicast-scouting
- Needs: SHM publish path, -l/--listen flag

## Flutter App (from design doc)
- ZenohService wraps all zenoh calls (no isolates needed, NativePort)
- CounterRepositoryImpl decodes payloadBytes as little-endian int64
- Domain + UI layers copied from xplr with minimal changes
- Riverpod state management

## Open Question (2026-03-07)
Whether to implement a zenoh_flutter package (in zenoh-dart monorepo) vs using
package:zenoh directly. zenoh-dart monorepo was originally structured for this
split. Research in progress — see flutter-package-analysis.md when complete.
