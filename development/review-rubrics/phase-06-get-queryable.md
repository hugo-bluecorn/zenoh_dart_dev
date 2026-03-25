# Phase 6 Review Rubric: Get/Queryable

> **Purpose:** Internal review baseline for CA and CA2 when evaluating CP's
> plan. CP should NOT read this — it prescribes expected slice decomposition.
> CP must arrive at their decomposition independently from the revised spec.

## Expected Slice Decomposition

1. **Queryable entity lifecycle**: sizeof functions (zd_queryable_sizeof, zd_query_sizeof) + zd_declare_queryable + zd_queryable_drop. Build system: add new functions to ffigen.yaml, regenerate bindings. This establishes the queryable entity pattern before adding query handling.

2. **Query callback + Query class**: The NativePort callback (_zd_query_callback) that clones queries to heap and posts [query_ptr, keyexpr, params, payload_or_null]. Dart Query class with keyExpr/parameters/payloadBytes/dispose. Tests: queryable receives query with correct fields.

3. **Query.reply() + zd_query_reply()**: The reply path. C shim loans the owned query, calls z_query_reply() with payload + encoding. Dart Query.reply() and replyBytes(). Tests: basic get/queryable round-trip.

4. **zd_get() + Session.get()**: The get side. NativePort callback for replies (ok format: [1, keyexpr, payload, kind, attachment, encoding], error format: [0, payload, encoding], sentinel: null). Stream<Reply> in Dart. Reply/ReplyError classes. Tests: get receives replies, stream completes.

5. **QueryTarget + ConsolidationMode enums**: Can bundle with get or as standalone setup slice. Maps to z_query_target_t (0,1,2) and z_consolidation_mode_t (-1,0,1,2).

6. **CLI examples**: z_get.dart and z_queryable.dart as separate slices. Flags mirror zenoh-c examples. Must include -e/--connect and -l/--listen.

## Key Patterns CP Must Follow

- C shim + Dart wrapper + test in the same slice (not split)
- Clone-and-post for query lifecycle (clone in C callback, post handle via NativePort, Dart replies via handle, then disposes)
- NativePort + ReceivePort + StreamController triple (matches Subscriber pattern)
- Two-session TCP testing with unique ports per test group
- Flattened C shim params with sentinels (NULL for optional, -1 for AUTO consolidation)
- zd_ prefix on all C shim symbols
- Multiple replies per query supported (z_query_reply does NOT consume the query)

## Test Cases to Verify in Plan

The revised spec lists 14 integration tests. Key ones CP must not miss:

- Basic get/queryable round-trip (the minimum viable test)
- Multi-reply from single queryable (3 replies to one query)
- Query dispose without reply (get times out cleanly)
- Get timeout with no queryable (stream completes empty)
- Empty parameters (empty string, not null)
- Encoding round-trip on reply
- Queryable stream closes on undeclare

## Red Flags (reject if seen)

- Splitting C shim into its own slice without Dart wrapper + test
- Abstract base classes for Query or Reply
- Builder patterns for get options
- Mock FFI layer instead of real native calls
- replyErr/replyDel included (deferred to Phase 6.1)
- Attachment support included (deferred to Phase 7+)
- Accessor functions (zd_query_keyexpr etc.) as separate slices from the callback — they're part of the Query class slice

## Post-Phase Retrospective

After Phase 6 ships, evaluate:
1. Did the rubric correctly predict CP's decomposition?
2. Did CA2 find value in having the rubric for plan review?
3. Should this pattern (spec + rubric + minimal CP prompt) continue for Phase 7+?
