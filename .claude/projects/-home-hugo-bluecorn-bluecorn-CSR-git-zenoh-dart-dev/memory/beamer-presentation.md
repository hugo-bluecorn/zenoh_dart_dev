# Beamer Presentation: zenoh-dart Status

## Location
- Kile project: `/home/hugo-bluecorn/Documents/zenoh/`
- Main file: `zenoh-status.tex`
- Theme: Madrid, 9pt base with `\normalsize` body fonts via `\setbeamerfont`

## Structure (~48 slides, 8 sections + title/agenda/thank you)

1. **Title + Agenda** (2 slides)
2. **ZettaScale Technology** (1 section title + 3 content) — company origin (ADLINK spinout 2022), Zetta Platform/Auto, milestones timeline
3. **What is Zenoh?** (1 section title + 16 content) — the problem, three paradigms, key expressions, comparison table, network roles + TikZ topology, transport layer (10 protocols), scouting & gossip, QoS/timestamps/SHM, router plugins, ROS 2 middleware, industrial adopters, real-world deployments, Zenoh-Pico, peer-reviewed papers, language ecosystem
4. **zenoh-dart: The Missing Binding** (1 section title + 2 content) — motivation slide, counter template validation (KISS, 3 repos, 3 topologies, spatial decoupling)
5. **How We Build It** (1 section title + 4 content) — two reference layers (zenoh-c = contract boundary, zenoh-cpp = structural peer), three-layer architecture TikZ, monorepo & dev cycle, zenoh-c examples roadmap (29 examples)
6. **What We Built** (1 section title + 4 content) — 18 classes API surface, pub/sub code example, SHM/discovery code example, cross-language interop TikZ
7. **Where We Are** (1 section title + 2 content) — completed phases table, what's next + companion projects
8. **Flutter Application Ideas** (1 section title "From Sensor to Screen" + 5 content) — 8 app concepts in single-column format (2 per slide × 4 slides) + why Flutter+Zenoh fit
9. **Summary** (1 slide) + **Thank You** (1 slide — CSR internship acknowledgment, Thibauld Jongen CEO & Finance, Herman Bruyninckx Science & Technology)

## Section Title Slides
Every section has a centered title/subtitle slide:
- ZettaScale Technology / "The company behind Zenoh"
- What is Zenoh? / "Unifying pub/sub, storage, and query in one wire protocol"
- zenoh-dart / "Building the missing binding from the ground up"
- How We Build It / "Two reference layers, one development cycle"
- What We Built / "18 classes, 7 CLI examples, and cross-language interop out of the box"
- Where We Are / "62 C shim functions, 185 tests, 7 phases complete"
- From Sensor to Screen / "Eight conceptual applications where a Flutter front-end meets a zenoh backbone"

## Key Design Decisions
- Author: "Bluecorn and Common Sense Robotics"
- Custom color `zenohblue` RGB(0,102,204) for structure elements
- TikZ diagrams for: architecture layers, network topology, cross-language interop, sensor-to-screen flow
- `\scriptsize` for tables, `\tiny` for paper citations
- lstlistings with Java language highlight for Dart code examples
- zenoh-c examples roadmap table shows all 29 examples mapped to implementation phases
- Flutter app ideas in single-column format (was two-column, overflowed)
- Narrative flow: motivation → approach → product → status → future → summary

## Font Sizing
- Final: 9pt base + `\setbeamerfont` body/itemize/subbody/description all at `\normalsize`, frametitle at `\normalsize`

## Research Sources Used
- zenoh.io/adopters (26+ organizations)
- Peer-reviewed papers: Liao et al. 2023 (arXiv), Diez et al. 2025 (Elsevier), RWTH Aachen 2025 (IEEE), ACM SAC 2025
- ZettaScale spinout PR (prnewswire 2022), Zetta Platform launch (June 2023), Zetta Auto/MotionWise (TTTech Auto)
- zenoh-c DEFAULT_CONFIG.json5 for protocol/scouting/routing details
- Industrial Flutter (industrialflutter.com), ARM Institute open-source teach pendant
- Counter template docs: counter-meta-plan.md, counter-app-architecture.md, counter-dart-design.md
