# Contract: Storage Adapter (parity surface)

`RubyReactor::Storage::Adapter` is the contract. Today it declares only part of what `RedisAdapter` implements and the runtime calls. This feature makes the **base class declare every method callers use**, each raising `NotImplementedError`. A contract spec then asserts that both adapters respond to every declared method, so a missing method fails CI instead of failing in production.

Both adapters must satisfy every row below. The **Semantics** column is the behavior the shared contract spec (`spec/ruby_reactor/storage/adapter_contract_spec.rb`) checks against each adapter.

Notation:

- `C` is the storage name (`reactor_class_name`).
- "NX" means the first caller wins, and later callers observe the winner.
- "absent" means the reader gets `nil`, `false` or `0`, exactly as the Redis method returns today.

## Contexts and lookup

| Method | Semantics |
|---|---|
| `store_context(id, json, C)` | Last writer wins. Redis: re-stamps the TTL. AR: upsert, plus the query projection (R-09). |
| `retrieve_context(id, C)` → Hash \| nil | Lookup by id **and** `C`; nil under any other `C`. |
| `find_context_by_id(id)` → Hash \| nil | Lookup by id across all classes. |
| `delete_context(id, C)` | Removes the context. AR also removes its input-index rows. |
| `determine_status(data)` → String | **Moves to `Adapter`** and is shared verbatim. |
| `scan_reactors(pattern:, count:, include_dispatched_children:)` → [Hash] | Sweeper input. The row shape is `{id, class, status, created_at, failure}`, unchanged. AR: R-08 window. |
| `scan_reactors_page(pattern:, cursor:, count:, include_dispatched_children:)` → `{reactors:, cursor:}` | Dashboard listing. `cursor` is opaque; `"0"` means start, and in a response it means end. AR lists all history. |
| `expire(key, seconds)` | No caller outside storage. AR: no-op. |

## Correlation IDs

| Method | Semantics |
|---|---|
| `store_correlation_id(cid, id, C)` | NX. Re-storing the same `id` is a no-op; a different `id` raises `ValidationError "Correlation ID '…' already exists"`. |
| `retrieve_context_id_by_correlation_id(cid, C)` → String \| nil | |
| `delete_correlation_id(cid, C)` | |

## Async step results

| Method | Semantics |
|---|---|
| `store_step_result(id, step, record, C)` | Last writer wins. |
| `retrieve_step_result(id, step, C)` → Hash \| nil | |
| `scan_step_results(count:)` → [Hash] | AR: R-08 window. |

## Maps

| Method | Semantics |
|---|---|
| `initialize_map_operation(map_id, count, C, reactor_class_info:, **meta)` | Sets the counter to `count` and stores the metadata hash unchanged. |
| `retrieve_map_metadata(map_id, C)` → Hash \| nil | |
| `scan_maps(count:)` → [Hash] | Metadata hashes. AR: R-08 window. |
| `set_map_counter` / `increment_map_counter` / `decrement_map_counter` / `decrement_map_counter_by(…, amount, C)` → Integer | Atomic. `_by` returns the remaining count. |
| `set_last_queued_index` / `increment_last_queued_index` | Atomic `INCR` semantics. |
| `set_map_offset` / `set_map_offset_if_not_exists` (NX) / `retrieve_map_offset` (nil when absent) / `increment_map_offset` | |
| `store_map_failed_context_id` (NX, first failure wins) / `retrieve_map_failed_context_id` | |
| `claim_map_owner_signal(map_id, C)` → Boolean | NX: exactly one `true`. |
| `store_map_result(map_id, index, value, C, strict_ordering:)` | Overwrites slot `index`. |
| `retrieve_map_results(map_id, C, strict_ordering:)` → [value] | Sorted by index. |
| `retrieve_map_results_batch(map_id, C, offset:, limit:, strict_ordering:)` → [value] | Present slots in `offset…offset+limit`, in index order. |
| `retrieve_map_result_slots(map_id, C, indexes)` → [value \| nil] | Aligned with `indexes`. |
| `count_map_results(map_id, C)` → Integer | |
| `missing_map_indices(map_id, count, C)` → [Integer] | |
| `store_map_element_context_id(map_id, id, C)` | Appends. Positions never shift (R-12). |
| `retrieve_map_element_context_ids(map_id, C)` → [String] | In append order. |
| `retrieve_map_element_context_id(map_id, C, index:)` → String \| nil | `LINDEX` semantics, including negative indexes. |
| `count_map_element_context_ids(map_id, C)` → Integer | |
| `retrieve_map_element_context_ids_from_tail(map_id, C, position, count, total:)` → [String] | The same window arithmetic as `RedisMapRollback`. |

## Map rollback (009)

| Method | Semantics |
|---|---|
| `start_map_rollback(map_id, C, **meta)` → `[created, metadata]` | NX on the map. A second caller gets `false` and the first caller's metadata. |
| `retrieve_map_rollback_metadata` / `retrieve_map_rollback_offset` | |
| `claim_map_rollback_positions(map_id, C, count)` → Range | Atomic `+= count`, clipped to `total`. |
| `store_map_rollback_outcome(map_id, C, position, outcome)` → Boolean | First outcome per position wins. Records the element index as seen. |
| `count_map_rollback_outcomes` / `stored_map_rollback_positions` / `map_rollback_outcome_stored?` / `each_map_rollback_outcome` | |
| `map_rollback_indexes_seen(map_id, C, indexes)` → [Boolean] | |
| `mark_map_rollback_handed_off` / `map_rollback_handed_off?` | |
| `claim_map_rollback_signal(map_id, C)` → Boolean | NX. |
| `map_rollback_summary(map_id, C)` → `{total, settled, outstanding, failed}` \| nil | |
| `scan_map_rollbacks(count:)` → [Hash] | AR: R-08 window. |

## Interrupt resumes (010)

| Method | Semantics |
|---|---|
| `claim_interrupt_resume(id, C, step, payload)` → Boolean | NX per `(id, step)`. The claim is never deleted. |
| `retrieve_interrupt_resumes(id, C, steps)` → `{step => payload}` | Claimed steps only. |
| `increment_interrupt_attempts(id, C, step)` → Integer | Atomic; returns the post-increment value. |

## Coordination (TTL-bound on both adapters)

These are ported line by line from Lua for AR (R-04). Return values are unchanged.

| Method | Semantics |
|---|---|
| `lock_acquire(key, owner, ttl)` / `lock_release(key, owner)` / `lock_extend(key, owner, ttl)` → Boolean | Re-entrant by owner (count). Expires after `ttl`, judged by the store's clock. |
| `lock_held?(bare_key)` / `lock_info(prefixed)` / `lock_ttl(prefixed)` | `lock_ttl` returns `-2` when absent. |
| `semaphore_init(key, limit)` → Boolean (NX) / `semaphore_reset` / `semaphore_exists?` | |
| `semaphore_acquire(key, timeout:)` → token \| nil | `timeout > 0` waits up to `timeout`. AR polls every 50 ms. |
| `semaphore_release(key, token, limit)` → Boolean | Refuses a double release and over-cap pushes. |
| `semaphore_held(key, token)` / `semaphore_held?` / `semaphore_state(name)` | |
| `rate_limit_check_and_increment(keys, argv)` → `[allowed, retry_after, failed_index]` | All windows or none. |
| `rate_limit_count` / `rate_limit_ttl` | |
| `period_seen?(key)` / `period_marker?(base, every)` | |
| `period_mark(key, ttl, context_id: nil)` | **New optional kwarg.** Redis: `SET key (context_id \|\| "1") EX ttl`. AR: permanent row, first claim wins (R-15). |
| `period_ttl(base, every)` | AR: `-1` (persistent). |
| `period_marker_info(base, every, now:)` → `{context_id:, claimed_at:}` \| nil | **Added by US5 (T059).** Redis: `context_id` is the stored value, or `nil` when the value is `"1"`; `claimed_at` is always `nil`. AR: the marker row. |
| `ordered_lock_assign` / `_can_proceed` / `_advance` / `_skip` / `_heartbeat` / `_reset` / `_peek` / `_keys` | Every return tuple, fence (stale epoch, drained batch), GC and KEEPTTL behavior is identical. |

## Completion signals

| Method | Semantics |
|---|---|
| `publish(channel, message)` | Redis: `PUBLISH`. AR: no-op. |
| `subscribe(channel) { \|msg\| … }` | Blocks until the block returns truthy or the thread is killed. AR: never yields; `AsyncWaiter` kills it (R-14). |

## New methods (this feature)

| Method | Redis | ActiveRecord |
|---|---|---|
| `claim_idempotency_key(key, id, C)` → nil \| String | `SET NX EX context_ttl`; returns the existing id when lost | permanent row; returns the existing id when lost |
| `purge_expired_coordination(limit: 1000)` → Integer | `0` (no-op) | deletes expired and NULL coordination rows (R-07) |
| `query_executions(filters:, cursor:, count:)` → `{reactors:, cursor:}` | **not defined** (capability absent) | keyset-paged filtered listing (R-18) |
