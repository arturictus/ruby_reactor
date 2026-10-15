# Data Model: ActiveRecord Storage Adapter

**Feature**: [spec.md](spec.md) | **Research**: [research.md](research.md)

## Conventions

- All tables are prefixed `ruby_reactor_`.
- `storage_name` is the `reactor_class_name` argument the adapter receives (`RubyReactor.reactor_storage_name`). It scopes rows exactly as it scopes Redis keys.
- **Ruby constants**: models are `RubyReactor::Storage::ActiveRecordAdapter::<Model>`, with no `Storage::ActiveRecord` module (R-01).
- `*_digest` is the SHA-256 hex (64 chars) of a user-supplied key string, such as lock, period or idempotency keys. User keys can be any length, and MySQL utf8mb4 indexes cap at 3072 bytes. The raw key is kept in `key` (text) for inspection and the dashboard.
- **JSON payloads** are `text` columns holding JSON. That is portable, and nothing queries inside them; queryable fields are projected into columns.
- `context` is `text`, except on MySQL where it is `LONGTEXT` (R-10).
- **Timestamps**: `created_at` and `updated_at` are `datetime(6)`. Coordination expiry is a `bigint` of epoch milliseconds on the database clock (R-06).
- **Retention**: history tables have no expiry (FR-014). Only `ruby_reactor_coordination` rows expire (R-07).
- **Scan windows**: sweeper scans of history tables filter on `updated_at > now − context_ttl` (R-08), so every scanned table has an `updated_at` index.

Each table below names the Redis key family it replaces, so a reviewer can map every adapter method onto both stores.

---

## 1. `ruby_reactor_schema`: schema version (FR-019)

| column | type | notes |
|---|---|---|
| id | integer PK | the table holds no rows |
| version | integer, not null, **default N** | the installed schema version is this column's **default** (R-16). 001 creates it with `default: 1`; each later migration runs `change_column_default`. |

Read once per process from the column metadata, at the adapter's first operation. It survives `db/schema.rb` loads and truncation, which a data row would not. A missing table, a default below `SCHEMA_VERSION` or a default above it each raise `StorageSchemaError` with a distinct message.

## 2. `ruby_reactor_executions`: one row per reactor run (replaces `reactor:<C>:context:<id>`)

| column | type | notes |
|---|---|---|
| id | string(36) PK | `context_id` |
| storage_name | string, not null | every `retrieve_context` filters on it (R-09) |
| reactor_class | string, not null | `data["reactor_class"]` |
| status | string(20), not null | `Adapter#determine_status(data)`: one of `pending running paused completed failed rolling_back halted aborted cancelled` |
| parent_context_id | string(36), null | composed child, async child or map element |
| root_context_id | string(36), null | |
| correlation_id | string, null | for display only; the claim lives in §9 |
| dispatched_child | boolean, default false | `private_data.async_dispatched`; the sweeper includes these (`include_dispatched_children`) |
| context | text / LONGTEXT, not null | the serialized context, byte-for-byte what Redis stored |
| started_at | datetime(6), null | `data["started_at"]` |
| finished_at | datetime(6), null | set when the status first becomes terminal |
| created_at, updated_at | datetime(6) | `updated_at` is bumped on every store |

**Indexes**:

- `(storage_name, id)`
- `(parent_context_id)`
- `(updated_at)`: sweeper window
- `(status, updated_at)`: sweeper candidates
- `(started_at DESC, id DESC)`: dashboard keyset
- `(reactor_class, started_at)`
- `(status, started_at)`

**Writes**: `store_context` is an upsert on `id` (last writer wins, like `SET`). `delete_context` deletes the row; it is only used by the existing explicit delete paths.

**State transitions**: `status` is projected from the context; the adapter never sets it on its own. Allowed values come from `determine_status`, unchanged.

## 3. `ruby_reactor_execution_inputs`: query index for top-level inputs (R-11)

| column | type | notes |
|---|---|---|
| execution_id | string(36), not null | → executions.id; `delete_context` deletes these rows too |
| name | string, not null | input name |
| value | string(255), not null | `to_s` of a scalar; `"null"` for nil |

**PK** `(execution_id, name)`. **Index** `(name, value, execution_id)`.

Written once, on the execution's first store, with `insert_all` skipping duplicates. Redacted inputs (`input …, redact: true`), non-scalar values, and values longer than 255 characters are never written, so they cannot be filtered on. The documentation says so.

## 4. `ruby_reactor_step_results`: async step outcomes (replaces `…:context:<id>:step_result:<step>`)

| column | type | notes |
|---|---|---|
| id | bigint PK | |
| storage_name | string, not null | |
| context_id | string(36), not null | the parent execution |
| step_name | string, not null | |
| status | string(20), not null | `record["status"]`: `dispatched` or `completed` |
| record | text, not null | the full JSON record, as Redis stored it |
| created_at, updated_at | datetime(6) | |

**Unique** `(storage_name, context_id, step_name)`. **Index** `(updated_at)`.

**Writes**: `store_step_result` is an upsert on the unique key. `scan_step_results` returns the `record`s within the R-08 window.

## 5. `ruby_reactor_map_operations`: one row per map step run (replaces `…:map:<id>:{metadata,counter,offset,last_queued_index,failed_context_id,owner_signalled}`)

| column | type | notes |
|---|---|---|
| id | bigint PK | |
| storage_name | string, not null | the parent reactor's storage name |
| map_id | string, not null | |
| metadata | text, null | the JSON hash `initialize_map_operation` builds today, unchanged; `retrieve_map_metadata` and `scan_maps` return it parsed |
| counter | bigint, null | remaining elements (`set/increment/decrement[_by]_map_counter`) |
| offset | bigint, null | `set_map_offset[_if_not_exists]`, `increment_map_offset` |
| last_queued_index | bigint, null | |
| failed_context_id | string(36), null | first failure wins (`WHERE failed_context_id IS NULL`) |
| owner_signalled_at | datetime(6), null | `claim_map_owner_signal`: a conditional set; one row updated means claimed |
| element_count | bigint, default 0 | append position for §6 (R-12) |
| created_at, updated_at | datetime(6) | |

**Unique** `(storage_name, map_id)`. **Index** `(updated_at)`.

**Writes**:

- Every counter or offset method ensures the row (`insert_all` skipping duplicates), then does a row-locked read-modify-write and returns the post-change value, exactly as `INCR`/`DECRBY` do.
- `NULL` stands for "key absent". `retrieve_map_offset` returns `nil` → `NULL`, preserving the Redis `GET` contract that callers test with `nil?`.

## 6. `ruby_reactor_map_elements`: element context index (replaces the `…:map:<id>:element_contexts` list)

| column | type | notes |
|---|---|---|
| map_operation_id | bigint, not null | → map_operations.id |
| position | bigint, not null | 0-based append order, assigned under the map row lock |
| context_id | string(36), not null | the element execution; duplicates are allowed, as in the Redis list |

**PK** `(map_operation_id, position)`.

`count_map_element_context_ids` reads `element_count`. Tail reads compute the same `start..stop` window as `LRANGE` and `ORDER BY position DESC`.

## 7. `ruby_reactor_map_results`: result slots (replaces the `…:map:<id>:results` hash)

| column | type | notes |
|---|---|---|
| map_operation_id | bigint, not null | |
| index | bigint, not null | element index |
| result | text, not null | JSON, as with `HSET` |

**PK** `(map_operation_id, index)`.

**Writes**: `store_map_result` is an upsert (re-dispatch overwrites the slot).

**Reads**:

- `retrieve_map_results_batch` and `retrieve_map_result_slots` are `WHERE index IN/BETWEEN`.
- `missing_map_indices` is `(0...count) − pluck(:index)`, the same O(n) as `HKEYS`.
- `count_map_results` is `COUNT(*)`.

## 8. Map rollback (009 DM §5) (replaces `…:map:<id>:rollback:{metadata,offset,results,indexes,handed_off,signalled}`)

### `ruby_reactor_map_rollbacks`

| column | type | notes |
|---|---|---|
| id | bigint PK | |
| storage_name, map_id | string, not null | **unique** together; insert-or-`RecordNotUnique` gives `start_map_rollback`'s `[created, meta]` |
| metadata | text, not null | the JSON fields `start_map_rollback` writes, plus `started_at` |
| offset | bigint, default 0 | `claim_map_rollback_positions`: a row-locked `+= count` that returns the range clipped to `total` |
| handed_off | boolean, default false | |
| signalled_at | datetime(6), null | `claim_map_rollback_signal`: conditional set |
| created_at, updated_at | datetime(6) | **index** `(updated_at)` for `scan_map_rollbacks` |

### `ruby_reactor_map_rollback_outcomes`

| column | type | notes |
|---|---|---|
| map_rollback_id | bigint, not null | |
| position | bigint, not null | |
| element_index | bigint, null | |
| outcome | text, not null | JSON |

**PK** `(map_rollback_id, position)`: the first outcome wins (`RecordNotUnique` → `false`, like `HSETNX`). **Index** `(map_rollback_id, element_index)`, which backs `map_rollback_indexes_seen`.

`map_rollback_summary` is two aggregate queries (COUNT, and COUNT where the outcome is in `FAILED_OUTCOMES`). It needs no Ruby iteration.

## 9. `ruby_reactor_correlation_ids` (replaces `…:correlation:<cid>`)

| column | type | notes |
|---|---|---|
| storage_name | string, not null | |
| correlation_digest | string(64), not null | |
| correlation_id | text, not null | |
| context_id | string(36), not null | |

**PK** `(storage_name, correlation_digest)`.

**Writes**: `store_correlation_id` inserts. On `RecordNotUnique` it reads the existing row: the same `context_id` returns, and a different one raises `ValidationError "Correlation ID '…' already exists"`. That is verbatim Redis behavior. `delete_correlation_id` deletes the row.

## 10. `ruby_reactor_interrupt_resumes` (010 DM §2–3) (replaces `…:resume:<step>` and `…:resume_attempts:<step>`)

| column | type | notes |
|---|---|---|
| storage_name | string, not null | |
| context_id | string(36), not null | |
| step_name | string, not null | a joined step path for composed children, the same string the Redis key used |
| payload | text, null | NULL = not claimed |
| attempts | integer, default 0 | |

**PK** `(storage_name, context_id, step_name)`.

**Writes**:

- `claim_interrupt_resume` ensures the row, then runs `UPDATE … SET payload = ? WHERE … AND payload IS NULL`. One row means claimed; the value changes from NULL, so MySQL affected-row counts are exact.
- `increment_interrupt_attempts` is a row-locked `+= 1` that returns the new value.

## 11. `ruby_reactor_period_markers`: permanent (FR-015) (replaces `period:<base>:<bucket>`)

| column | type | notes |
|---|---|---|
| key_digest | string(64) PK | digest of `Period.key(base, every)` |
| key | text, not null | e.g. `period:daily_report:7:2026` |
| context_id | string(36), null | the claiming execution, when the caller passes it (R-15) |
| claimed_at | datetime(6), not null | |

First insert wins. `period_seen?` and `period_marker?` are `EXISTS`; `period_ttl` returns `-1`.

## 12. `ruby_reactor_idempotency_keys` (US6) (Redis: `reactor:<C>:idempotency:<digest>`, `SET NX EX context_ttl`)

| column | type | notes |
|---|---|---|
| storage_name | string, not null | keys are scoped per reactor class (US6 scenario 3) |
| key_digest | string(64), not null | |
| key | text, not null | |
| context_id | string(36), not null | |
| created_at | datetime(6) | |

**PK** `(storage_name, key_digest)`.

`claim_idempotency_key` inserts. On `RecordNotUnique` it returns the existing `context_id`, and `nil` when it claimed the key.

## 13. `ruby_reactor_coordination`: TTL key/value for coordination (R-03, R-04)

| column | type | notes |
|---|---|---|
| key_digest | string(64) PK | |
| key | text, not null | the Redis key, verbatim (`lock:order:42`, `semaphore:x:held`, `ordered_lock:{k}:next`, `rate:k:60:29123`) |
| value | text, null | JSON-encoded Redis value; NULL = absent |
| expires_at_ms | bigint, null | NULL = no TTL; `<= now_ms` = absent |

**Index** `(expires_at_ms)`, used by `purge_expired_coordination`.

How each Redis type is encoded in `value`, all read and written only inside `atomically`:

| Redis type | JSON form | used by |
|---|---|---|
| string / int | `"…"` or a number | rate-limit counters, `ordered_lock:…:next/last_completed/first_failed/epoch`, `semaphore:…:init` |
| hash | object | `lock:<k>` → `{owner, count}`, `ordered_lock:…:assigned_at` → `{nonce: ts}` |
| list | array | `semaphore:<k>` available tokens (FIFO: `lpop` = shift, `rpush` = push) |
| set | array (unique) | `semaphore:<k>:held` |

**Per-key TTL fidelity**:

- Every Redis key keeps its own row, so per-key `EXPIRE`, `KEEPTTL`, and the ordered-lock "epoch outlives the others" rule port unchanged.
- The ordered-lock "drained" test (`exists next == 0 and exists last == 0`) reads two rows, both locked by the same transaction.

**Size bound**: the largest values are a semaphore's token list (≤ `limit` UUIDs) and an ordered lock's `assigned_at` (in-flight nonces only), so whole-value rewrites stay small.

---

## Entity relationships

```text
executions 1─* execution_inputs
executions 1─* step_results            (context_id)
executions 1─* interrupt_resumes       (context_id)
executions *─1 executions              (parent_context_id, root_context_id)
map_operations 1─* map_elements ─→ executions (context_id)
map_operations 1─* map_results
map_rollbacks 1─* map_rollback_outcomes        (map_rollbacks ↔ map_operations by storage_name + map_id)
correlation_ids, idempotency_keys, period_markers ─→ executions (context_id)
coordination: standalone, keyed by Redis key
```

None of the links is a foreign-key constraint; they are logical, as they are in Redis. A child can be written before its parent's first save (for example a map element before the map's checkpoint), so FK constraints would reject valid write orders.

## Migrations (R-16)

| file | creates | `SCHEMA_VERSION` |
|---|---|---|
| `001_create_ruby_reactor_tables.rb` | §1–§13 | 1 |

Future schema changes add `002_…` and onward, each bumping the default of `ruby_reactor_schema.version`. `migrations.lock` pins the SHA-256 of each released file.
