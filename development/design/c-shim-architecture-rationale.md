# C Shim Architecture Rationale

> **Audience:** Auditors, reviewers, and future contributors seeking to understand
> the architectural decisions behind zenoh-dart's C shim layer.
>
> **Case study:** `z_get` / `z_queryable` (query/reply) — the most
> architecturally complex example set, used throughout as the concrete case.
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
zenoh pattern: `z_sub` for subscribe, `z_pub` for publish, `z_get` +
`z_queryable` for query/reply. The examples are the roadmap.

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

## 4. What: `z_get` / `z_queryable` Function Audit (Case Study)

The get/queryable implementation adds 10 C shim functions wrapping `z_get()`,
`z_declare_queryable()`, `z_query_reply()`, and related accessors. During
architectural review, we audited each function against the six barrier patterns
to verify that the shim contains no unnecessary proxies.

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

Looking at the established convention across `z_put`, `z_pub`, `z_sub`,
`z_scout`, and `z_info`:

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

2. **No foreknowledge of future examples.** Later zenoh-c examples
   (`z_get_liveliness`, `z_querier`, etc.) may introduce code paths where Dart
   needs to lazily access query fields (pull-based) rather than receiving them
   all upfront (push-based). Removing the accessors now and re-adding them later
   costs a rebuild and ffigen cycle.

3. **Marginal cost.** Each accessor is approximately 5-10 lines of trivial C
   code. They add no complexity, no maintenance burden, and no risk.

4. **The YAGNI principle applies to speculative features, not to completing a
   thin shim layer over an API you are already wrapping.** The functions exist at
   the C level; the barriers exist; the shim provides them. Whether Dart calls
   them today is a data flow question, not a shim completeness question.

## 5. What: `z_get` / `z_queryable` CLI Cross-Language Verification

To verify that our Dart CLI examples follow the example-driven approach, we
compared the C, C++, and Dart implementations side by side.

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

## 7. Why zenoh-dart Does Not Implement `z_queryable_with_channels` or `z_non_blocking_get`

The zenoh-c examples include two channel-based alternatives to the callback
pattern:

- `z_queryable_with_channels.c` — declares a queryable backed by a FIFO
  channel, receives queries via blocking `z_recv()` in a loop
- `z_non_blocking_get.c` — sends a query with a FIFO handler, polls for
  replies via `z_try_recv()` with sleep between attempts

The zenoh-cpp equivalents use `channels::FifoChannel(16)` as a template
parameter to `session.get()` and `session.declare_queryable()`, returning
handler objects with `recv()` and `try_recv()` methods.

**zenoh-dart does not implement these examples.** The analysis below explains
why.

### 7.1 The Channel Pattern Solves a Problem Dart Does Not Have

The channel abstraction in zenoh-c exists because C has no async runtime.
C developers need an explicit mechanism to decouple the zenoh callback thread
from the processing thread:

```c
// C: the only way to consume events without a callback
while (z_recv(z_loan(handler), &query) == Z_OK) {
    // process query on main thread
}
```

Dart has `Stream`, `Future`, and `async`/`await`. The zenoh-dart binding uses
a NativePort + StreamController bridge that is functionally identical to a
FIFO channel — events are buffered asynchronously and delivered to the
consumer on the Dart event loop:

```dart
// Dart: Stream IS the channel
await for (final query in queryable.stream) {
    // process query — non-blocking, event-driven
}
```

The existing `z_queryable.dart` and `z_get.dart` CLI examples already provide
the Dart-idiomatic equivalent of both channel examples:

| zenoh-c Channel Example | C Pattern | zenoh-dart Equivalent | Dart Pattern |
|---|---|---|---|
| `z_queryable_with_channels.c` | `while(1) z_recv()` blocking loop | `z_queryable.dart` | `await for (q in queryable.stream)` |
| `z_non_blocking_get.c` | `while(1) z_try_recv(); sleep()` poll loop | `z_get.dart` | `await for (r in session.get(...))` |

### 7.2 Blocking `recv()` Is Dangerous in Dart's Execution Model

Dart isolates are single-threaded. A blocking FFI call to
`z_fifo_handler_query_recv()` would freeze the entire isolate — no timers,
no I/O, no UI updates. The workarounds all collapse back to the pattern
already in use:

| Approach | Consequence |
|----------|-------------|
| Block the main isolate | Event loop freezes — unacceptable |
| Run on a helper isolate with message passing | Reinvents the NativePort bridge |
| Make `recv()` async with a Completer | Reinvents StreamController |

### 7.3 Polling `try_recv()` Is an Anti-Pattern in Async Dart

The `z_non_blocking_get.c` example polls in a loop with `sleep()` between
attempts. In Dart, this wastes CPU cycles and requires tuning the poll
interval. Streams are event-driven — the consumer is notified exactly when
data arrives, with no polling overhead:

```c
// C: poll with sleep (the only non-blocking option without callbacks)
while (1) {
    int rc = z_try_recv(z_loan(handler), &reply);
    if (rc == Z_CHANNEL_DISCONNECTED) break;
    if (rc == Z_CHANNEL_NODATA) { z_sleep_s(1); continue; }
    process_reply(reply);
}
```

```dart
// Dart: event-driven, zero wasted cycles
await for (final reply in session.get('demo/**')) {
    processReply(reply);
}
// Stream completes automatically on sentinel
```

### 7.4 Barrier Analysis: Most Functions Would Be Pure Facades

Independent analysis of the 11 C shim functions that would be required
reveals that only 2 have genuine FFI barriers. The remaining 9 wrap
zenoh-c functions that are actual exported symbols (`ZENOHC_API`), not
macros or static inlines:

| Would-Be Shim Function | Wraps | FFI Barrier? |
|---|---|---|
| `zd_declare_queryable_with_fifo_channel` | `z_fifo_channel_query_new` + `z_declare_queryable` | **Yes** — closure creation |
| `zd_get_with_handler` | `z_fifo_channel_reply_new` + `z_get` | **Yes** — closure + options |
| `zd_fifo_handler_query_recv` | `z_fifo_handler_query_recv` | No — exported function |
| `zd_fifo_handler_query_loan` | `z_fifo_handler_query_loan` | No — exported function |
| `zd_fifo_handler_query_drop` | `z_fifo_handler_query_drop` | Move wrapper only |
| `zd_fifo_handler_reply_try_recv` | `z_fifo_handler_reply_try_recv` | No — exported function |
| `zd_fifo_handler_reply_loan` | `z_fifo_handler_reply_loan` | No — exported function |
| `zd_fifo_handler_reply_drop` | `z_fifo_handler_reply_drop` | Move wrapper only |
| `zd_reply_is_ok` | `z_reply_is_ok` | No — exported function |
| `zd_reply_ok` | `z_reply_ok` | No — exported function |
| `zd_reply_drop` | `z_reply_drop` | Move wrapper only |

This would be the most proxy-heavy set of functions in the shim, violating
the principle that the C shim exists for FFI barriers, not as a full proxy
layer.

### 7.5 Conclusion

The `z_queryable_with_channels` and `z_non_blocking_get` examples demonstrate
an alternative consumption model (polling/blocking channels) for the same
query/reply operations that zenoh-dart already supports via Streams. Dart's
async runtime provides the buffering, non-blocking delivery, and completion
signaling that C achieves through explicit channel objects.

Implementing these examples in zenoh-dart would add redundant API surface,
introduce dangerous blocking semantics, and require 9 facade functions with
no FFI barrier justification. The existing `z_queryable.dart` and `z_get.dart`
CLI examples are the Dart-idiomatic implementations of the same behaviors.

## 8. How zenoh-dart Implements `z_pull` (C-Side Ring Buffer)

Unlike the channel examples skipped in Section 7, `z_pull.c` introduces a
genuinely new semantic: **lossy buffering**. A ring buffer drops the oldest
samples when full, guaranteeing the consumer always sees the most recent data.
This cannot be replicated by Dart's `Stream` (which buffers indefinitely) or
`StreamController` (which has no drop-oldest policy).

### 8.1 Why C-Side, Not Dart-Side

The ring buffer must live in C, not Dart. The reason is **freshness**.

If the ring buffer sits in Dart (after NativePort delivery), all samples
cross the FFI boundary — including ones that will be dropped. When Dart's
event loop stalls (GC pause, Flutter frame render), the "surviving" samples
in a Dart-side ring are stale: they were recent when C posted them, but old
by the time Dart processes them.

With a C-side ring buffer, drops happen before NativePort. Only surviving
samples cross FFI. If Dart stalls for 500ms and a sensor publishes at 100Hz,
the 3 samples in a C-side ring of capacity 3 are from the last 30ms. In a
Dart-side ring, they'd be 500ms old.

```
C-side:  zenoh thread → [ring buffer, drops oldest] → NativePort → Dart
Dart-side: zenoh thread → NativePort → [ring buffer, drops oldest] → Dart
                                        ^^^^^^^^^^^^^^^^^^^^^^^^^^^^
                                        samples already stale if Dart stalled
```

### 8.2 The "Fat tryRecv" Pattern

The pull subscriber does not use NativePort at all. Instead, Dart polls via a
synchronous FFI call: `zd_pull_subscriber_try_recv()`. This single call does:

1. `z_ring_handler_sample_try_recv()` — non-blocking receive from ring
2. `z_sample_loan()` — borrow the sample
3. Extract all fields (keyexpr, payload, kind, encoding, attachment)
4. `z_sample_drop()` — release the sample
5. Return extracted data via output pointers

One FFI call per poll. Dart never holds a sample handle. This mirrors the
subscriber callback pattern (extract everything in C, deliver to Dart in one
operation) but inverts the control flow — Dart pulls instead of C pushing.

### 8.3 Return Code Semantics

`z_pull.c` uses `z_try_recv()` which returns three possible values:

| Return | Constant | Meaning | Dart action |
|--------|----------|---------|-------------|
| 0 | `Z_OK` | Sample available | Construct `Sample`, return it |
| 1 | `Z_CHANNEL_NODATA` | Ring empty | Return `null` |
| 2 | `Z_CHANNEL_DISCONNECTED` | Subscriber closed | Throw `StateError` |

These are **positive** return codes — unlike the usual zenoh-c convention
where errors are negative. The Dart side must not use the `!= 0` error
pattern here.

### 8.4 Barrier Justification

All 4 C shim functions have genuine FFI barriers:

| Function | Barrier |
|----------|---------|
| `zd_ring_handler_sample_sizeof` | P4 — opaque type size |
| `zd_declare_pull_subscriber` | P5 (closure) + P1 (move) |
| `zd_pull_subscriber_try_recv` | P2 (`z_try_recv`/`z_loan` are `_Generic` macros) + extraction chain |
| `zd_ring_handler_sample_drop` | P1 (`z_move` is static inline) |

Zero facades. The pull subscriber is the leanest new-capability addition
in the shim's history: 4 functions, all barrier-justified, one new Dart
class, one CLI example.

### 8.5 CLI: `z_pull.dart` Mirrors `z_pull.c` via `stdin.readLineSync()`

`z_pull.c` uses `getchar()` for interactive polling — the user presses Enter
to pull. Dart mirrors this exactly with `stdin.readLineSync()`, which blocks
the CLI process until user input (acceptable in a CLI context). No timer, no
invented flags — the user controls the poll interval by pressing Enter.

## 9. Summary

The zenoh-dart C shim architecture is governed by five principles:

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
5. **Skip what the language already provides** — zenoh-c's channel pattern
   (`z_recv`/`z_try_recv` with FIFO/Ring handlers) compensates for C's lack
   of async runtime. Dart's `Stream` provides identical semantics natively.
   The `z_queryable_with_channels` and `z_non_blocking_get` examples are not
   implemented because `z_queryable.dart` and `z_get.dart` already deliver the
   same behavior via Streams.

The architecture is minimal, auditable, and consistent across all implemented
examples. Each C shim function is barrier-justified, and examples that map to
native Dart abstractions are implemented idiomatically rather than ported
literally.
