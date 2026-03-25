---
name: feedback_revision_cycles
description: Recognize when proposal revision cycles hit diminishing returns — execution-time details signal the end of the design phase
type: feedback
---

Stop revising proposals when findings shift from structural issues to execution-time details. Signs you've reached the end of the iteration cycle:
- Issues found are practical/ergonomic, not architectural
- Fixes are "add a note" rather than "restructure"
- Self-review expands beyond the base implementation that will work

**Why:** Token generation naturally expands scope over iterations. The 3rd pass catches real gaps; the 4th pass finds things that resolve naturally during implementation. Continuing past this point is writing about building instead of building.

**How to apply:** After 2-3 revision passes (including independent review), assess whether remaining issues are design-blocking or execution-time. If the latter, declare the proposal ready and move to implementation.
