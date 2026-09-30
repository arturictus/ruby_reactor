# Data Model: Distributed Map Rollback and Bounded Fan-out

**Feature**: [spec.md](spec.md) | **Research**: [research.md](research.md)

All records live in Redis through `Storage::RedisAdapter`. Every key expires with
`durability_ttl`, like the existing map keys. `<P>` is the class name of the context that ran the
map (the parent), as in today's map keys; `<map_id>` is `"<parent context id>:<map step>"`.

## 1. Context (changed)

| Field | Type | Change | Notes |
| --- | --- | --- | --- |
| `status` | string | new value `rolling_back` | A rollback handed off at a fan-out map and has not finished. Non-terminal. |
| `rollback` | hash or nil | **new** | Where this execution level's rollback stands. Set only while `rolling_back`; cleared when the rollback finishes. A composed child keeps its own copy inside the root blob. |
| `failure_reason` | Failure | unchanged | Holds the final `Failure` once the rollback finishes. |
| `undo_stack` | array | unchanged | Already pops one entry per completed undo (008 R-16); this is the rollback's resume cursor. |
| `map_operations[step]` | string | meaning extended | Present means the map was dispatched: `MapStep#run` adopts instead of dispatching again, and `#undo` rolls back distributed (R-01, R-03). |

### `rollback` hash

| Key | Type | Meaning |
| --- | --- | --- |
| `trigger` | `"failure"` \| `"undo"` | What started the rollback: a step failure, or `Reactor#undo`. |
| `step` | string or nil | The failing step (`failure` trigger). For a compose whose child handed off, this is the compose step. |
| `compensated` | bool | Whether `step`'s own compensate has finished. False when the hand-off came from compensating `step` itself (a failed fan-out map, or a compose whose child is mid-rollback). |
| `failure` | serialized `Failure` or nil | The triggering failure. `resume_rollback` rebuilds the `StepFailureError` from it. |
| `failures` | array of rollback-failure entries | Rollback failures collected before the hand-off, restored into `CompensationManager#rollback_failures` on resume. |

### Status transitions

```text
running ──step failure──▶ (rollback in process) ──hand-off at fan-out map──▶ rolling_back
rolling_back ──owner resumed, map settled, rest undone──▶ failed      (trigger: failure)
rolling_back ──owner resumed, map settled, rest undone──▶ cancelled   (trigger: undo)
completed | failed | paused ──Reactor.undo──▶ (undo in caller) ──hand-off──▶ rolling_back
rolling_back ──another hand-off (a second fan-out map lower in the stack)──▶ rolling_back
```

Rules:

- `Worker#perform` on `rolling_back` calls `Executor#resume_rollback` and never resumes forward.
- `Reactor.undo` on `rolling_back` raises `ValidationError` (FR-027).
- `Reactor.cancel` on `rolling_back` raises `ValidationError` (FR-027). `cancelled` is terminal and
  would strand the steps before the map.
- `RubyReactor::Sweeper` re-enqueues `rolling_back` when no `async:` lock is held.
- A parent waiting on an `async_reactor` child keeps waiting while the child is `rolling_back`,
  because the status is non-terminal.

## 2. Map metadata (changed)

Key: `reactor:<P>:map:<map_id>:metadata` (hash, existing).

| Field | Change | Notes |
| --- | --- | --- |
| `owner_context_id` | **new** | The top-level run: `(context.root_context \|\| context).context_id`. The collector and the rollback resume this run's `Worker` (R-03, R-05). |
| `owner_reactor_class_name` | **new** | Storage name of the owner's class. |
| `batch_size` | **new** | The effective batch size: declared, or `Map::DEFAULT_BATCH_SIZE` (50). Read by forward re-dispatch and by the rollback. |
| `atomic` | **new** | Replaces the never-stored `fail_fast`. Read by `Dispatcher.requeue_index`. |
| everything else | unchanged | `count`, `strict_ordering`, `reactor_class_info`, `parent_context_id`, `step_name`, the nested-map fields. |

## 3. Map owner signal (new)

Key: `reactor:<P>:map:<map_id>:owner_signalled`, a string set with `SET NX` (TTL `durability_ttl`).

The collector claims it once the map has settled, then enqueues the owner's `Worker`. Only one
collector delivery ever enqueues.

## 4. Element-context index (write rule changed)

Key: `reactor:<P>:map:<map_id>:element_contexts` (list, existing).

- **Forward write**: `ElementExecutor` pushes the context id only for a **fresh** element context,
  not on a parked or retried re-entry (R-06). The inline map path is unchanged: one push per
  element.
- **Rollback read**: positions counted from the tail (position 0 is the last pushed id), one
  `LRANGE` per claimed batch.

## 5. Map rollback records (new)

| Key suffix (`reactor:<P>:map:<map_id>:rollback…`) | Type | Contents |
| --- | --- | --- |
| `:metadata` | hash, created with `HSETNX` | `total` (LLEN of the element index at start), `batch_size`, `step_name`, `owner_context_id`, `owner_reactor_class_name`, `reactor_class_info` (element class), `started_at`. Its presence means "a rollback of this map exists" (FR-027). |
| `:offset` | integer | The next unclaimed position. `INCRBY batch_size` claims a batch (R-02). |
| `:results` | hash, position → JSON outcome | One element rollback outcome per position (below). `HLEN == total` means settled. |
| `:indexes` | set of integers | Element indexes that a job saw. Used to name started-but-never-seen indexes (R-09). |
| `:handed_off` | string, `SET` | Set by the top-level hand-off handler **after** it saved the `rolling_back` context. Until it exists, no job enqueues the owner (R-05). Never set when the map settles synchronously (inline mode). |
| `:signalled` | string, `SET NX` | Claimed by whichever side observes both "settled" and `handed_off` second: the job storing an outcome, or the handler right after setting `handed_off`. The claimer enqueues the owner's `Worker` once (R-05). |

### Element rollback outcome (value in `:results`)

```json
{ "index": 42, "outcome": "undone", "failures": [] }
```

| `outcome` | When | Contributes to the final `rollback_failures` |
| --- | --- | --- |
| `undone` | The element was `completed` or `aborted` and its undo stack was replayed with no failure, or the stack was already empty (a duplicate). | nothing |
| `failed` | Replayed, but one or more undos failed. | each entry of `failures`, tagged `map_step`, `element_index` |
| `not_needed` | The element started but has nothing to undo: `failed` (it rolled itself back), `halted`, or still `running` from a superseded delivery. Skipped elements never started, so they have no position and no outcome. | nothing |
| `element_in_flight` | The element's `map_element:` lock was still held after the job requeued itself `lock_snooze_max_attempts` times (R-07): a genuinely live forward duplicate. A contended lock before that only requeues the job; no outcome is stored. | one entry, `reason: :element_in_flight` (as 008) |
| `context_unavailable` | The element context row is gone (expired). `index` is null. | only when `started` is unknown (below) |

**Aggregation** (owner, on re-entry once settled; R-09):

1. `HSCAN` outcomes in chunks of 500, and keep the `failures` of `failed` and `element_in_flight`
   outcomes.
2. **Re-symbolize** each entry, because JSON round-trips symbols as strings. Keys become symbols;
   the `step`, `kind`, `reason` and `map_step` values become symbols; `element_index` stays an
   Integer or nil. The entries then equal the inline path's (FR-005).
3. **Unavailable elements, each reported once**:
   - `started` known: add one `context_unavailable` entry per index in `0...started` missing from
     `:indexes`, and ignore nil-index `context_unavailable` outcomes, which describe the same
     elements;
   - `started` unknown: add one unnamed entry per nil-index `context_unavailable` outcome.

   This mirrors 008's `report_unavailable`, which uses one form or the other, never both.

### Rollback-failure entry (unchanged shape, 008)

```ruby
{ step: :charge, kind: :undo, key: nil, reason: :raised, message: "...",
  map_step: :charge_orders, element_index: 42 }
```

## 6. Element context during rollback (write rule changed)

The element rollback job saves the element context after **each** popped undo entry (R-07), under
the element's `map_element:<map_id>:<index>` lock. A redelivered job therefore resumes after the
last saved entry. Status stays as it was (`completed` / `aborted`); an empty undo stack is the
"already undone" signal.

## 7. Constants

| Constant | Value | Where |
| --- | --- | --- |
| `Map::DEFAULT_BATCH_SIZE` | 50 | Forward dispatch and rollback when no `batch_size` is declared. |
| `Map::ROLLBACK_CHUNK` | 100 | Elements loaded per read in inline map rollback. |
| `MapStep::ELEMENT_LOCK_WAIT` | 2 s | Existing. The rollback's wait on an element's liveness lock, per attempt. |
| `lock_snooze_max_attempts` / `lock_snooze_base_delay` | configuration (existing) | How many times, and how far apart, an element rollback job requeues itself on a contended element lock before reporting `element_in_flight` (R-07). |
| `Reactor::UNDO_LOCK_WAIT` | 5 s | Manual undo's wait on the run's `async:` lock (R-12). |

## 8. DSL value (renamed)

| DSL | Stored as | Default |
| --- | --- | --- |
| `atomic(enabled = true)` | `MapStep` input `atomic` | `true` |
| `fail_fast(enabled = true)` (deprecated) | same input; one warning per call site | — |
| `fan_out(enabled = true, batch_size: nil)` | `batch_size` input; the effective value is resolved at dispatch | 50 when omitted |

Legacy job payload key `fail_fast` is read as `atomic` by `Map::Helpers.normalize_arguments`
(FR-023).
