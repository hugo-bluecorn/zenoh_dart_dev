# tdd-finalize-docs Audit for zenoh-dart

## Date: 2026-03-05

## What the Agent Did (Phase 2)

### CHANGELOG.md (from tdd-releaser, not doc-finalizer)
- Comprehensive entry: all new classes, C shim functions, CLI, test count. Good.

### CLAUDE.md (from doc-finalizer, commit 106381c)
- Added Phase 2 status line
- Added Zenoh, Subscriber, Sample, SampleKind to API classes list
- Caught missing Zenoh class from Phase 1 docs — good bonus fix
- Updated "Phases 2-18" → "Phases 3-18"
- Added z_sub CLI example with LD_LIBRARY_PATH
- **Verdict: Good job**

### README.md (from doc-finalizer, commit 106381c)
- Added Phase 2 status block with technical details
- Updated architecture diagram line with new classes
- Marked Phase 2 COMPLETE in roadmap table
- Added z_sub CLI example
- **Verdict: Good job**

## Problems Identified

### 1. Plugin-centric design doesn't fit consumer projects

Agent definition Step 2 categorization:
- "New agent added" → README agents table
- "New skill added" → README skills table
- "New hook added" → README hooks table

These categories are about the tdd-workflow plugin's own components. For zenoh-dart:
- New Dart API class → CLAUDE.md API list, README architecture
- New C shim function → CLAUDE.md Current Status
- New CLI example → CLAUDE.md CLI section, README CLI section
- Phase completed → README roadmap, CLAUDE.md status

### 2. detect-doc-context.sh is too shallow

Only checks if README.md, CLAUDE.md, CHANGELOG.md exist and scans docs/ at maxdepth 1.
Doesn't discover:
- pubspec.yaml (version context)
- Package-specific docs (e.g., packages/zenoh/README.md)
- Project-specific doc sections

### 3. No project-specific section awareness

Agent discovers "Available Dart API classes" section by reading CLAUDE.md, not by guidance.
Works by pattern matching but has no guarantee of finding all relevant sections.

### 4. Missing docs/phases/ update

Phase spec development/phases/phase-02-sub.md still reads as future work after completion.
detect-doc-context.sh uses maxdepth 1, misses docs/phases/ subdirectory.

### 5. Accumulated doc gaps

z_delete CLI example missing from CLAUDE.md CLI code block (Phase 1 doc-finalizer missed it).
Phase 2 doc-finalizer only added z_sub, didn't catch the gap.

## Improvement Options

### Option A: Project-specific doc guidance (recommended)
Add a section to CLAUDE.md (or a .tdd-doc-config.md) that tells the doc-finalizer
exactly which sections to update per release type. The agent reads this as context.

Example guidance:
```
When a phase completes, update:
- CLAUDE.md "Current Status": add phase status line with shim count + test count
- CLAUDE.md "Available Dart API classes": add new classes with descriptions
- CLAUDE.md "CLI examples": add new CLI examples with full LD_LIBRARY_PATH command
- README.md Phase Roadmap: mark phase COMPLETE
- README.md architecture diagram: add new classes
- README.md CLI Examples: add new commands with LD_LIBRARY_PATH
```

### Option B: Override categorization for consumer projects
Replace plugin-centric categories with generic library ones:
- New public API → API docs, architecture diagram
- New CLI tool → CLI examples section
- Phase completed → status sections, roadmap
- Breaking change → migration notes

### Option C: Let CA own documentation entirely
Skip tdd-finalize-docs. Have CI do doc updates as part of /tdd-release,
guided by CA's verification report. Doc-finalizer adds marginal value
when CA already produces comprehensive verification summaries.

## Verdict
Agent worked acceptably for Phase 2 but by luck (good existing patterns to follow).
Will degrade on projects with different doc structures.
Option A is the quickest win with least disruption to the plugin.
