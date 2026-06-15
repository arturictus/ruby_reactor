# Reactor Durability: Implementation Plan

Companion to `durability_investigation.md`. The investigation established
*what* to change and *why*; this document specifies *how* — concrete edits,
ordering, sequencing, and tests.

> **No backward compatibility required.** There is no RubyReactor deployment in
> production. We are free to change the Sidekiq job signature, the stored
> payload shape, the storage TTL, and the schema-version policy without
> migration shims. This removes the single biggest source of complexity the
> investigation hedged around.

---

## Target state (recap)

1. **Storage is load-bearing.** The stored context is the source of truth for
   resume, not the Sidekiq job payload.
2. **Job payload is identity-only:** `(context_id, reactor_class_name, snooze_count)`.
   The worker rehydrates the live context from storage by that id.
3. **Save-per-step:** every completed step writes a durable checkpoint, so a
   crash re-runs at most the single in-flight step.
4. **Per-context lock** serializes duplicate deliveries and doubles as the
   liveness signal.
5. **Sweeper** re-enqueues non-terminal contexts whose worker died (no live lock).
6. **TTL refresh** on each save so long-running/snoozed contexts never expire
   mid-flight.

---

## Findings from the code review that shape the implementation

These are mechanics the investigation did not pin down. Each one is a concrete
constraint on the edits below.

### F1 — `save_context` serializes the wrong context for a checkpoint

`Executor#save_context` (`lib/ruby_reactor/executor.rb:242-249`) serializes
`@context`. But the durable resume unit is the **root** context: the async
handoff serializes `@context.root_context || @context`
(`lib/ruby_reactor/executor/step_executor.rb:199-206`), and the worker resumes
that root. For a top-level reactor `@context == root`, so today this is
invisible. For composed/nested reactors a sub-executor's `save_context` writes
the *sub*-context to its own key — never on the root's resume path.

**Implication:** the save-per-step checkpoint must serialize and store the
**root** context under the root's key, mirroring `handle_async_step`. A new
`checkpoint!` path (not the existing observability `save_context`) makes this
explicit.

### F2 — enqueue-before-persist ordering

Today the ensure-block `save_context` runs *after* `handle_async_step` has
already called `perform_async`. The job carries all state in its blob, so
storage lag is harmless. With an **identity-only** payload the worker rehydrates
from storage, so the context **must be persisted before the job is enqueued**.

**Implication:** `handle_async_step` must `checkpoint!` (store root) **before**
`async_router.perform_async`.

### F3 — `retrieve_context` returns a parsed Hash, not a Context

`RedisAdapter#retrieve_context` (`lib/ruby_reactor/storage/redis_adapter.rb:23-29`)
does `JSON.parse` and returns a Hash. The worker today calls
`ContextSerializer.deserialize(serialized_context)` which expects the raw JSON
**string** (it parses + schema-validates + `Context.deserialize_from_retry`).

**Implication:** rehydrate-by-id needs either (a) an adapter method that returns
the raw stored string, or (b) a `ContextSerializer.deserialize_hash(hash)` that
takes the already-parsed Hash. Option (b) is cleaner — no second parse — and
moves schema validation to a method that operates on the Hash. The
`DeserializationError` / `SchemaVersionError` handling in `Worker#perform`
**moves** from "decode the payload" to "rehydrate from storage."

### F4 — save-per-step needs a hook into `StepExecutor`

The per-step loop lives in `StepExecutor#execute_all_steps`
(`lib/ruby_reactor/executor/step_executor.rb:16-55`), which has no reference to
`save_context`. We inject a checkpoint callback from the Executor when
constructing the `StepExecutor` (it already receives a `managers:` hash).

### F5 — "id-only" payload still needs the class name

The storage key is `reactor:#{reactor_class_name}:context:#{context_id}`
(`redis_adapter.rb:319`). Rehydrate cannot build the key from the id alone.
Payload is therefore `(context_id, reactor_class_name, snooze_count)` — two small
strings, not one. (`reactor_class_name` is also already needed to reconstruct
`context.reactor_class` for anonymous/test classes — `worker.rb:34-42`.)

### F6 — map element / collector workers are a separate path (durable via Phase 5)

`MapElementWorker` and `MapCollectorWorker` (`lib/ruby_reactor/sidekiq_adapter.rb:20-84`)
do not flow through `Worker#perform`, and map element contexts carry
`parent_context_id` so `scan_reactors` skips them (`redis_adapter.rb:307`). The
Phase-3 sweeper therefore does **not** cover map fan-out — and maps are the path
**most** exposed to a hard kill (one lost element job hangs the whole map and its
parent forever). This is not deferred; it is **Phase 5**, which adds a dedicated
map sweeper. The key enabler: the storage already holds the full recovery state
(see Phase 5), so recovery is a matter of reading it, not adding new persistence.

### F7 — contention snooze does no work before snoozing

On the resume path, the lock/semaphore/rate-limit/ordered-lock contention errors
are raised at the **start** of `resume_execution` (before any step runs). So a
snooze re-enqueue never loses inline progress, and re-enqueuing by id (rehydrate
fresh) is safe. The per-context lock fits the same pattern: `wait: 0` →
`AcquisitionError` → existing snooze path.

### F8 — composed/nested sub-reactors build their own Executor + StepExecutor

A composed sub-reactor runs through a **fresh** `Executor` (and therefore a fresh
`StepExecutor`) created inside `ComposeStep.execute_child_reactor`
(`lib/ruby_reactor/step/compose_step.rb`). The per-step checkpoint callback (F4)
is injected when the Executor builds its `StepExecutor`, so it covers the
**top-level** executor only. If it is not propagated into child executors, a
crash mid-child re-runs the **whole child span**, not one step — the plan's
"only the in-flight step re-runs" claim then fails for composed reactors.

**Implication:** the `on_step_complete` callback must be wired into **every**
executor, including the nested ones `ComposeStep` constructs. This is safe and
correct because `checkpoint!` resolves `root = @context.root_context || @context`
— a child's checkpoint serializes and stores the **root**, not the sub-context.
The child execution path needs the callback; it does not need its own key.

### F9 — the Collector resumes the parent in-process and stores the *sub* context

`Collector.resume_parent_execution` (`lib/ruby_reactor/map/.../helpers.rb:55-116`)
resumes the map's parent **synchronously inside the collector worker** and stores
the updated **parent** context back to storage (~line 111-115). When the map is
embedded in a composed sub-reactor, "parent" is the **sub** context, so the
write lands under the sub's key — never the root. This is the F1 bug on the
collector path, and the Phase-2 `checkpoint!` (which only the `Worker#perform`
path calls) does **not** cover it.

**Implication:** with storage load-bearing and rehydrate-by-root-id, a nested map
completing leaves the **root blob stale** (it does not reflect the sub's
post-map progress). The collector's parent-resume must checkpoint the **root**
(via the same `checkpoint!` root resolution), not the sub context.

---

## Phase 0 — TTL config plumbing (prep, no behavior change)

Small, isolated, lands first to unblock later phases.

- Add `config.context_ttl` (default `86_400`) and `config.context_lock_ttl`
  (default `60`) to `Configuration`.
- Replace the hardcoded `ex: 86_400` for the **context** key in
  `RedisAdapter#store_context` with `config.context_ttl`. (Leave map/correlation
  TTLs alone for now.)

No new durability yet; just removes magic numbers the later phases tune.

---

## Phase 1 — Per-context lock (must land before the sweeper)

Reuse `RubyReactor::Lock` as verified in the investigation. **Key** =
`"async:#{context_id}"` (the root context id — the resume unit). **Owner** =
per-execution `SecureRandom.uuid`, *never* the context_id (reentrancy would
defeat the guard — investigation "Why `owner: context_id` is wrong").

### Edits

`lib/ruby_reactor/executor.rb`, in `resume_execution`:

Acquire **after** `enter_ordered_lock_scope` + the ordered-lock short-circuit
return (so drained/stale redeliveries that do no work never grab it), and
**before** `acquire_exclusive_lock` (~line 181):

```ruby
def acquire_context_lock
  @acquired_context_lock = RubyReactor::Lock.new(
    "async:#{(@context.root_context || @context).context_id}",
    owner: @context_lock_owner ||= SecureRandom.uuid,   # per-execution
    ttl: RubyReactor.configuration.context_lock_ttl,
    wait: 0,                                             # fail fast -> snooze
    auto_extend: true
  )
  @acquired_context_lock.acquire   # raises AcquisitionError on a live duplicate
end
```

Release in the existing `ensure` (next to `release_locks`, ~line 219):
`@acquired_context_lock&.release`.

`AcquisitionError` is already rescued at `executor.rb:206` → sets
`@contention_snooze` → re-raised → `worker.handle_snooze`. **Zero new error
handling.**

### Uncapped snooze for `async:` contention

Per investigation decision: a duplicate of the *same* execution can wait
arbitrarily long for the live original. In `Worker#handle_snooze`
(`lib/ruby_reactor/sidekiq_workers/worker.rb:89`), exclude
`Lock::AcquisitionError` whose key starts with `async:` from the cap, exactly as
`OrderedLock::WaitError` is excluded:

```ruby
capped = !(error.is_a?(RubyReactor::OrderedLock::WaitError) ||
           async_context_lock_error?(error))
```

The `Lock::AcquisitionError` message already embeds the key
(`"Could not acquire lock 'lock:async:...'"`). Cleanest: have the executor tag
the error (rescue → re-raise a marked error, or set an attr) rather than
string-match. Add a small `AcquisitionError#key` or a dedicated
`ContextLockContention` subclass to avoid brittle parsing.

### Why this is safe to ship alone

No sweeper yet → the same `context_id` never runs twice concurrently → the lock
is never contended. It is a no-op guard that becomes load-bearing in Phase 3.
Independently shippable and reversible.

### Tests

- Two `resume_execution` calls on the same `context_id` with overlapping
  lifetimes: second raises `AcquisitionError`, snoozes, succeeds after first
  releases.
- Owner is per-execution: simulate the reentrancy hazard — two executors,
  *same* context_id, assert the second is blocked (proves owner ≠ context_id).
- Nested/composed reactor: distinct context_ids → distinct keys → no
  self-contention (assert child resume does not block under parent's lock).
- Crash semantics: holder dies without releasing → TTL expiry → a later acquire
  succeeds (use a short `context_lock_ttl`).

---

## Phase 2 — Storage load-bearing (core change)

Three coupled changes; land together.

### 2a. `checkpoint!` — root-context, per-step durable save

Add to `Executor` a checkpoint that serializes the **root** context (F1) and
refreshes TTL (Phase 4 ties in here):

```ruby
def checkpoint!
  root = @context.root_context || @context
  storage = RubyReactor.configuration.storage_adapter
  name = root.reactor_class&.name || "AnonymousReactor-#{root.reactor_class.object_id}"
  storage.store_context(root.context_id, ContextSerializer.serialize(root), name)
end
```

Wire it into the per-step loop via the `managers:` hash (F4). In
`StepExecutor#execute_all_steps`, after a step returns a terminal-for-this-step
`Success` (i.e. the result was handled and recorded), invoke the injected
`on_step_complete` callback → `executor.checkpoint!`. Skip the checkpoint for
`AsyncResult` (handoff already persists, 2c) and `InterruptResult` (handle_interrupt
already saves) to avoid a double write.

Ordering inside a step is **side-effect → record result → checkpoint** so the
checkpoint reflects committed state (investigation hole #2).

**Propagate the callback into nested executors (F8).** `ComposeStep.execute_child_reactor`
builds a fresh `Executor`/`StepExecutor` for each composed sub-reactor; the
`on_step_complete` callback must be threaded into those too, or composed
reactors lose the per-step guarantee (a mid-child crash re-runs the whole child
span). Because `checkpoint!` resolves the **root**, a child's checkpoint stores
the root with the child state embedded — exactly what resume-by-root-id needs.
Regression test: checkpoint after a *sub-reactor's inner step* and assert the
**root** key advanced (not the sub key).

### 2b. Rehydrate-by-id in the worker

Change `Worker#perform` signature to
`perform(context_id, reactor_class_name, snooze_count = 0)`.

```ruby
def perform(context_id, reactor_class_name, snooze_count = 0)
  data = RubyReactor.configuration.storage_adapter
                    .retrieve_context(context_id, reactor_class_name)
  return if data.nil?  # swept/expired/lost — nothing to resume

  context = ContextSerializer.deserialize_hash(data)   # F3
  # ... existing reactor_class resolution, inline_async_execution = true, resume ...
rescue RubyReactor::Error::DeserializationError,
       RubyReactor::Error::SchemaVersionError => e
  handle_deserialization_failure(context_id, reactor_class_name, e)  # now id-based
end
```

- Add `ContextSerializer.deserialize_hash(hash)` (F3): schema-validate +
  `Context.deserialize_from_retry(hash)`. Refactor `deserialize(string)` to
  `deserialize_hash(JSON.parse(string))`.
- `handle_deserialization_failure` / `extract_failure_metadata` no longer parse
  a payload blob — they already have `context_id` and `reactor_class_name`.
  Simplify accordingly.
- The post-run `executor.save_context unless skip_context_persist?` at
  `worker.rb:55` stays (final terminal save), but should call `checkpoint!`
  semantics (root-context). Audit: with save-per-step the final save is
  partially redundant but cheap and ensures terminal status lands.

### 2c. Identity-only enqueue

`SidekiqAdapter.perform_async` /`perform_in` (`lib/ruby_reactor/sidekiq_adapter.rb:5-17`):
enqueue `(context_id, reactor_class_name)` instead of the serialized blob.

`handle_async_step` (`step_executor.rb:193-213`): **persist root, then enqueue**
(F2):

```ruby
def handle_async_step(step_config)
  @context.current_step = step_config.name
  @context.undo_stack   = @compensation_manager.undo_stack
  context_to_serialize  = @context.root_context || @context

  @middlewares.on(:before_async_enqueue, context_to_serialize)

  # Persist BEFORE enqueue: the job carries only the id now.
  checkpoint_root!(context_to_serialize)            # store root in storage

  configuration.async_router.perform_async(
    context_to_serialize.context_id,
    context_to_serialize.reactor_class.name
  )
end
```

`AsyncResult` still needs `execution_id`/`intermediate_results` for the return
value — build it from the in-memory context in `perform_async` (it no longer
deserializes a blob to get `context_id`; it receives it directly).

`handle_snooze` (`worker.rb:97`) and `escalate_snooze` re-enqueue / persist by
id — they already have `context` in scope; just pass `context_id` +
`reactor_class_name`.

### Behavior-preservation argument

Rehydrate-by-id is behavior-identical to the old blob path **as long as the
stored serialized form equals what `handle_async_step` would have enqueued** —
which it does, because both call `ContextSerializer.serialize(root)`. The only
intended difference: save-per-step advances the stored `current_step` /
`intermediate_results` past the async boundary, shrinking the re-run blast
radius. `first_execution?` semantics are unchanged (current_step is still set by
`handle_async_step` exactly as before).

### Tests

- Crash mid-inline-span: kill after step N of an inline async span; resume
  (rehydrate by id) starts at step N+1, not at the async boundary. Assert
  earlier steps' side effects ran once.
- Stale-payload bug gone: a retry rehydrates fresh state and skips
  already-completed steps.
- `deserialize_hash` round-trips a stored context identically to the old
  string path (golden test against existing serialization fixtures).
- Worker with a missing/expired id returns cleanly (no crash) — precondition for
  the sweeper.
- Nested/composed: a checkpoint after a sub-reactor step stores the **root**
  with the child state embedded (regression guard for F1).
- Composed per-step durability (F8/C1): kill mid-child after sub-step N → resume
  rehydrates root, child resumes at sub-step N+1 (not the start of the child
  span). Proves the `on_step_complete` callback is wired into nested executors.

---

## Phase 3 — Sweeper (depends on Phase 1)

One mechanism, two holes: the per-context lock's presence is the liveness signal
(investigation "One lock, two holes").

### Logic

```text
for each {id, class, status} in storage.scan_reactors:
  next unless status == "running"            # non-terminal only
  next if live_lock?("async:#{id}")          # worker alive -> leave alone
  Worker.perform_async(id, class)            # died/lost -> re-enqueue by id
```

- `live_lock?` = adapter check for `lock:async:#{id}` existence (reuse
  `lock_info` / a thin `lock_held?`). Lock auto-extends every `ttl/3` while a
  worker runs, so absence = death.
- `scan_reactors` already returns `{id, class, status}` and already filters out
  nested/map contexts (parent_context_id). Good for top-level reactors; map
  elements remain uncovered (F6).
- Re-enqueue is trivial because the payload is now identity-only (Phase 2).

### Packaging — pluggable driver (decided)

Ship a `Sweeper` class exposing a pure, testable `run_once` (scan + re-enqueue)
and a documented interface; **do not bake in a schedule**. The host app wires
the cadence (sidekiq-cron, sidekiq-scheduler, a self-rescheduling worker, or an
external cron hitting `run_once`) however it prefers. Provide a thin
`Sweeper.run_once` entry point and document the contract: call it periodically,
it is idempotent, interval bounds recovery latency. No scheduling dependency
added to the gem.

### Safety

The lock (Phase 1) is exactly what makes a mis-judged "dead" worker safe: if the
sweeper re-enqueues a context whose worker is actually alive (GC pause, liveness
race), the duplicate hits the live lock → `AcquisitionError` → uncapped snooze →
no double execution. **Phase 1 must be in place first.**

### Tests

- Running context, no lock → re-enqueued.
- Running context, live lock → skipped.
- Terminal context (completed/failed/skipped) → skipped.
- Sweeper re-enqueues a still-alive context → duplicate snoozes, original
  finishes, exactly one execution (integration with Phase 1).
- `run_once` is idempotent across back-to-back runs (no double enqueue within a
  sweep if it re-enqueues then immediately re-scans).

---

## Phase 4 — TTL refresh / alignment

With storage load-bearing, a long-running or snoozed context must not expire
mid-flight (investigation hole #4).

- `checkpoint!` / `store_context` refreshes the context TTL on every write (the
  `SET ... ex:` already re-stamps it — confirm each save path goes through it).
- Set `config.context_ttl` to comfortably exceed the max snooze/retry window
  (`lock_snooze_*`, `sidekiq_retry_count`, ordered-lock `poison_pill_timeout`).
  Document the relationship so operators tuning one tunes the other.
- The `async:` lock TTL (`context_lock_ttl`, default ~60) is independent and
  short — it is liveness, not retention. Auto-extend keeps a live worker's lock
  fresh regardless.

### Tests

- A context checkpointed repeatedly over a span longer than `context_ttl` never
  expires (TTL re-stamped each save).
- An idle (snoozed, not checkpointing) context still outlives its max snooze
  window because the TTL exceeds it.

---

## Phase 5 — Map durability (depends on Phase 1)

Maps are the path **most** exposed to a hard kill: a single lost element job
hangs the entire map and its parent forever. The good news established by the
investigation: **storage already holds the full recovery state** — we recover by
reading it, not by adding new persistence.

### The holes (under OSS hard kill)

| # | Crash point | Effect today |
| - | ----------- | ------------ |
| M1 | element worker killed mid-run | result never stored, counter never decremented → Collector never fires → parent hangs forever |
| M2 | collector worker killed | all results present, parent never resumed → hang |
| M3 | element re-run (sweeper/super_fetch) | counter double-decremented → may go negative → `new_count.zero?` never true → hang |
| M4 | dispatcher killed after `increment_map_offset`, before enqueue | batch reserved but never queued → those indices never produce results → hang |
| M5 | batch-continuation element lost | `trigger_next_batch_if_needed` never fires → tail batches never dispatched → hang |

### The unifying insight: results-count is the authoritative, idempotent signal

`store_map_result(map_id, index, value)` is an HSET keyed by index
(`redis_adapter.rb:31-44`) — **idempotent**: a re-run of index `i` overwrites the
same slot. So the durable truth of "what is done" is
`present = HKEYS(map:ID:results)`, and `missing = (0...count) - present`. The
`map:ID:counter` is merely a *trigger* and is the source of the M3 fragility.

> **Strict-ordering storage is a precondition (M1).** The idempotent HSET path
> only applies when `strict_ordering: true` (`redis_adapter.rb:37`). With
> `strict_ordering: false` the adapter uses `rpush` (`redis_adapter.rb:40`):
> there is **no index→slot mapping** (so `missing` is uncomputable) and `rpush`
> is **not idempotent** (so a re-dispatch *duplicates* results). The entire
> Phase-5 recovery model breaks for loose maps.
>
> **Decision: when durability is enabled, store map results index-keyed (HSET)
> regardless of `strict_ordering`.** Loose ordering is purely a *read-order*
> convenience for the collector; it does not require list storage. Change
> `store_map_result` to always HSET-by-index under the durable path, and have the
> loose-ordering collector read `HVALS`/sort-by-key as needed instead of relying
> on insertion order. This makes `missing`-based recovery and idempotent
> re-dispatch apply uniformly. (If a host ever needs true append semantics, the
> map sweeper must skip those maps and they are documented non-durable — but the
> default and recommended path is index-keyed.)

**Decision: make completion authoritative on results-count, not the counter.**
The Collector already gates on `results_count < total_count`
(`collector.rb:37`). We make the *trigger* robust by recovering off `missing`,
and treat the counter as a best-effort fast-path only (it may be wrong; the
results hash is never wrong). Recovering off `missing` subsumes M1, M4, and M5 in
one mechanism — any index not in `results`, however it got lost, is re-dispatched.

### 5a. Enrich map metadata for recovery

`initialize_map_operation` (`redis_adapter.rb:64-77`) stores
`{count, strict_ordering, reactor_class_info, created_at}`. Add
`parent_context_id`, `step_name`, and `parent_reactor_class_name` so a sweeper
that finds a map by scanning has everything to re-dispatch elements and
re-trigger the collector without reconstructing the map_id. (`map_id` =
`"#{parent_context_id}:#{step_name}"` is *derivable* but splitting on `:` is
brittle if a step name ever contains one — store it explicitly.)

Also record the **parent's lock kind** (N1): for a **nested** map — one whose
parent context is itself a map *element* — store `parent_is_map_element: true`
plus the parent element's `outer_map_id` and `outer_index`, so the sweeper can
check the correct liveness lock (`map_element:…`) instead of assuming `async:`.
A top-level or composed-reactor parent stores neither flag and the sweeper uses
`async:#{parent_context_id}`. The element executor already carries
`map_metadata` (`element_executor.rb`), so a map dispatched *from within* an
element has these values in scope at `initialize_map_operation` time.

### 5b. Element-level lock (reuse Phase 1 primitive)

Mirror the per-context lock at element granularity in `ElementExecutor.perform`:

- **Key** = `"map_element:#{map_id}:#{index}"` (the resource = one element slot).
- **Owner** = per-execution `SecureRandom.uuid`.
- `wait: 0`, `auto_extend: true`, `ttl: context_lock_ttl`.

Acquired before running the element, released in `ensure`. This makes the lock's
**presence the element's liveness signal** for the map sweeper, exactly as the
`async:` lock does for the reactor sweeper. A duplicate delivery of a live
element is blocked (snooze/return); a dead element's lock expires → re-dispatch
is safe. Skip storing a result before acquiring (`store_map_element_context_id`
is fine; it is idempotent rpush — though consider dedup).

### 5c. Re-dispatch-by-index in the Dispatcher

The Dispatcher currently dispatches forward batches by reserving offset
(`dispatcher.rb:63-105`). Add a path to (re)queue a **specific set of indices**:
resolve the source from the stored parent context (`resolve_source`, already
present), pick `source[i]` for each missing `i` (Array → `slice`; query builder →
`offset(i).limit(1)`), and `queue_element_job(element, i, ...)`. This is the same
machinery, just index-driven instead of offset-driven.

### 5d. Map sweeper

Driven the same pluggable way as Phase 3 (`run_once`, host wires cadence).
Needs an enumerator of active maps: add `scan_maps` to the adapter (SCAN
`reactor:*:map:*:metadata`, parse each). Then per map:

```text
for each map {map_id, count, parent_context_id, step_name, class} in scan_maps:
  present  = HKEYS("reactor:CLASS:map:MAP_ID:results")
  missing  = (0...count) - present
  if missing.any?:
    for i in missing:
      next if live_lock?("map_element:MAP_ID:#{i}")   # element alive -> skip
      Dispatcher.requeue_index(map_id, i, ...)         # 5c
  else:
    # all results in; did the parent resume?
    next if terminal?(parent_context_id)               # already collected
    next if parent_live_lock?(map_meta)                # collector/parent running
    re-trigger Collector(map_id, parent_context_id, ...)# M2 recovery
```

- `live_lock?` reuses the Phase-1/Phase-3 helper.
- Re-dispatch only indices with **no live element lock** → a slow-but-alive
  element is never double-run; the lock (5b) makes the sweeper safe, same as the
  reactor sweeper relies on the `async:` lock.

#### Parent liveness key must match the parent's actual lock (N1 — nested maps)

The collector re-trigger is gated on the parent **not** being terminal and
**not** holding the lock under which the parent execution actually runs. For a
**top-level or composed** parent that lock is `async:#{parent_context_id}`. But
for a **nested** map (a map whose parent is itself a map *element*), the parent
holds **no** `async:` lock — it runs under the element lock
`map_element:#{outer_map_id}:#{index}` (5b). Checking `async:#{parent_context_id}`
for a nested map therefore always reads "absent" → the sweeper would re-trigger
the nested collector / re-dispatch **while the element parent is alive**.

**Fix:** the sweeper derives the parent's lock key from map metadata, not by
assuming `async:`:

```text
def parent_live_lock?(map_meta):
  if map_meta.parent_is_map_element:                   # nested map
    live_lock?("map_element:#{map_meta.outer_map_id}:#{map_meta.outer_index}")
  else:                                                # top-level / composed parent
    live_lock?("async:#{map_meta.parent_context_id}")
```

This requires 5a to record, for a nested map, that its parent is a map element
plus the `outer_map_id` / `outer_index` that identify the element's lock. A
top-level/composed map stores neither and falls to the `async:` branch.

Symmetrically, 5e's parent-resume lock must be the **same** key — a nested map's
collector resuming its element-parent must take that element's `map_element:`
lock, not an `async:` lock the element never holds.

### 5e. Collector's parent-resume must take the parent lock

`Collector.resume_parent_execution` (`helpers.rb:55-116`) resumes the parent
**synchronously inside the collector worker**, not via `Worker#perform`. Two
collector deliveries (e.g. the eager queue at dispatch + the counter-zero
trigger + a sweeper re-trigger) could resume the parent concurrently and both
write its context. Wrap the parent resume in the **parent's lock** (Phase 1
primitive, `owner` per-execution) so only one resume runs; the loser no-ops.
This closes the double-collector race that Phase 5d's re-trigger would otherwise
introduce — the same "the recovery layer creates the race, the lock pays for it"
pattern as the reactor sweeper.

**Use the parent's actual lock key (N1).** For a top-level/composed parent the
key is `async:#{parent_context_id}`; for a **nested** map whose parent is a map
element it is `map_element:#{outer_map_id}:#{outer_index}` — the same key 5d's
`parent_live_lock?` checks. The two must agree or the sweeper's liveness gate and
the resume guard protect different keys.

**Checkpoint the root, not the sub (F9 / C2).** `resume_parent_execution`
currently stores the resumed **parent** context under the parent's own key
(`helpers.rb:111-115`). When the map is embedded in a composed sub-reactor the
parent is the *sub* context, so the **root blob never advances** and a
rehydrate-by-root-id resume loses the map's completion. The parent resume must
persist via the same root-resolving `checkpoint!` (`root = parent.root_context ||
parent`) used on the `Worker#perform` path — store the **root**, with the sub's
post-map state embedded in `composed_contexts`. Regression test: map inside a
composed reactor completes → assert the **root** key reflects the sub's
post-collect progress.

### Residual after Phase 5

- **One element may re-run** on crash (at-least-once), same irreducible residual
  as the main path — element steps with side effects must be idempotent.
- **Element re-dispatch is from-scratch, not per-step (M2).** `ElementExecutor`
  mints a fresh context unless a `serialized_context` is supplied
  (`element_executor.rb` hydrate path), and 5c re-queues by *index* with inputs,
  not a checkpoint. So an element's **internal** multi-step / async progress is
  not individually durable across re-dispatch — the **whole element** re-runs.
  This is acceptable (it is the same at-least-once residual, one element wide),
  but it means the "only one in-flight *step*" guarantee is "only one in-flight
  *element*" for map fan-out. Document it; if per-step durability inside elements
  is ever needed, 5c must re-queue the element's stored checkpoint instead of
  fresh inputs.
- **Element-hosted sub-work stalls (N2).** A map element that itself runs a
  composed reactor or a nested map is a `parent_context_id`-bearing context, so
  `scan_reactors` skips it (`redis_adapter.rb:307`) — correctly, since the map
  sweeper owns it. The map sweeper recovers the element's **nested map**
  (via 5d) and re-dispatches the **whole element** if its result slot is missing
  (M2), but it does not separately recover the element's *own* non-map async
  steps mid-flight — those fold into the whole-element re-dispatch. Bounded and
  acceptable; stated here so it is not mistaken for per-step element recovery.
- **Nested maps** (a map element that itself contains an async map) inherit the
  same recovery, since each level has its own map_id/metadata; the `scan_maps`
  pattern catches them as long as their metadata key matches. Their parent
  liveness/resume lock is the element lock, not `async:` — see N1 in 5d/5e.

### Tests

- M1: kill an element mid-run (no result stored) → sweeper re-dispatches that
  index → map completes → parent resumes. Exactly-once result per index.
- M2: all results present, collector job dropped → sweeper re-triggers collector
  → parent resumes once.
- M3: force a double element run → counter goes wrong → completion still
  detected via results-count; no hang.
- M4: kill dispatcher after offset reserve, before enqueue → reserved indices are
  `missing` → sweeper re-dispatches them.
- M5: drop the batch-boundary element → next batch never auto-dispatched →
  sweeper re-dispatches the missing tail.
- Element lock: duplicate delivery of a live element is blocked; one result.
- Collector concurrency: two collector deliveries → parent resumes exactly once
  (parent lock).
- M1 (loose ordering durable): a `strict_ordering: false` map stores results
  index-keyed under the durable path; re-dispatching index `i` overwrites slot
  `i` (no duplicate), and `missing` is computable.
- C2 (map in composed reactor): a map embedded in a composed sub-reactor
  completes → the **root** key reflects the sub's post-collect progress (not just
  the sub key); a rehydrate-by-root-id resume continues past the map.
- N1 (nested map liveness): a nested map whose element-parent is alive
  (`map_element:` lock held) is **not** re-triggered/re-dispatched by the
  sweeper; once the element dies (lock expired) recovery proceeds.

---

## Sequencing summary

| Phase | What | Depends on | Shippable alone |
| ----- | ---- | ---------- | --------------- |
| 0 | TTL config plumbing | — | yes (no-op) |
| 1 | Per-context lock (per-execution owner) + uncapped `async:` snooze | 0 | yes (no-op until 3) |
| 2 | Save-per-step + rehydrate-by-id + identity-only payload | 0 | yes |
| 3 | Sweeper (top-level reactors) | 1, 2 | yes |
| 4 | TTL refresh / alignment | 0, 2 | yes |
| 5 | Map durability (element lock + results-based completion + map sweeper) | 1, 2 | yes |

Land 0 → 1 → 2 → 3 → 4 → 5. Each is independently reversible. Hard ordering
constraints: **1 before 3** (the lock makes the reactor sweeper safe), **2's
enqueue-before-persist** (F2) within phase 2, and **1 before 5** (the element
lock and the collector's parent-resume lock both reuse the Phase-1 primitive).
Phase 5 is independent of 3/4 and can land in parallel with them.

Two cross-cutting constraints the phases above fold in:

- **Composed reactors (F8/C1):** Phase 2's `on_step_complete` callback must reach
  the nested executors `ComposeStep` builds, or composed reactors lose the
  per-step guarantee. In-phase-2 work, not a separate phase.
- **Maps in composed reactors (F9/C2):** Phase 5's collector parent-resume must
  checkpoint the **root** (not the sub context). Depends on Phase 2's `checkpoint!`
  root resolution existing.

---

## Residual risks after this work (accepted)

Carried over from the investigation, restated as what remains true post-implementation:

1. **In-flight step idempotency is irreducible.** Re-run blast radius is one
   step. Side-effecting steps must be idempotent; offer an opt-in
   `context.idempotency_key` (stable hash of `context_id + step_name`) for
   side effects that support dedup. Document as developer responsibility.
2. **Map fan-out: one element may re-run** on crash (Phase 5 covers recovery via
   the map sweeper; the at-least-once residual is the same as the main path —
   element steps must be idempotent). No longer a hang; bounded by the map
   sweeper interval.
3. **Schema strictness.** No back-compat needed today (no production, single
   `SCHEMA_VERSION`). A version mismatch is a permanent failure — acceptable. A
   serializer/migration ships with the first `SCHEMA_VERSION` bump, not now.
4. **Sweeper interval bounds recovery latency** for lost jobs. Tunable.
5. **Save cost:** one extra Redis write + full root re-serialize per step. Watch
   large contexts; revisit compression (`ContextSerializer.compress_if_needed`
   is currently a no-op stub — a natural lever) if it bites.
</content>
</invoke>
