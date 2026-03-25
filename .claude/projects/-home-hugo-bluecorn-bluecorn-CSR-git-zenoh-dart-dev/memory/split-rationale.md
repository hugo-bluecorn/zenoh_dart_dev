---
name: split-rationale
description: Why zenoh_dart has a dev/prod repo split — AI-assisted development generates too many artifacts for a product repo
type: project
---

The dev/prod split exists because AI-assisted development (Claude Code) generates far more structured artifacts than traditional development. Phase specs, design docs with multi-pass revisions, TDD progress files, experiment results, audit documents, LaTeX papers, memory files, role definitions, proposals with review cycles — none of this belongs in a product repo but all of it is valuable during development.

**Why:** Traditional repo sync patterns (subtree, submodules, GitHub Actions, Copybara) don't account for this because it's a new problem. Teams without AI assistance don't produce this volume of development scaffolding. The split keeps the product repo clean for consumers while preserving the full development record.

**How to apply:** Development happens in zenoh_dart_dev. Clean code syncs to zenoh_dart (prod). The sync mechanism should be simple (dev mirrors prod's `package/` layout so file copy works without path translation). Choose the simplest sync approach — likely a script or GitHub Action, not heavyweight tooling.
