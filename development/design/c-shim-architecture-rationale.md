# C Shim Architecture Rationale

> **Audience:** Auditors, reviewers, and future contributors seeking to understand
> the architectural decisions behind zenoh-dart's C shim layer.
>
> **Case study:** Phase 6 (Get/Queryable) — the most architecturally complex
> phase, used throughout as the concrete example.
>
> **Date:** 2026-03-25

## 1. Why: The Dual-Reference Strategy

### The Dependency Chain

```
Rust (zenoh core) --> zenoh-c (C bindings) --> C shim (zd_*) --> Dart FFI --> Dart API
```

We reference two layers from our extern submodules — zenoh-c and zenoh-cpp — and
explicitly avoid a third (Rust).

### Why Both C and C++, Not Just C

**zenoh-c is our contract boundary.** Every function we call, every options struct
we fill, every return code we check is defined in the zenoh-c headers. The C
headers and tests are the authoritative specification for FFI correctness.

**zenoh-cpp is our structural peer.** It wraps the same zenoh-c API from another
language, making it the best template for API design — options classes, error
handling patterns, Session vs Publisher vs Queryable split, lifecycle management.
C++ solved the same "language binding over zenoh-c" problem we are solving in Dart.

**Neither alone is sufficient:**

- C alone gives correct FFI but no guidance on API ergonomics. You would end up
  with a 1:1 C wrapper, not an idiomatic Dart API.
- C++ alone gives good API design but hides the C-level details (move semantics,
  loaning, options struct fields) that our shim must handle correctly.

**What we explicitly avoid:** The Rust source (`eclipse-zenoh/zenoh`). It is one
layer too deep — we cannot call Rust APIs, only C APIs. The Rust codebase would
overwhelm planning context with internals that do not map to our FFI boundary.

### What to Look at Per Phase

| Need | Look at C | Look at C++ |
|------|-----------|-------------|
| Function signatures | `zenoh_commons.h` | -- |
| Options struct fields | `z_*_options_t` | Verify same fields exposed |
| Move/consume semantics | `z_api_drop_options.c` | -- |
| Error handling pattern | Return codes | `ZException` maps to our `ZenohException` |
| API shape (methods, classes) | -- | `session.hxx`, `publisher.hxx`, etc. |
| Test structure | `z_int_*.c` | `network/*.cxx` (closest analog to our tests) |
| CLI flags and output format | `examples/z_*.c` | `examples/universal/z_*.cxx` |
| Edge cases | C unit tests | C++ tests for binding-specific issues |

## 2. Why: The Example-Driven Approach

The zenoh-c and zenoh-cpp examples (`z_get.c`, `z_queryable.c`, `z_get.cxx`,
`z_queryable.cxx`, etc.) are the **behavioral specification** for each zenoh
interaction pattern. We implement against the examples rather than the headers
alone for four reasons:

### 2.1 Examples Encode Intent, Headers Encode Capability

The headers expose hundreds of options, flags, and functions. The examples show
which ones matter for each use case and in what order. Without the examples, we
would be guessing which subset of `z_get_options_t`'s 13 fields to expose first.

### 2.2 Cross-Language Interop Verification

Our Dart `z_get.dart` must be able to talk to a C `z_queryable` and vice versa.
If both implementations follow the same example patterns — same defaults, same
selector parsing, same output format — cross-language testing is trivial. You
swap one process for the other.

### 2.3 User Familiarity

When a zenoh user picks up zenoh-dart, they will compare our `z_get.dart` to the
`z_get.c` they already know. Matching flags (`-s`, `-k`, `-p`, `-t`, `-o`, `-e`,
`-l`), matching defaults (`demo/example/**`), and matching output format
(`>> Received ('keyexpr': 'value')`) means zero cognitive overhead switching
languages.

### 2.4 Scope Control

The examples naturally define the phase boundary. Each example demonstrates one
zenoh pattern: Phase 2 = `z_sub`, Phase 3 = `z_pub`, Phase 6 = `z_get` +
`z_queryable`. The examples are the roadmap.

**The chain is:** C example shows the pattern. C++ example shows how a language
binding wraps it. Dart CLI mirrors both. Dart API is the idiomatic layer
underneath.

## 3. How: The C Shim as Sole Facade

### Dart Never Calls zenoh-c Directly

```
Dart --> libzenoh_dart.so (C shim, zd_* functions)
              |
              +--> libzenohc.so (zenoh-c, z_* functions)
                   resolved by OS linker via DT_NEEDED
```

Dart has **zero direct bindings** to zenoh-c. The `ffigen.yaml` configuration
filters on `zd_.*` — only symbols with the `zd_` prefix appear in
`bindings.dart`. Dart literally cannot see `z_get()`, `z_declare_queryable()`,
or any other zenoh-c function. They do not exist in Dart's world.

### Why Not Split Calls Between zd_* and z_*?

One could theoretically have ffigen generate bindings for both headers and let
Dart call `z_*` directly when no FFI barrier exists. We chose not to, for four
reasons:

1. **zenoh-c's header is enormous.** Hundreds of functions, macros that expand to
   nothing, opaque types that confuse ffigen.

2. **Almost every call chain hits a barrier.** Even "simple" functions need a loan
   or move first, which is a macro or static inline. You would shim the loan,
   call the function directly, then shim the drop. This is worse than shimming
   the whole operation.

3. **Two namespaces in bindings means confusion.** "Which do I call? Is this one
   shimmed? Do I need to loan first?" The single-namespace `zd_*` convention
   eliminates this entirely.

4. **Maintenance burden.** Every new phase would require auditing which functions
   need a shim versus a direct call. One wrong call (forgetting that the loan is
   a macro) produces a crash.

### The Six FFI Barrier Patterns

These are the structural reasons the C shim exists. Each pattern represents
something Dart FFI and ffigen cannot handle, documented in full in
`development/c-shim/C_shim_audit.md`:

| # | Barrier | Why Dart Cannot Cross It |
|---|---------|--------------------------|
| 1 | `static inline` move functions | No exported symbol for Dart to bind to |
| 2 | C11 `_Generic` polymorphic macros | No exported symbol; compile-time dispatch |
| 3 | Options struct initialization | `_default()` functions are macros or inlines |
| 4 | Opaque type sizes | Dart FFI has no `sizeof` for foreign types |
| 5 | Closure callbacks across threads | NativePort bridge required for Dart event loop |
| 6 | Loaning and const/mut enforcement | `z_*_loan()` are macros/inlines; Dart erases const |

Every `zd_*` function in the shim exists because it wraps one or more of these
barriers.

### Two Orthogonal Design Choices

The architecture reflects two independent decisions:

| Decision | Our Choice | Alternative |
|----------|------------|-------------|
| **Interface boundary** | C shim is sole facade (all `zd_*`) | Dual-binding (`zd_*` + `z_*` direct) |
| **Callback data flow** | Push via NativePort (extract in C, post all fields) | Pull via accessors (post pointer only, Dart calls back to C) |

We chose "sole facade + push." This is the simplest architecture but has a
consequence explored in Section 4.

## 4. What: Phase 6 Function Audit (Case Study)

Phase 6 (Get/Queryable) adds 10 C shim functions. During architectural review,
we audited each function against the six barrier patterns to verify that the shim
contains no unnecessary proxies.

### Function-by-Function Analysis

| # | Function | FFI Barrier(s) | Called from Dart? | Verdict |
|---|----------|----------------|-------------------|---------|
| 1 | `zd_queryable_sizeof` | P4 (opaque size) | Yes — Dart allocates queryable via calloc | Justified |
| 2 | `zd_query_sizeof` | P4 (opaque size) | No — C callback mallocs the query; Dart receives raw pointer as int64 | Barrier-justified but currently unreachable |
| 3 | `zd_get` | P5 (closure/NativePort) + P3 (options) + P2 (macro) | Yes | Justified |
| 4 | `zd_declare_queryable` | P5 (closure/NativePort) + P3 (options) + P2 (macro) | Yes | Justified |
| 5 | `zd_query_reply` | P6 (loan) + P3 (options) + P1 (inline) | Yes | Justified |
| 6 | `zd_query_drop` | P1/P2 (move macro) | Yes | Justified |
| 7 | `zd_query_keyexpr` | P6 (loan) + P1 (inline) | No — NativePort already posts keyexpr | Barrier-justified but currently unreachable |
| 8 | `zd_query_parameters` | P6 (loan) + P1 (inline) | No — NativePort already posts parameters | Barrier-justified but currently unreachable |
| 9 | `zd_query_payload` | P6 (loan) | No — NativePort already posts payload | Barrier-justified but currently unreachable |
| 10 | `zd_queryable_drop` | P1/P2 (move macro) | Yes | Justified |

### Key Finding: Barrier-Justified but Currently Unreachable

Four functions (2, 7, 8, 9) have genuine FFI barriers — each wraps something
Dart FFI cannot call directly. However, the "push via NativePort" data flow
design makes them unreachable in the current code path:

- `zd_query_sizeof`: C allocates the query internally (clone-and-post pattern).
  Dart receives a pointer, never needs the size.
- `zd_query_keyexpr`, `zd_query_parameters`, `zd_query_payload`: The NativePort
  callback extracts all fields in C and posts them to Dart. Dart stores them in
  the `Query` object on receipt. There is no pull-back-to-C call.

### Pattern Consistency Check

Looking at Phases 0-5, the established convention is:

- **Entity properties** use pull-accessors (e.g., `zd_publisher_keyexpr()`,
  `zd_session_zid()`)
- **Message/event data** uses push via NativePort (subscriber callback posts
  sample fields, scout callback posts hello fields)
- **Entity allocation** is Dart-side via `sizeof` + `calloc`, C fills
  (subscriber, publisher, queryable)

The four unreachable functions break these patterns: they add pull-accessors for
message data that is already pushed, and `zd_query_sizeof` provides a size for
an allocation that C handles internally.

### Decision: Keep All 10 Functions

Despite being currently unreachable, we retain all 10 functions because:

1. **Each has a genuine FFI barrier.** They are not unnecessary proxies — they
   wrap operations Dart FFI genuinely cannot perform directly (loaning, move
   semantics, opaque sizes).

2. **No foreknowledge of future phases.** Phases 7-18 are specified but not yet
   implemented. A future phase could introduce a code path where Dart needs to
   lazily access query fields (pull-based) rather than receiving them all upfront
   (push-based). Removing the accessors now and re-adding them later costs a spec
   revision, rebuild, and ffigen cycle.

3. **Marginal cost.** Each accessor is approximately 5-10 lines of trivial C
   code. They add no complexity, no maintenance burden, and no risk.

4. **The YAGNI principle applies to speculative features, not to completing a
   thin shim layer over an API you are already wrapping.** The functions exist at
   the C level; the barriers exist; the shim provides them. Whether Dart calls
   them today is a data flow question, not a shim completeness question.

## 5. What: Phase 6 CLI Cross-Language Verification

To verify that our Dart CLI examples follow the example-driven approach, we
compared the C, C++, and Dart specifications side by side.

### z_get CLI Comparison

| Aspect | C (`z_get.c`) | C++ (`z_get.cxx`) | Dart (`z_get.dart`) |
|--------|---------------|---------------------|---------------------|
| -s/--selector | `demo/example/**` | `demo/example/**` | `demo/example/**` |
| -p/--payload | optional string | optional string | optional string |
| -t/--target | `BEST_MATCHING\|ALL\|ALL_COMPLETE` | same | same |
| -o/--timeout | `10000` ms | `10000` ms | `10000` ms |
| -e/--connect | common args | `ConfigCliArgParser` | specified |
| -l/--listen | common args | `ConfigCliArgParser` | specified |
| Selector parsing | Manual `strchr('?')` split | `parse_selector()` | API takes separate args |
| Output (ok) | `>> Received ('ke': 'val')` | `Received ('ke' : 'val')` | `>> Received ('ke': 'val')` |
| Output (error) | `Received an error` (no payload) | `Received an error : payload` | `>> Received (ERROR: 'payload')` |
| Completion | FIFO channel recv loop | condition_variable wait | Stream completes |

### z_queryable CLI Comparison

| Aspect | C (`z_queryable.c`) | C++ (`z_queryable.cxx`) | Dart (`z_queryable.dart`) |
|--------|---------------------|-------------------------|---------------------------|
| -k/--key | `demo/example/zenoh-c-queryable` | `demo/example/zenoh-cpp-zenoh-c-queryable` | `demo/example/zenoh-dart-queryable` |
| -p/--payload | `Queryable from C!` | `Queryable from C++ zenoh-c!` | `Queryable from Dart!` |
| --complete | flag | flag | flag |
| -e/--connect | common args | `ConfigCliArgParser` | specified |
| -l/--listen | common args | `ConfigCliArgParser` | specified |
| Query output | `>> [Queryable ] Received Query 'ke?params'` | Same format | Matches |
| Query payload | Prints if non-null and non-empty | Prints if `has_value()` | Should match |
| Reply output | `>> [Queryable ] Responding ('ke': 'val')` | `[Queryable ] Responding ('ke': 'val')` | Should match |

### Findings

1. **Flags and defaults are consistent** across all three languages.
2. **C++ error output is more informative** than C (prints the error payload).
   Dart follows C++ here, which is the correct choice since C++ is our structural
   peer.
3. **Language-specific defaults** follow the zenoh convention: each binding uses
   its own identifier in the default keyexpr and payload string.
4. **Completion mechanisms differ by language** (C: FIFO channel, C++:
   condition_variable, Dart: async Stream) but the behavioral contract is
   identical: process replies until done.

## 6. Why Not NativeCallable.listener? (Dart 3.1+ Callback API)

Dart 3.1 (August 2023) introduced `NativeCallable`, a higher-level API for
creating native callback pointers. Three constructors exist as of Dart 3.11:

| Constructor | Thread-safe? | Synchronous? | Return values? | Min Dart |
|-------------|-------------|-------------|----------------|----------|
| `.isolateLocal` | Same thread only (aborts otherwise) | Yes | Yes | 3.2 |
| `.listener` | Any thread | No (async) | No (void only) | 3.1 |
| `.isolateGroupBound` | Any thread | Yes | Yes | Experimental |

### 6.1 NativeCallable.listener Uses the Same Mechanism We Already Use

`NativeCallable.listener` internally uses `SendPort`/`ReceivePort` message
passing — confirmed by the VM implementation (`Ffi_createNativeCallableListener`
in `runtime/lib/ffi.cc`), which calls `isolate->CreateAsyncFfiCallback(zone,
send_function, port.Id())`. This is functionally identical to our manual
`Dart_PostCObject_DL()` + `ReceivePort` bridge in the C shim.

Same plumbing, different tap.

### 6.2 The Loaned-Pointer Lifetime Problem

The critical constraint that no Dart-side API can solve:

```
zenoh thread calls: callback(z_loaned_sample_t*, void* context)
                              ^^^^^^^^^^^^^^
                              ONLY VALID DURING THIS CALL
```

`NativeCallable.listener` is **asynchronous**. It serializes the pointer address
(an integer) through a `SendPort` and delivers it to the Dart isolate later. By
the time Dart processes the message, the `z_loaned_sample_t*` is **already
invalid** — the memory that backed it has been released or reused by zenoh-c.

This means even with `NativeCallable.listener`, you **still need C code** that:

1. Runs synchronously during the callback (on the zenoh thread)
2. Extracts keyexpr, payload, kind, attachment, encoding from the loaned pointer
3. Posts the extracted data (not the pointer) to Dart

That C code **is our shim.** The loaned-pointer lifetime problem is structural
to zenoh-c's API design and cannot be solved from the Dart side alone.

### 6.3 Why the Other Variants Don't Help Either

**`NativeCallable.isolateLocal`** aborts the process if called from a
non-Dart-isolate thread. Zenoh callbacks run on tokio worker threads. This
variant has the same fatal flaw as `Pointer.fromFunction` — it would crash
identically.

**`NativeCallable.isolateGroupBound`** (experimental) runs the Dart callback
synchronously on the calling thread, which would allow reading loaned pointers
directly. However:

- It is explicitly marked experimental ("may change in the future")
- It would block zenoh's tokio event loop while Dart code executes
- It restricts access to static/global fields not shared between isolates
- No stable release date announced

### 6.4 Could a Hybrid Approach Work?

A hybrid where the C shim extracts data, allocates a heap copy, then calls a
`NativeCallable.listener` function pointer with the heap pointer is technically
possible. The Dart callback (async, on isolate thread) would read and free the
heap copy.

**Gain:** Closure support on the Dart side (no static dispatch map), slightly
cleaner receiver code.

**Cost:** Still requires the C shim for synchronous data extraction. Adds a new
native function signature for the handoff. Refactors a tested, proven pattern
for marginal ergonomic improvement.

**Verdict:** Not justified. The current pattern is battle-tested across 6 phases
and 200+ tests.

### 6.5 Deprecation Status

- `Pointer.fromFunction`: **Not deprecated.** The Dart 3.1 changelog states it
  "will be replaced" by `NativeCallable` in future releases, but no timeline or
  `@Deprecated` annotation exists.
- `SendPort.nativePort` / `Dart_PostCObject_DL`: **Not deprecated.** No
  deprecation notice exists in the stable API.
- Our approach remains fully supported.

### 6.6 Future Watch

Monitor `NativeCallable.isolateGroupBound` for stable promotion. If it
stabilizes, it could genuinely eliminate the C shim's callback data extraction
code by allowing Dart to read loaned pointers synchronously on the zenoh thread.
The tradeoff (blocking zenoh's event loop during Dart execution) would need
benchmarking, but for lightweight field extraction it may be acceptable.

Until then: stay the course.

## 7. Summary

The zenoh-dart C shim architecture is governed by four principles:

1. **Dual reference** — C for correctness, C++ for design. Neither alone
   suffices.
2. **Example-driven** — CLI examples mirror C/C++ examples for interop,
   familiarity, and scope control.
3. **Sole facade** — Dart talks only to `zd_*` functions. The shim exists for
   FFI barriers but serves as the complete interface, not a selective bypass.
4. **NativePort over NativeCallable** — Dart's `NativeCallable.listener` uses
   the same `SendPort`/`ReceivePort` mechanism we already use manually. The C
   shim remains necessary because zenoh-c's loaned pointers are only valid
   during the synchronous callback — no Dart-side API can solve this structural
   constraint. Revisit when `NativeCallable.isolateGroupBound` reaches stable.

Phase 6 validates these principles: 10 functions, each barrier-justified, 6
actively called, 4 retained for completeness and future-proofing. The CLI
examples match C/C++ flags, defaults, and output format. The architecture is
minimal, auditable, and consistent with Phases 0-5.
