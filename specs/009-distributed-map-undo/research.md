# Research: Distributed Map Rollback and Bounded Fan-out

**Feature**: [spec.md](spec.md) | **Plan**: [plan.md](plan.md) | **Date**: 2026-09-30, revised
the same day after `/speckit-analyze` (R-02, R-04, R-05, R-06, R-07, R-09, R-12, R-15, R-16)

Each decision gives the choice, why, and what was rejected. File references are to the code as of
`21a4c59f` (008 merged).

## Current behavior (verified in code)

| Question | Answer | Where |
| --- | --- | --- |
| Does a fan-out map's rollback run inline, loading every element? | Yes. `MapStep#compensate` reads the whole element-context index (`LRANGE 0 -1`), loads **every** row, deserializes all of them, sorts by index, then undoes each one serially in the process that detected the failure. `batch_size` plays no part. | `step/map_step.rb` `#compensate`, `#completed_elements` |
| Where does a fan-out map's failure get rolled back? | In the **collector** job: `Map::Helpers#resume_parent_execution` runs `handle_step_failure` for the map step there, holding only the `map_collect:` lock, never the parent's `async:` lock. | `map/helpers.rb`, `map/collector.rb` |
| What does `fan_out` without `batch_size` do? | Batch size falls back to `source.size`: one batch, every element enqueued at once. | `MapStep#dispatch_async_map`, `Dispatcher.dispatch_batch` |
| What is the forward back pressure exactly? | `batch_size` jobs are enqueued per throw. When the element at position `k*B - 1` finishes, the next `B` are enqueued. The trigger depends only on position, so other elements of earlier batches may still be running. A slow element never holds back later batches, and outstanding jobs are not bounded, only each throw is. | `ElementExecutor.trigger_next_batch_if_needed` |
| Why does a fan-out map inside a composed child hang? | `prepare_async_execution` stores the child under its own id. The collector loads that blob, whose `root_context` is nil, and resumes the child as a standalone run. Nothing ever resumes the root. | `map/helpers.rb` `#resume_parked_aware` (ponytail note) |
| What does `fail_fast` mean? | On (the default): the first element failure fails the map, stops dispatch, and rolls back every completed element. Off: the map completes with per-element `Result`s, failed elements roll themselves back, succeeded ones are kept. That is atomic versus partial. | `MapStep#execute_inline_map`, `ElementExecutor.handle_result`, `Dispatcher.dispatch_batch` |
| Does the map sweeper keep `batch_size` / `fail_fast` when it re-dispatches? | No. `requeue_index` reads `map_meta["batch_size"]` and `map_meta["fail_fast"]`, but `initialize_map_operation` never stores them. A re-dispatched element therefore loses `atomic` and stops triggering batches. This is a latent bug, fixed by R-10. | `storage/redis_adapter.rb#initialize_map_operation`, `Dispatcher.requeue_index` |

---

## R-01: Rollback mirrors execution mode

**Decision**: A map rolls back where its elements ran:

- A fan-out map dispatches one rollback job per completed element (R-02 to R-09).
- An inline map rolls back in the executing process, but reads element states in chunks of
  `Map::ROLLBACK_CHUNK` (100) from the tail of the element index, never all at once.

**Rationale**:

- This is the user's rule ("rollback each map reactor the same way we execute them").
- An inline map is already bounded by one process's execution, so its rollback is not the scaling
  problem. What makes it grow is the all-at-once read, and chunking removes that.

**Alternatives rejected**:

- Distribute inline maps' rollback too. That adds a hand-off to runs that never had one (a
  synchronous `Reactor.run` would return a `DispatchResult` from a failure).
- Leave inline rollback unchanged. That keeps the O(n) load that FR-012 removes.

## R-02: Back pressure is the forward batch mechanism, reused

**Decision**: Rollback jobs are dispatched exactly as forward element jobs are:

- Claim `B` positions with one atomic offset increment and enqueue them.
- When the job at position `k*B - 1` settles, the next batch is claimed.
- `B` is the map's effective batch size (R-10).

The spec bound (FR-002, FR-018, SC-001, SC-004) is "no throw enqueues more than `B`; the next
throw fires when the previous throw's last position reports". There is **no** bound on outstanding
jobs: the trigger fires on position alone, so a lagging element in batch `k` does not stop batches
`k+1`, `k+2` and so on. An earlier draft claimed "at most two batches outstanding". That only holds
when jobs finish in queue order, and it was dropped after `/speckit-analyze` (A1). The tests assert
the per-throw burst (`QueueProbe` `max_burst`), never queue depth.

**Rationale**:

- "Same way we execute them."
- One mechanism, one bound to document.
- The user's framing is per throw ("max amount of elements to fan out in a single throw").

**Alternatives rejected**:

- **Sliding window** (each settled job enqueues exactly one more; a strict `≤ B` outstanding). For
  a database source the forward path would fetch one record per job (`offset(i).limit(1)`)
  instead of one query per batch. It would also make forward and rollback diverge unless both
  changed, and changing forward is out of scope.
- **Per-batch settle counter** (next batch only when the whole batch settled). This would bound
  outstanding jobs at `B`, but it costs one more counter per map, stalls throughput on one slow
  element, and diverges from forward. It can be revisited if unbounded lag ever matters in
  practice.

## R-03: Map completion resumes the owner run; `MapStep#run` adopts the settled outcome

**Decision**: The collector stops writing any context:

- **Collector**: once every index has a result slot, it claims `map:<id>:owner_signalled`
  (`SET NX`) and enqueues the **owner's** `Worker`. The owner is the top-level run,
  `context.root_context || context`, whose id and class are now stored in the map metadata
  (`owner_context_id`, `owner_reactor_class_name`).
- **Owner Worker**: resumes as it does for any hand-off. The map step is not in
  `intermediate_results`, so `MapStep#run` runs again, at any composition depth
  (root → `ComposeStep#run` → child `resume_execution` → `MapStep#run`).
- **Re-entry**: `context.map_operations[step]` is set, so `MapStep#run` adopts instead of
  dispatching:
  - settled with an atomic failure: return the failing element's `Failure`, carrying its
    `rollback_failures` (moved from `Collector.handle_failure`);
  - settled otherwise: return `Success(collect(ResultEnumerator))` (moved from
    `Collector.apply_collect_block`), and record `started` on the map reference (moved from
    `Helpers#record_elements_started`);
  - not settled (an early or duplicate resume, or a sweeper re-enqueue): return the
    `DispatchResult` again, without dispatching anything.
- **Failure path**: an adopted `Failure` goes through the executor's normal failure handling.
  `handle_step_failure` compensates the map (R-04 distributes it) and the run rolls back as any
  step failure does.
- **Deleted**: `Map::Helpers#resume_parent_execution`, `#resume_parked_aware`, `#store_parent`,
  `#record_elements_started`, and the `inline_async_execution = true` workaround.
- **`prepare_async_execution`**: stores the owner tree (`root_context || context`) under the
  owner id before dispatch, as `handle_background_handoff` already does, so a fast resume finds a
  consistent root. It also keeps storing the child snapshot, which the dispatcher reads to resolve
  the source.

**Rationale**:

- Fixes "Fan-out map inside a composed child" by the direction `future_improvements.md` already
  records.
- The same change removes the collector's failure-branch write, which that file lists as a writer
  outside a controlled execution.
- It gives forward and rollback one mechanism: settle, signal the owner once, and the construct
  adopts on re-entry.
- Adoption is idempotent, so a spurious resume (the general sweeper re-enqueues any `running`
  context with no `async:` lock) no longer risks dispatching a map twice.

**Alternatives rejected**:

- **Collector writes the root blob.** This breaks the single-writer rule: the collector never holds
  the root's `async:` lock.
- **Collector resumes the root inline.** Same lock problem, and the collector keeps a second copy
  of the executor's failure path.
- **Keep the root-level path, special-case only composed children.** That leaves two completion
  paths and the collector's failure-branch write.

**Cost**: One extra job hop (collector → owner Worker) on every fan-out map completion. The owner
Worker contends on the `async:` lock if the dispatching worker still holds it, and snoozes
uncapped until it is released (existing behavior for that lock).

**Implementation notes** (found while implementing):

- `ComposeStep#compensate` / `#undo` now link the stored child to its parent and root, as
  `#run` does. Unlinked, a fan-out map inside the child recorded the child as its owner during
  rollback, and the rollback resumed the child's standalone row instead of the root.
- The `DispatchResult` a fan-out map returns carries the owner's `execution_id`, not the composed
  child's: it is what the caller of `Reactor.run` holds and looks the run up by.
- **An interrupt inside a composed child is unsupported on main, fan-out or not**: `ComposeStep`
  fails the step (`NoMethodError` on `InterruptResult#success?`). US2-AS2 (T052(b)) is out of reach
  without that separate capability; its example is `pending` with the reason.

## R-04: Rollback can hand off and resume (`Error::RollbackHandedOff`)

**Decision**: A construct whose rollback is distributed (`MapStep#compensate` / `#undo` on a
fan-out map) starts the map rollback (R-06), then raises `Error::RollbackHandedOff`.

**How the signal unwinds**:

- `CompensationManager#rollback_completed_steps` pops an entry only after its undo returns, so the
  map entry stays on the undo stack. Entries already undone are gone.
- A **composed child's** executor rescues the signal, records its own `rollback` state (below) on
  the child context, and re-raises. The root embeds the child, so the root's save persists it.
- **`Executor#undo_all`** does the same at its own level. This is the path manual undo and
  `ComposeStep#compensate` take into a child: they call the child executor's `undo_all`, never its
  `execute` / `resume_execution`.
  - On a hand-off it writes `@context.rollback["failures"]` from its compensation manager and
    re-raises.
  - On entry, when `@context.rollback` is present, it restores those failures first, and clears
    them when it finishes.
  - Without this, a child's rollback failures collected before the hand-off would be lost, because
    the child executor is rebuilt on resume (`/speckit-analyze` G2).
- The **top-level** executor (`execute` / `resume_execution` / `resume_rollback`) rescues the
  signal before `rescue Error::Rescuable` and `rescue Exception`. It records the run's `rollback`
  state, sets status `rolling_back`, and **saves inside the rescue body, while it still holds the
  context lock** (R-13). It returns a `DispatchResult` (`job_id: "map_rollback:<map_id>"`).
- **`Reactor#undo`** (manual) rescues it the same way (R-12).

**`Error::Rescuable` does not match `RollbackHandedOff`**: it is a control signal, not a failure.
This lets it pass through the `rescue Error::Rescuable` sites between the raise and the handler:

- `CompensationManager#compensate_step_body` and `#undo_step` (they wrap `call_undo`, which is
  where `MapStep#undo` runs);
- `StepExecutor#safe_execute_step_sync` (a child's rollback inside `ComposeStep#run`);
- `Executor#aborting_on_interruption`, which must not mark the run `aborted` on it.

**`rollback` state on the context** (data-model.md): `trigger` (`failure` | `undo`), `step` (the
failing step, or nil), `compensated`, `failure` (the triggering `Failure`, serialized), and
`failures` (rollback failures collected so far).

**Resuming**: `Worker#perform` sees `rolling_back` and calls `Executor#resume_rollback`, which runs
under the context lock:

1. Restores `rollback_failures` from the saved state.
2. If `compensated` is false, compensates the failing step. Only constructs can hand off, and they
   read their state from the context, so arguments are `{}`. A map re-enters and adopts; a compose
   continues its child's rollback.
3. Runs `rollback_completed_steps`.
4. Finalizes:
   - `failure` trigger: rebuild the `StepFailureError` from the saved failure and call
     `result_handler.handle_execution_error`. This is the code
     `Helpers#resume_parent_execution` has today, moved into the executor, so the final `Failure`,
     the `CompensationError` rule and the `rollback_failures` shape are unchanged.
   - `undo` trigger: status `cancelled`, reason "Undo triggered".
   - Either way, `rollback` is cleared.

**Rationale**:

- The undo stack already makes rollback resumable: entries pop only when done (008 R-16). What was
  missing is a signal that stops the loop cleanly, and a place to store the trigger.
- Raising matches how parks unwind (`ExecutionParked`) through the same stack depth.

**Alternatives rejected**:

- **Return a sentinel result from `#undo`.** It would have to be plumbed through
  `rollback_completed_steps`, `handle_step_failure`, three `ResultHandler` branches,
  `ComposeStep#compensate` and `Reactor#undo`, and every intermediate caller would have to learn
  it.
- **Wait in place** (the coordinating job polls until element rollbacks finish). This holds a worker
  for the whole rollback, hits job timeouts and shutdown (`Sidekiq::Shutdown` is an interruption,
  so the run would be marked `aborted`), and still needs resumption after a crash.
- **Subclass `ExecutionParked` and snooze-poll.** Every poll reloads the parent blob. The trigger
  plus sweeper is how the forward path already works.

**Implementation notes** (found while implementing):

- **The final Failure is captured at the hand-off, not rebuilt at resume.** The `ResultHandler`
  the signal passes through sets `RollbackHandedOff#failure` to the exact Failure the run will end
  with (`failure_for` of the `StepFailureError` it would raise, minus rollback failures), and the
  executor saves it in `rollback["failure"]`. `resume_rollback` adds the rollback failures. Rebuilding
  a `StepFailureError` from the saved Failure loses `step_arguments`, `validation_errors` and the
  code location; capturing keeps every field, so I-7 holds exactly.
- `rollback["compensation_error"]`: the failing step's compensate returned a Failure before the
  rollback handed off, so the resume ends with that `CompensationError`, as inline.
- **A third trigger, `step`.** When a composed child hands off from inside `ComposeStep#run` (the
  child's own step failed), the root has no rollback of its own yet. The root records
  `{trigger: "step"}` and, on resume, runs forward again: `ComposeStep#run` re-enters the child,
  which is `rolling_back` and finishes its own rollback (`resume_rollback` at the child level), and
  the child's Failure then rolls the root back exactly as the inline path does. T057's plan
  (compensate the compose step with `compensated: false`) would report the child's rollback
  failures as a `CompensationError`, which diverges from the inline Failure (I-7).
- `Executor#resume_execution` delegates to `resume_rollback` for a `rolling_back` context, which
  is how a composed child re-enters; `Worker` routes a `rolling_back` row there directly.

## R-05: Exactly-once owner resume; recovery

**Decision**:

- **Owner resume**: a two-flag handshake, so the owner is enqueued only after its hand-off is
  saved, exactly once, whichever side finishes last.
  - **Hand-off side**: the top-level handler (`Executor` rescue, or `Reactor#undo`) saves the
    context, then sets `map:<id>:rollback:handed_off` (`SET`). It then checks
    `count_map_rollback_outcomes == total`. If the map has settled and it claims
    `map:<id>:rollback:signalled` (`SET NX`), it enqueues the owner's `Worker`.
  - **Job side**: the element rollback job that stores an outcome checks settled. If the map has
    settled **and** `handed_off` is set **and** it claims `signalled`, it enqueues the owner's
    `Worker`.
  - **Why it is exactly once**: whichever side observes both conditions second enqueues, and the
    claim makes it once.
  - **Why the Worker never sees a stale blob**: it is enqueued only after `handed_off`, which is set
    after the save. The owner's `async:` lock still serializes it against the handler's release.
- **Inline test mode** (`Sidekiq::Testing.inline!`): element jobs run inside dispatch, so every
  outcome is stored before `MapStep#undo` returns and before any `handed_off` flag exists. No job
  enqueues the owner. `#undo` checks settled right after dispatching and aggregates synchronously;
  there is no hand-off. This decides `/speckit-analyze` U3 in the design instead of leaving it to
  implementation.
- **Recovery**:
  - **General `RubyReactor::Sweeper`**: treats `rolling_back` like `running`. With no `async:` lock
    held, it re-enqueues the owner. On re-entry an unsettled map rollback raises the hand-off again,
    so this is harmless.
  - **`Map::Sweeper`**: gains a rollback pass. For each map with rollback metadata, it
    re-dispatches positions below the claimed offset that have no outcome and no live element lock.
    It also claims positions never dispatched when their batch trigger was lost.

**Rationale**: This mirrors the forward map's recovery split, where elements are recovered by
`Map::Sweeper` and the owner by `RubyReactor::Sweeper`. The owner-side check makes duplicate
triggers harmless.

## R-06: The rollback work list is the element-context index, read by position

**Decision**:

- **Work items**: positions in the existing element-context list (`map_element_contexts_key`),
  counted from the tail. `total = LLEN` is fixed when the rollback starts
  (`HSETNX rollback:metadata`, so a second start finds the first: FR-027).
- **Coverage**: the list holds every element that **started**, because `ElementExecutor` registers
  an element before running it. So failed and halted elements get a job too, and it reports
  `not_needed` without undoing anything. Skipped elements never registered and get no job. Spec
  US1-AS2, FR-007 and the edge cases say this since `/speckit-analyze` I1.
  - **Rejected alternative**: a separate forward list of completed ids. It would miss a context
    that completed but crashed before pushing its id, and a sweeper re-dispatch would then leave
    its side effects un-undone. A no-op job per failed element is cheap by comparison.
- **Dispatch**: claims positions with `INCRBY rollback:offset B` and reads them with one
  `LRANGE` per batch.
- **Outcomes**: stored in `rollback:results` (a hash, position → outcome), so they are
  idempotent.
- **Forward registration is deduplicated at the source**: `ElementExecutor` registers the context
  id only for a fresh context, not on a parked or retried re-entry (`serialized_context` present),
  which re-registers the same id today.
- **Leftover duplicates** (payloads from before the upgrade, or a sweeper re-dispatch that made a
  second context for the same index) are safe:
  - each job takes the element's `map_element:<map>:<index>` lock. If it is contended, the job
    requeues itself instead of reporting (R-07), so two jobs for the same index (a duplicate id,
    or a superseded context) serialize rather than produce a false `element_in_flight`;
  - an element whose undo stack is already empty reports `undone` with nothing to do.

**Rationale**: No new forward write. `LRANGE` by position gives bounded reads and atomic claims.
Superseded contexts from a sweeper re-dispatch stay in the list and are rolled back if they
completed, as they are today.

**Alternatives rejected**:

- **Index → id hash written by the forward path.** It loses superseded ids, so a context that
  completed twice (a lost result followed by a re-dispatch) would be rolled back once.
- **Scanning the forward results hash.** It holds result values, not context ids, and can be large.

**Implementation note**: tail positions are anchored at the `total` the rollback started with
(head index `total - 1 - position`), so an id a late duplicate appends after the start never
shifts them.

## R-07: Element rollback checkpoints after every undone entry

**Decision**:

- The element rollback job (`Map::ElementRollback`) takes the element's `map_element:` lock
  (`wait: ELEMENT_LOCK_WAIT`).
  - **If the lock is held**, the job does not report yet. It requeues itself with the same
    arguments through `perform_map_element_rollback_in(Worker.snooze_delay(config, nil),
    attempt: attempt + 1, ...)`. The position stays outstanding, so back pressure and settle
    counting are unaffected.
  - **Only after `lock_snooze_max_attempts`** does it report `element_in_flight`. This is today's
    outcome for a genuinely live forward duplicate.
  - **Why**: the lock is shared by every context of one index. Without the requeue, a concurrent
    duplicate id or superseded context in the same batch would report a false rollback failure,
    and a superseded completed context would never be undone (`/speckit-analyze` U2).
  - **Inline path**: in-process, one element at a time, so it never contends with itself. It keeps
    today's single wait-then-report.
- It then runs `rollback_completed_steps` with a per-entry callback that saves the element context
  after each pop. A redelivery resumes after the last saved entry.
- The same class serves the inline path (R-01), called in-process.

**Rationale**: Spec FR-006 as revised. Exactly-once per step would need idempotent user undos or
two-phase records. At-least-once for the one entry in flight is the standard background-job
guarantee, and it is documented.

**Implementation notes**: only a job's first attempt waits `ELEMENT_LOCK_WAIT` for the lock (the
settle gap); a requeued attempt tries once, since its requeue delay is the spacing, so a held lock
never blocks a worker for `2 s × lock_snooze_max_attempts`. An element saves after each undone entry
with `Executor#checkpoint!`, which stores the row without publishing a completion signal per entry.

## R-08: Dispatch order

**Decision**: Positions are counted from the tail of the element index, so the newest-started
element goes first:

- For an inline map this is exactly highest index first, today's order.
- For a fan-out map it follows start order, which tracks index order batch by batch.

Completion order across elements is not guaranteed.

**Rationale**: Elements are independent and ran in parallel forward. Strict order across parallel
jobs would need serialization, which defeats FR-001.

## R-09: Reporting unavailable elements at bounded memory

**Decision**:

- An element rollback job whose context row is gone reports `context_unavailable`. Its index is
  unknown, because the row held it.
- Every job adds its element index to `rollback:indexes` (a set).
- At aggregation, the owner checks `0...started` (from the map reference) against that set in
  pipelined `SISMEMBER` chunks of 1,000. It reports each index that was started but never seen,
  which covers an expired index list, as 008's `report_unavailable` does.
- **Each expired element is reported once, as in 008**:
  - **`started` known**: the named, started-but-unseen entries are the report, and nil-index
    `context_unavailable` outcomes are **not** added. They describe the same elements.
  - **`started` unknown** (a failed fan-out map that skipped indexes): one unnamed entry per nil-index
    outcome.

  This matches `report_unavailable` (`map_step.rb`), which reports one form or the other, never
  both, and keeps the inline/fan-out oracle (I-7) exact (`/speckit-analyze` I2).
- Aggregation reads outcomes with `HSCAN` in chunks and keeps only failures.
- **Shape**: outcomes are stored as JSON, so aggregation re-symbolizes each failure entry: symbol
  keys, and `step`, `kind`, `reason` and `map_step` values symbolized back. Everything else is
  unchanged: `key`, `message`, and `element_index` (an Integer or nil). The final `rollback_failures`
  are then equal to the inline path's (FR-005, `/speckit-analyze` U1).

**Rationale**: Parity with 008 (FR-007) without loading every index at once. Pipelined `SISMEMBER`
works on any Redis. `SMISMEMBER` would need 6.2, and the gem does not manage Redis.

**Implementation notes**: an outcome's `failures` are stored serialized with
`ContextSerializer.serialize_value`, so symbols round-trip exactly and no manual re-symbolizing is
needed. Outcomes are first-writer-wins (`HSETNX`): a duplicate delivery, which finds the element
already undone, must not replace a `failed` outcome with its own `undone`, and only the job that
stored the outcome claims the next throw.

## R-10: Default batch size, stored with the map

**Decision**:

- **Constant**: `RubyReactor::Map::DEFAULT_BATCH_SIZE = 50`. There is no configuration setting;
  the per-map `batch_size` is the override (spec Assumptions).
- **Applied** in `MapStep#dispatch_async_map` and the `Dispatcher` fallback.
- **Stored in map metadata**: the effective `batch_size` and `atomic`, which fixes the
  sweeper re-dispatch losing both. The rollback reads `batch_size` from the metadata.

**Rationale**: The forward and rollback paths and the sweeper need one source of truth. A constant
is enough until someone needs a different default everywhere (YAGNI).

## R-11: `atomic` replaces `fail_fast`

**Decision**:

- **DSL**: `MapBuilder#atomic(enabled = true)`, on by default.
- **`fail_fast(enabled = true)`** sets the same flag and prints one definition-time deprecation
  warning per call site, through the existing `warn_definition` helper. That helper is extracted
  from `StepBuilder` into `Dsl::DefinitionWarnings`, a module both builders include.
- **Both declared** on one map: `Error::ValidationError` at definition.
- **Internals** are renamed (`MapStep` input, metadata, job payload key) to `atomic`.
- **Legacy payloads**: job payloads enqueued before the upgrade carry `fail_fast`. One
  normalization in `Map::Helpers.normalize_arguments`, used by `ElementExecutor`, `Dispatcher`,
  `Collector` and `RetryManager`, maps `fail_fast` to `atomic` (FR-023). It is removed at the
  next MAJOR.

**Rationale**:

- MINOR: nothing that works today breaks.
- One normalization point instead of reading both keys everywhere.

**Alternatives rejected**:

- **Remove `fail_fast` and raise `DeprecatedDslError`**, like map `async`. That is breaking, and
  the semantics did not change, which is what justified the hard removal of `async`.
- **Keep `fail_fast` internally.** Future readers would see two names for one flag.
- **`all_or_none` / `all_or_nothing`**: long, and the opt-out (`all_or_none false`) reads awkwardly.
  `atomic` is one word and is the usual saga/transaction term.
- **`allow_partial`** (inverted, off by default): reads well, but the `fail_fast` alias and the
  legacy payload mapping would have to negate the value, which is easy to get wrong.

## R-12: Manual undo holds the run's context lock

**Decision**: `Reactor.undo(id)` / `#undo` acquire `async:<root id>` (`wait:` `undo_lock_wait`
constant, 5s) around the whole undo.

- If the lock is held (a live run or rollback), it raises the existing `Lock::AcquisitionError`.
  There is no new error class; the caller retries.
- A run already in `rolling_back` raises `Error::ValidationError` ("rollback already in
  progress", FR-027).
- **`Reactor.cancel` / `#cancel` gets the same guard**: on a `rolling_back` run it raises
  `Error::ValidationError` ("rollback in progress; cannot cancel"). `cancelled` is terminal, so the
  owner `Worker` returns early and the sweeper skips the run. The steps before the map would never
  be undone and nothing would recover them (`/speckit-analyze` G1, Constitution II). `cancel`
  otherwise stays as is.
- If the undo hands off, `#undo` records `rollback: {trigger: "undo"}`, sets `rolling_back`, saves,
  and returns without cancelling. `Reactor.undo` skips its `cancel` call in that case, and
  `resume_rollback` applies `cancelled` when the rollback finishes.

**Rationale**:

- Without the lock, element jobs can finish and resume the owner before the caller's process has
  saved the undo stack it already popped, and steps after the map would be undone twice.
- This is a narrow part of `future_improvements.md` §"External actors send requests". It takes
  the lock for undo only. It adds only the `rolling_back` status guard to `cancel`, and leaves
  `continue` alone.

## R-13: `resume_execution` saves before releasing the context lock

**Decision**: In `Executor#resume_execution`'s `ensure`, `save_context` moves before
`@acquired_context_lock&.release`. The rollback hand-off also saves in its rescue body (R-04).

**Rationale**:

- Today the lock is released and then the blob saved. An owner Worker (R-03, R-05) can take the
  lock in that gap, load the pre-save blob and continue from stale state, and the late save then
  overwrites its progress.
- The collector's current resume has the same window. R-03 routes every map completion through it,
  so the ordering becomes load-bearing.
- A regression spec pins it.

**Out of scope**: the synchronous caller's final save racing a worker (`Reactor.run` with a fan-out
map never holds `async:`). This is `future_improvements.md` §"Fenced context writes"; unchanged.
Tracked as the follow-up "A synchronous caller's final save races a worker resume" in
`specs/future_improvements.md` §"Rollback follow-ups (008)".

## R-14: A map step's undo record carries no arguments

**Decision**:

- `MapStep` declares `rollback_arguments` → `{}`, a `StepConfig` hook with default identity, used
  where `ResultHandler` pushes the undo entry. A map's rollback reads its declaration
  (`element_class`) and the map records, never the resolved `source`.
- This holds for both modes.

**Rationale**: The executor, not the collector, now records a fan-out map's completion (R-03). The
normal push would store the resolved `source` (a whole array) in the parent blob, which 008 R-03
deliberately avoided. Inline maps stored it too, needlessly.

## R-15: Observability

**Decision**:

- **Status `rolling_back`** is added in these places:
  - `Worker::TERMINAL_STATUSES` excludes it;
  - `RedisReactorScan` known statuses;
  - the general sweeper;
  - the dashboard, everywhere statuses are listed (`/speckit-analyze` C4):
    - `gui/src/lib/reactors.ts` `STATUS_GROUPS.running`, so it counts and filters with the live
      runs;
    - `gui/src/components/StatusBadge.tsx`: amber with an undo icon;
    - the status filter options in `LiveView.tsx` and `ReactorClassInstances.tsx`;
    - the status colour in `ReactorDetail.tsx`.
- **Map reference hydration** (`Web::API.hydrate_map_ref`) adds
  `rollback: { total, settled, outstanding, failed }` (`outstanding = total - settled`) from the
  rollback records. The GUI step inspector shows "Rolling back settled/total (outstanding
  outstanding, failed failed)" **only while the run's status is `rolling_back`**. The records
  outlive the run by the durability TTL, so the API field alone would otherwise show a finished
  rollback as in progress (`/speckit-analyze` A3).
- **Structured log lines**, key=value, with reactor, map step and element index:
  - `event=ruby_reactor.map.rollback.started`, with `total` and `batch_size`;
  - `event=ruby_reactor.map.rollback.element`, with `index`, `outcome` and `failures`;
  - `event=ruby_reactor.map.rollback.completed`, with `total` and `failed`.
- **Element undo middleware events** (`start_undo` …) fire inside the element job with the
  element's context, as they do in the inline path.

**Rationale**: Constitution IV and spec FR-009 / FR-011. There is no new middleware event type; the
existing per-step undo events already cover each element.

## R-16: Testing strategy

**Decision**: Real Redis, Sidekiq fake mode plus `drain_async_jobs`.

- **One new `inline!` spec** (T041). Its subject is inline-mode support itself: a spec edge case,
  and R-05's claim that no hand-off happens. It cannot be written in fake mode. This deviates from
  Constitution III, so it is justified in plan.md Complexity Tracking.
- **Existing specs** that already use `inline!` (`map_recovery_spec`, `map_batch_size_spec`,
  `fail_fast_spec`) are extended where needed, but no new `inline!` block is added to them.
- **Step-wise drain helper**: `pending_async_jobs` is the step-wise helper. Its ActiveJob
  `PendingJob` exposes `job_class` while the Sidekiq one exposes `worker_class`. The shipped
  surface gains `worker_class` as an alias on the ActiveJob struct, so step-wise drains work under
  `for_each_async_backend` (`/speckit-analyze` U4).

- **Oracle**: the same reactor run with an inline map and with a fan-out map must end with the same
  final `Failure` (message, step, `rollback_failures` set) and the same set of undone elements.
  Specs share one fixture reactor with a `fan_out` toggle.
- **Back pressure**: drain one job at a time and assert no single job enqueues more than `B`
  element rollback jobs (`max_burst`). Queue depth is not asserted (R-02).
- **Fault injection**:
  - raise an interruption from an element's second undo, then redeliver the job: the first undo
    runs once and the second runs again;
  - hold an element's `map_element:` lock while its rollback job runs: the job requeues, then
    completes once the lock is free, with no `element_in_flight` (R-07);
  - drop a rollback job, then run `Map::Sweeper.run_once`;
  - drop the owner resume, then run `RubyReactor::Sweeper.run_once`.
- **Scale** (`:slow` tag): 10,000 elements, no row loaded twice per job; the peak number of element
  contexts in memory per job is 1.
- **SC-002** (5× with 10 workers) needs real concurrency. It is measured by a benchmark rake task in
  the demo app against Docker Sidekiq at concurrency 10 (quickstart §5), not in RSpec.
  - **Baseline**: the inline-map rollback of the same elements. That is today's serial algorithm,
    with chunked reads that don't change the per-element work. The spec's SC-002 now names this
    baseline explicitly.

## R-17: Documentation impact

- **README.md**: the map section (~lines 880–930: `fan_out`, `batch_size`, the `fail_fast`
  mentions, the rollback paragraph, "`batch_size` is optional"); the status list; the Durability
  section's statuses.
- **documentation/data_pipelines.md**:
  - "`fan_out` Without `batch_size`" (default 50);
  - Back Pressure (applies to rollback);
  - the `fail_fast` section, rewritten as `atomic` with a deprecation note;
  - Rollback (distributed, `rolling_back`, at-least-once window).
- **documentation/background_and_async.md**: the fan-out maps section (owner resume, rollback
  hand-off, the new worker class, sweeper coverage).
- **documentation/composition.md**: compose plus fan-out is supported, and how rollback travels.
- **documentation/core_concepts.md**: the rollback table map row; the `rolling_back` status.
- **documentation/testing.md**: the `be_rolling_back` matcher.
- **demo_app/documentation/data_pipelines.md**: kept in sync.
- **CHANGELOG.md**:
  - Features: distributed map rollback, default batch size, `atomic`;
  - Bug Fixes: composed-child fan-out, sweeper re-dispatch losing `batch_size` / `atomic`;
  - Deprecations: `fail_fast`.
- **specs/future_improvements.md**:
  - remove "Fan-out map inside a composed child" and "Rollback fan-out for very large maps";
  - mark the collector failure-branch writer as fixed.

## R-18: SemVer

**Decision**: MINOR. Nothing is marked `!`.

The observable changes, each noted in CHANGELOG:

- fan-out maps over 50 elements without a declared `batch_size` are now back-pressured;
- the new status value `rolling_back`;
- one extra job per fan-out map completion;
- `fail_fast` warns.

**Rationale**: No working reactor needs a code change (spec SC-006). Consumers that filter on
status strings see one new value, which is additive.
