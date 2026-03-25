# CLI Examples Cross-Language Review

Comparison of all 7 zenoh-dart CLI examples against their zenoh-c and zenoh-cpp equivalents (v1.7.2).

**Reviewed files:**
- C: `extern/zenoh-c/examples/z_*.c`
- C++: `extern/zenoh-cpp/examples/universal/z_*.cxx` (SHM: `zenohc/z_pub_shm.cxx`)
- Dart: `package/example/z_*.dart`

---

## 1. z_put

### Core flow comparison

| Step | C | C++ | Dart |
|------|---|-----|------|
| Init log | `zc_init_log_from_env_or("error")` | `init_log_from_env_or("error")` | `Zenoh.initLog('error')` |
| Open session | `z_open(&s, z_move(config), NULL)` | `Session::open(std::move(config))` | `Session.open(config: config)` |
| Put | `z_put(z_loan(s), z_loan(ke), z_move(payload), NULL)` | `session.put(KeyExpr(keyexpr), payload)` | `session.put(keyExpr, value)` |
| Close | `z_drop(z_move(s))` | RAII | `session.close()` |

### CLI flags

| Flag | C | C++ | Dart |
|------|---|-----|------|
| `-k, --key` | `_Z_PARSE_ARG` | `named_value({"k","key"})` | `addOption('key', abbr: 'k')` |
| `-p, --payload` | `_Z_PARSE_ARG` | `named_value({"p","payload"})` | `addOption('payload', abbr: 'p')` |
| `-e, --connect` | `parse_zenoh_common_args` | `ConfigCliArgParser` | `addMultiOption('connect', abbr: 'e')` |
| `-l, --listen` | `parse_zenoh_common_args` | `ConfigCliArgParser` | `addMultiOption('listen', abbr: 'l')` |

### Default key expression

| C | C++ | Dart |
|---|-----|------|
| `demo/example/zenoh-c-put` | `demo/example/zenoh-cpp-zenoh-c-put` | `demo/example/zenoh-dart-put` |

### Conformance: PASS

Dart mirrors C++ ergonomics exactly. All flags match. The only structural difference is endpoint configuration — C/C++ use internal common-arg parsers while Dart explicitly calls `config.insertJson5()`. Functionally equivalent.

---

## 2. z_delete

### Core flow comparison

| Step | C | C++ | Dart |
|------|---|-----|------|
| Delete | `z_delete(z_loan(s), z_loan(ke), NULL)` | `session.delete_resource(KeyExpr(keyexpr))` | `session.deleteResource(keyExpr)` |

### CLI flags

| Flag | C | C++ | Dart |
|------|---|-----|------|
| `-k, --key` | Yes | Yes | Yes |
| `-e, --connect` | Yes (common args) | Yes (ConfigCliArgParser) | **MISSING** |
| `-l, --listen` | Yes (common args) | Yes (ConfigCliArgParser) | **MISSING** |

### Conformance: MINOR DEVIATION

**Finding D-1:** `z_delete.dart` is missing `-e`/`--connect` and `-l`/`--listen` flags. It uses `Session.open()` with no config, meaning it can only operate in multicast peer mode. Both C and C++ support endpoint configuration via common args. The Dart example should add `connect`/`listen` options and `Config()` construction matching the other examples.

---

## 3. z_sub

### Core flow comparison

| Step | C | C++ | Dart |
|------|---|-----|------|
| Declare subscriber | `z_declare_subscriber(z_loan(s), &sub, z_loan(ke), z_move(callback), NULL)` | `session.declare_subscriber(keyexpr, data_handler, closures::none)` | `session.declareSubscriber(keyExpr)` |
| Receive samples | C callback function `data_handler` | C++ lambda `data_handler` | `subscriber.stream.listen(...)` |
| Wait | `while(1) z_sleep_s(1)` | `while(true) sleep_for(1s)` | `Completer + signal handlers` |
| Cleanup | `z_drop(sub); z_drop(s)` | RAII | `subscriber.close(); session.close()` |

### Sample output format

| Field | C | C++ | Dart |
|-------|---|-----|------|
| Kind | `kind_to_str(z_sample_kind(sample))` | `kind_to_str(sample.get_kind())` | `sample.kind == SampleKind.put ? 'PUT' : 'DELETE'` |
| Key | `z_keyexpr_as_view_string(z_sample_keyexpr(sample), &key_string)` | `sample.get_keyexpr().as_string_view()` | `sample.keyExpr` |
| Payload | `z_bytes_to_string(z_sample_payload(sample), &payload_string)` | `sample.get_payload().as_string()` | `sample.payload` |
| Attachment | Checked via `z_sample_attachment(sample) != NULL` | `sample.get_attachment().has_value()` | Not printed |

### Output format

```
C/C++: >> [Subscriber] Received PUT ('demo/example/test': 'Hello')
Dart:  >> [Subscriber] Received PUT ('demo/example/test': 'Hello')
```

### Conformance: PASS

Dart uses stream-based delivery (idiomatic for Dart) vs callback-based in C/C++. The output format matches. Signal handling is cleaner in Dart (explicit SIGINT/SIGTERM listeners with Completer) vs C/C++ infinite sleep loops.

**Note:** Dart doesn't print attachments in the subscriber output. C and C++ both print attachment if present. This is cosmetic — the Dart `Sample` class does expose `attachment`, it's just not printed in the example.

---

## 4. z_pub

### Core flow comparison

| Step | C | C++ | Dart |
|------|---|-----|------|
| Declare publisher | `z_declare_publisher(z_loan(s), &pub, z_loan(ke), NULL)` | `session.declare_publisher(KeyExpr(keyexpr))` | `session.declarePublisher(keyExpr)` |
| Matching listener | `z_publisher_declare_background_matching_listener(z_loan(pub), z_move(callback))` | `pub.declare_background_matching_listener(lambda, closures::none)` | `publisher.matchingStatus!.listen(...)` |
| Put in loop | `z_publisher_put(z_loan(pub), z_move(payload), &options)` | `pub.put(s, std::move(options))` | `publisher.put(payload)` |
| Encoding | `z_encoding_clone(&encoding, z_encoding_text_plain()); options.encoding = z_move(encoding)` | Not set | Not set |

### CLI flags

| Flag | C | C++ | Dart |
|------|---|-----|------|
| `-k, --key` | Yes | Yes | Yes |
| `-p, --payload` | Yes | Yes | Yes |
| `-a, --attach` | Yes | Yes | Yes |
| `--add-matching-listener` | Yes | Yes | Yes |
| `-e, --connect` | Yes | Yes | Yes |
| `-l, --listen` | Yes | Yes | Yes |

### Publish loop format

```
C:    [   0] Pub from C!
C++:  [0] Pub from C++ zenoh-c!
Dart: [0] Pub from Dart!
```

### Conformance: PASS

All flags present. Matching listener semantics match. The C example explicitly sets `encoding = text_plain` in put options; C++ and Dart do not (relying on defaults). This is consistent — the C example is more verbose by nature.

**Note:** C uses `sprintf(buf, "[%4d] %s", ...)` (4-digit padded), C++ uses `"[" << idx << "]"` (no padding), Dart uses `"[$idx]"` (no padding). Dart matches C++ convention.

---

## 5. z_pub_shm

### Core flow comparison

| Step | C | C++ | Dart |
|------|---|-----|------|
| Create SHM provider | `z_shm_provider_default_new(&provider, 4096)` | `PosixShmProvider(MemoryLayout(65536, AllocAlignment({2})))` | `ShmProvider(size: 65536)` |
| Alloc buffer | `z_shm_provider_alloc_gc_defrag_blocking(&alloc, z_loan(provider), buf_ok_size)` | `provider.alloc_gc_defrag_blocking(len, AllocAlignment({0}))` | `provider.allocGcDefragBlocking(encodedBytes.length)` |
| Write to buffer | `sprintf((char*)buf, ...)` | `memcpy(buf.data(), s.data(), len)` | `dataPtr[i] = encodedBytes[i]` (byte loop) |
| Convert to bytes | `z_bytes_from_shm_mut(&payload, z_move(alloc.buf))` | implicit via `pub.put(std::move(buf))` | `buffer.toBytes()` |
| Publish | `z_publisher_put(z_loan(pub), z_move(payload), &options)` | `pub.put(std::move(buf))` | `publisher.putBytes(zbytes)` |
| Cleanup | `z_drop(provider); z_drop(pub); z_drop(s)` | RAII | `provider.close(); publisher.close(); session.close()` |

### SHM provider sizes

| | C | C++ | Dart |
|-|---|-----|------|
| Pool size | 4096 | 65536 | 65536 |
| Alloc size | `total_size / 4` = 1024 | `s.size() + 1` (dynamic) | `encodedBytes.length` (dynamic) |
| Alignment | default | `AllocAlignment({2})` provider, `{0}` per-alloc | default |

### CLI flags

| Flag | C | C++ | Dart |
|------|---|-----|------|
| `-k, --key` | Yes | Yes | Yes |
| `-p, --payload` | Yes | Yes | Yes |
| `--add-matching-listener` | Yes | Yes | Yes |
| `-a, --attach` | **Yes** (C z_pub has it) | No | No |
| `-e, --connect` | Yes | Yes | Yes |
| `-l, --listen` | Yes | Yes | Yes |

### Conformance: PASS

The SHM pipeline is structurally equivalent across all three. Dart's alloc size matches C++ (dynamic, based on actual payload length) rather than C (fixed quarter of pool). The C++ example uses explicit alignment; Dart uses default alignment (matching C).

**Note:** C++ `z_pub_shm.cxx` is under `zenohc/` (not `universal/`) because SHM is zenoh-c specific. The Dart example is in `example/` with the others since SHM is feature-guarded at the C shim level.

---

## 6. z_info

### Core flow comparison

| Step | C | C++ | Dart |
|------|---|-----|------|
| Own ZID | `z_info_zid(z_loan(s))` then `z_id_to_string` | `session.get_zid()` (operator<<) | `session.zid.toHexString()` |
| Router ZIDs | `z_info_routers_zid(z_loan(s), z_move(callback))` | `session.get_routers_z_id()` (range-for) | `session.routersZid()` (for-in) |
| Peer ZIDs | `z_info_peers_zid(z_loan(s), z_move(callback2))` | `session.get_peers_z_id()` (range-for) | `session.peersZid()` (for-in) |

### Output format

```
C:    own id: <hex>\nrouters ids:\n<hex>\npeers ids:\n<hex>
C++:  own id: <hex>\nrouters ids:\n<hex>\npeers ids:\n<hex>
Dart: own id: <hex>\nrouters ids:\n  <hex>\npeers ids:\n  <hex>
```

### CLI flags

| Flag | C | C++ | Dart |
|------|---|-----|------|
| `-e, --connect` | Yes | Yes | Yes |
| `-l, --listen` | Yes | Yes | Yes |

### Conformance: PASS

Dart matches C++ ergonomics (property/method access, iteration). Minor formatting difference: Dart indents router/peer IDs with 2 spaces. C/C++ do not indent. Cosmetic only.

**Note:** C++ guards info functions behind `#if defined(ZENOHCXX_ZENOHC) && defined(Z_FEATURE_UNSTABLE_API)`. Dart doesn't need feature guards — the C shim handles this.

---

## 7. z_scout

### Core flow comparison

| Step | C | C++ | Dart |
|------|---|-----|------|
| Scout call | `z_scout(z_move(config), z_move(closure), NULL)` + `z_sleep_s(1)` | `scout(std::move(config), on_hello, on_end_scouting)` + condition_variable wait | `Zenoh.scout(config: config)` returns `Future<List<Hello>>` |
| Hello handling | Callback increments counter | Callback prints + increments | Collect into list, iterate after |
| Completion | `drop` callback checks count | `on_end_scouting` signals condition_variable | `await` resolves when scouting completes |

### Hello output format

```
C:    Hello { pid: <hex>, whatami: peer, locators: [tcp/...] }
C++:  Hello { pid: <hex>, whatami: peer, locators: ["tcp/..."] }
Dart: Hello(zid: <hex>, whatami: peer, locators: [tcp/...])
```

### CLI flags

| Flag | C | C++ | Dart |
|------|---|-----|------|
| `-e, --connect` | No (uses default config) | Yes (ConfigCliArgParser) | Yes |
| `-l, --listen` | No (uses default config) | Yes (ConfigCliArgParser) | Yes |

### Conformance: PASS

Dart's `Future<List<Hello>>` + `await` is the idiomatic equivalent of C++'s callback + condition_variable synchronization. The Hello output format differs slightly (`Hello(...)` vs `Hello { ... }`) — this is Dart's `toString()` convention. Functionally identical.

**Note:** C's scout example uses `z_config_default(&config)` with no endpoint args. C++ and Dart both support endpoint configuration.

---

## Summary

| Example | Flags Match | Flow Match | Output Match | Verdict |
|---------|:-----------:|:----------:|:------------:|---------|
| z_put | Yes | Yes | Yes | **PASS** |
| z_delete | **No** (missing -e/-l) | Yes | Yes | **MINOR DEVIATION** |
| z_sub | Yes | Yes (stream vs callback) | Yes | **PASS** |
| z_pub | Yes | Yes | Yes | **PASS** |
| z_pub_shm | Yes | Yes | Yes | **PASS** |
| z_info | Yes | Yes | ~Yes (indent) | **PASS** |
| z_scout | Yes | Yes (Future vs callback) | ~Yes (toString) | **PASS** |

### Findings

| ID | Severity | Example | Description |
|----|----------|---------|-------------|
| D-1 | Minor | z_delete | Missing `-e`/`--connect` and `-l`/`--listen` flags. Uses `Session.open()` with no config. C and C++ both support endpoint configuration. |

### Architectural observations

1. **Dart tracks C++ ergonomics, not C verbosity.** The C examples require manual `z_loan`/`z_move`/`z_drop`, view keyexpr creation, bytes conversion, and explicit cleanup. The C++ examples abstract all of this via RAII and method syntax. Dart matches the C++ pattern — one-line `session.put(keyExpr, value)`, `session.declareSubscriber(keyExpr)`, etc.

2. **Idiomatic Dart patterns replace C/C++ patterns.** Streams replace callbacks (z_sub), `Future<List<Hello>>` replaces callback + condition_variable (z_scout), `Timer.periodic` replaces infinite for-loops with sleep (z_pub), `Completer` + signal listeners replace `while(true) sleep` (z_sub, z_pub).

3. **Endpoint configuration is explicit in Dart.** C and C++ use internal common-arg parsers that handle endpoint injection automatically. Dart manually constructs the JSON and calls `config.insertJson5()`. This is repeated boilerplate across 5 of 7 examples. A future helper (e.g., `Config.fromArgs()`) could reduce this, but it's not a conformance issue.

4. **SHM pipeline is structurally equivalent.** The alloc → write → toBytes → putBytes flow in Dart maps 1:1 to C's alloc → write → `z_bytes_from_shm_mut` → `z_publisher_put` and C++'s alloc → memcpy → `pub.put(std::move(buf))`.

5. **All default key expressions follow the `demo/example/zenoh-<lang>-<op>` convention.** This is consistent with zenoh's cross-language example naming.
