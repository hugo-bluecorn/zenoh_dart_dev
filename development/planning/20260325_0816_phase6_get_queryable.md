# Planning Archive: Phase 6 — Get/Queryable

**Feature:** Query/reply pattern — `Session.get()`, `Queryable`, `Query`, `Reply`, `ReplyError`, `QueryTarget`, `ConsolidationMode`
**Approved:** 2026-03-25T08:16:30Z
**Iterations:** 2 (initial plan + revision per CA/CA2 review)

## Overview

Phase 6 adds the query/reply pattern to zenoh-dart: `Session.get()` sends queries and receives replies as a finite stream; `Session.declareQueryable()` declares handlers that receive queries and send replies. The most architecturally complex phase due to clone-and-post query lifecycle management and dual NativePort bridges (one for replies, one for incoming queries).

## Revision History

### Iteration 1 (rejected)
- Front-loaded all 12 C shim functions in Slice 1 as build prerequisite
- Function count was 12 (included internal callbacks)
- Missing: Consolidation LATEST test, Session.get() on closed session test

### Iteration 2 (approved)
- CA feedback: Redistribute C functions to testing slices (CLAUDE.md TDD guideline)
- CA2 feedback: Correct function count to 10 (internal callbacks are not exported)
- CA + CA2: Add Consolidation LATEST test (Slice 5) and Session.get() closed session test (Slice 4)
- CA retracted: Error reply integration testing (requires Query.replyErr(), deferred to Phase 6.1)

## Plan Summary

- **7 slices**, ~30 tests (193 → ~223 total)
- **10 new C shim functions** (62 → 72 total)
- **5 new Dart source files**, 2 modified files, 2 CLI examples, 3 test files

### Slice Breakdown

| Slice | Description | C Functions | Tests |
|-------|-------------|-------------|-------|
| 1 | QueryTarget/ConsolidationMode enums + exports | 0 (header only) | 4 |
| 2 | Reply/ReplyError data classes | 0 | 9 |
| 3 | Queryable lifecycle | 4 | 7 |
| 4 | Basic get/queryable integration (TCP 17470) | 6 | 12 |
| 5 | Advanced scenarios (TCP 17471) | 0 | 6 |
| 6 | z_get.dart CLI | 0 | 3 |
| 7 | z_queryable.dart CLI | 0 | 3 |

### Key Design Decisions

- Clone-and-post for query lifecycle (heap-allocated z_owned_query_t)
- Reply stream completion via null sentinel
- ConsolidationMode.auto → -1 sentinel (Dart enum index differs from zenoh-c value)
- Query.payloadBytes is nullable (query may not carry payload)
- Multiple replies per query supported (zd_query_reply does not consume query)

### Deferred to Phase 6.1+

- Query.replyErr() / Query.replyDel()
- Attachments on get and reply
- QoS options (congestion_control, priority, is_express)
- Locality filtering (allowed_destination, allowed_origin)
- Unstable API fields (accept_replies, source_info, cancellation_token)
