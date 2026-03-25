# C Shim Audit — Detailed Memory

## Document Genealogy

Three source documents were created independently, then synthesized:

1. **CA-C_shim_proof.md** (CA session) — Existence proof with 4 lettered patterns (A-D):
   - A: `static inline` move functions → no symbol in `nm -D`
   - B: `_Generic` polymorphic macros → preprocessor construct, no symbol
   - C: Options struct initialization → compound barrier (sizeof + move fields)
   - D: Opaque type sizes → Dart FFI has no `sizeof()` for foreign types
   - Includes end-to-end `z_put` trace, ffigen #146/#459 citations

2. **CA-C_shim_audit.md** (CA session) — Function-by-function analysis:
   - All 62 C shim functions audited
   - Ownership model (3-state: live/consumed/disposed)
   - Thread safety analysis
   - Findings F1-F5

3. **CC-C_shim_audit.md** (CC session) — Independent audit:
   - Merged CA's patterns A+B into its Pattern 1
   - Used 4 numbered patterns (1-4), where Pattern 4 = closure callbacks (NEW)
   - Added Pattern Resolution Matrix (62-row table)
   - Additional findings (C-14: return-value, C-16: style)

### Synthesis Result

**`C_shim_audit.md`** — Single unified document with 5 parts:
- Part A: Existence proof (5 patterns after dedup: CA's A-D + CC's callbacks)
- Part B: Function-by-function audit
- Part C: Cross-cutting analysis
- Part D: Pattern resolution matrix
- Part E: Conformance summary
- 7 findings (F1-F7), all references verified against Dart 3.11.1

### Pattern Deduplication Logic
- CA had 4 (A, B, C, D) — `static inline`, `_Generic`, options structs, sizeof
- CC had 4 (1, 2, 3, 4) — merged macros+inlines, sizeof, options, callbacks
- Union = 5: split CC's merged Pattern 1 back into two + kept CC's Pattern 4

## LaTeX Document

**Location:** `development/c-shim/latex/C_shim_audit.tex`
**Output:** 23 pages, 485KB PDF, clean build (zero warnings)

### LaTeX Packages & Features Used
- `listings` — 4 syntax styles: cstyle, dartstyle, shellstyle, yamlstyle
- `tcolorbox` — 3 box types: quotebox, findingbox (parameterized color), patternbox
- `booktabs` + `tabularx` — Professional tables with `L` (raggedright X) column type
- `longtable` — 62-row pattern resolution matrix with `Y{8mm}` centered columns
- `hyperref` — Clickable cross-references, bookmarks, colored links
- `fancyhdr` — Header with doc title + zenoh-c version, footer with page number
- `titlesec` — Sans-serif section headings
- `sourcecodepro` — Monospace font for code
- `microtype` — Microtypographic refinements
- Custom `\newcolumntype{Y}[1]` for centered fixed-width columns
- Custom commands: `\code{}`, `\fn{}`, `\type{}`, `\file{}`, `\pattern{}`, `\PASS`, `\PARTIAL`

### Overfull/Underfull Fixes Applied
Key techniques for fixing monospace identifier overflow in body text:
- `\allowbreak{}` inside `\code{}`/`\fn{}` at underscore boundaries
- `\-` discretionary hyphenation hints
- Reword paragraphs so long `\fn{}` names don't land at line-break points
- Reformat inline comma-separated lists to `\begin{itemize}`
- Change conformance tables from `lll` to `lcL` (flexible notes column)
- Use `\footnotesize` for tables with long monospace cell content
- `\pagenumbering{Alph}` before titlepage / `\pagenumbering{arabic}` after TOC (fixes duplicate page.1 destination)

## Resolved: 6th Pattern — Loaning (Restored)

User correctly recalled 6 patterns. Discovery: `development/reviews/c-shim-audit.md` (line 23) explicitly states "The C shim resolves all six problems" with "loaning pattern" as the 6th. The synthesized document had incorrectly folded loaning into Patterns 1+2.

**Verdict: 6 patterns is correct.** Pattern 6 (Loaning) is genuinely distinct:
- Per-type loan functions (`z_config_loan`, `z_bytes_loan`) ARE exported (`nm -D` confirms `T` symbols)
- This distinguishes them from Pattern 1 (`static inline`, no symbol) and Pattern 2 (`_Generic` macro, no symbol)
- The barrier is **semantic**: Dart's `Pointer<Opaque>` erases `const` qualifier — no compile-time or runtime enforcement of immutability
- The shim enforces const/mut correctness at the C compiler level via explicit naming

**Documents updated:**
- `development/c-shim/C_shim_audit.md` — Added A.7 Pattern 6 section, updated matrix (P1 count corrected from 40→34, P6 added with 8 functions), updated pattern summary table
- `development/c-shim/latex/C_shim_audit.tex` — Pattern 6 section, 6-column matrix, 6-row summary table, end-to-end example updated. 26 pages, 506KB, zero warnings.

**Key correction in matrix:** Loan functions (`zd_*_loan`) are NO LONGER marked P1. They wrap exported functions, not `static inline` functions. Previously incorrectly attributed to Pattern 1.

**Struct-by-value return:** Still a sub-mechanism of Pattern 1 (not a separate pattern). The loan question was the real missing pattern.
