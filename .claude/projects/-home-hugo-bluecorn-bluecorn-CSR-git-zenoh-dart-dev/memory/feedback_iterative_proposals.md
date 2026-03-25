---
name: feedback_iterative_proposals
description: User prefers 2-3 revision passes on proposals before finalizing — iterative refinement catches gaps from first-pass generation
type: feedback
---

Do 2-3 revision passes on proposals and design documents before considering them final.

**Why:** First-pass token generation is hypothesis-driven (generating from research). Subsequent passes work from the concrete artifact that now exists, catching gaps, internal inconsistencies, and missing details that weren't visible during generation. The user explicitly values this pattern and considers it a quality improvement technique.

**How to apply:** After writing a proposal or design doc, re-read the full output and do a critical review pass — look for underspecified sections, inconsistencies between sections, missing diagrams, untested assumptions, and broken numbering. Fix issues and push as a separate commit so the diff is reviewable. Flag what the revision pass caught.
