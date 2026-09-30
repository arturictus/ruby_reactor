# Contract: Map Completion and Distributed Rollback Protocol

The sequences the implementation must follow, and the invariants the specs pin. The record names
are defined in [data-model.md](../data-model.md).

## Invariants

- **I-1: single writer.** A context is written only by the execution that owns it: the top-level
  run's worker holding `async:<owner id>`, or the caller's process during `Reactor#undo`, which
  holds the same lock. The collector and element rollback jobs write only map records and element
  contexts.
- **I-2: the owner resumes once per signal, and never before its hand-off is saved.** Each settle
  signal (`owner_signalled`, `rollback:signalled`) enqueues the owner's `Worker` at most once. A
  rollback signal also requires `rollback:handed_off`, which the handler sets after saving (R-05).
  Extra resumes from the sweepers are harmless because every construct adopts idempotently on
  re-entry.
- **I-3: no double dispatch.** A map dispatches its elements once (`map_operations[step]` is set
  before dispatch), and starts its rollback once (`rollback:metadata` is created with `HSETNX`).
- **I-4: step-level saga order.** Steps before a map are undone only after its rollback has
  settled. Within an element, steps are undone in reverse order.
- **I-5: resume cursor.** An undo entry leaves the stack only after its undo returns. A hand-off
  leaves the map entry, and every entry below it, on the stack.
- **I-6: save before release.** Every hand-off (a forward `DispatchResult` or a rollback hand-off)
  persists the context before the owner's `async:` lock is released.
- **I-7: oracle.** For the same reactor and failure, the final `Failure` and the set of undone
  elements are the same whether the map is inline or fan-out. That includes `rollback_failures`
  entries with symbol values, and each unavailable element reported once.
- **I-8: no terminal status mid-rollback.** A `rolling_back` run cannot be cancelled or undone
  again (FR-027). Only `resume_rollback` moves it to `failed` / `cancelled`.

## S-1: A fan-out map completes (any composition depth)

```text
owner worker (holds async:<owner>)           element jobs            collector
─────────────────────────────────           ────────────            ─────────
MapStep#run (first time)
  map_operations[step] = map_id
  store owner tree + child snapshot
  initialize map metadata (owner ids, batch_size, atomic)
  Dispatcher: enqueue batch 0 (≤ B)
  return DispatchResult ── executor saves, then releases async: (I-6)
                                              run, store result slot,
                                              position kB-1 → next batch,
                                              counter hits 0 → enqueue collector
                                                                     all slots present?
                                                                     SET NX owner_signalled
                                                                     enqueue Worker(owner)
Worker(owner) takes async:<owner>
  resume_execution → … → ComposeStep#run → child resume_execution
  MapStep#run (re-entry: map_operations[step] present)
    settled + failed_context_id → return the element's Failure (+ its rollback_failures)
    settled                     → return Success(collect(ResultEnumerator)); record started
    not settled                 → return DispatchResult (no dispatch)
  the executor continues: result recorded, undo entry {step, arguments: {}} (R-14)
```

## S-2: Rollback reaches a completed fan-out map

A later step failed, the map itself failed (atomic), or `Reactor#undo` was called.

```text
owner (worker, or caller during undo; holds async:<owner>)
  CompensationManager: compensate the failing step, then pop entries newest first …
  MapStep#undo (map_operations[step] present)
    HSETNX rollback:metadata (total = LLEN element_contexts, batch_size, owner ids)
      created → log rollback.started; claim batch 0 (INCRBY offset B); enqueue ≤ B element rollback jobs
      existed → dispatch nothing (I-3)
    settled?  (HLEN results == total)
      yes → aggregate (HSCAN failures + started-index check) → return Success / Failure(rollback_failures)
      no  → raise RollbackHandedOff
  ▲ unwinds without popping (I-5), through Rescuable sites untouched
  composed child executor / child Executor#undo_all: record child `rollback` (incl. its failures so far), re-raise
  top-level executor:      record `rollback`, status rolling_back, SAVE (in rescue, lock held),
                           SET rollback:handed_off, then: settled && SET NX rollback:signalled → enqueue Worker(owner);
                           release
  Reactor#undo:            same, and skip `cancel`

element rollback job (position p, attempt a)
  load element context (by id from the job args)
    missing → outcome context_unavailable (index null)
  take map_element:<map>:<index> (wait 2 s)
    held and a < lock_snooze_max_attempts → perform_map_element_rollback_in(delay, attempt: a+1); stop (no outcome)
    held and a = max                      → outcome element_in_flight
  status completed|aborted → rollback_completed_steps, saving the element after each pop
                             → undone | failed(failures)
  otherwise (failed / halted / superseded running) → not_needed
  HSET results[p]; SADD indexes index; log rollback.element
  p ≡ B-1 (mod B) → claim the next batch
  HLEN results == total && EXISTS rollback:handed_off && SET NX rollback:signalled → enqueue Worker(owner)

Worker(owner), status rolling_back → Executor#resume_rollback (takes async:<owner>)
  restore rollback_failures from `rollback.failures`
  unless compensated: handle the failing step's compensate again (constructs adopt)
  rollback_completed_steps → MapStep#undo re-entry → settled → aggregate → pop → continue
  finalize: failure → the same Failure as the inline path (I-7) | undo → cancelled
  clear `rollback`, save, release
```

A second fan-out map lower in the undo stack repeats S-2 from inside `resume_rollback`. The
status stays `rolling_back`.

**Aggregation** (`MapStep#undo` re-entry once settled): `HSCAN` failures and re-symbolize them.
Then report unavailable elements once: named started-but-unseen indexes when `started` is known,
otherwise one entry per nil-index outcome (DM §5).

**Inline test mode** (all jobs run inside dispatch): every outcome is stored before `MapStep#undo`
checks settled, and `handed_off` never exists, so no job enqueues the owner. `#undo` aggregates
synchronously and never raises the hand-off.

## S-3: The failing step is inside a composed child

```text
root: ComposeStep#run → child executes → child step fails
  child handle_step_failure: compensate the child step, then pop child entries … child MapStep#undo → RollbackHandedOff
  child executor: record child.rollback {trigger: failure, step: <child step>, compensated: true, failure: <child Failure>}, re-raise
  root StepExecutor: passes it through (not Rescuable)
  root executor: root.rollback {trigger: failure, step: <compose step>, compensated: false, failure: <child Failure>}
                 status rolling_back, save (the child is embedded), release
… element rollbacks settle → Worker(root)
root resume_rollback: compensated false → handle_step_failure(compose step)
  ComposeStep#compensate → child executor undo_all (restores child.rollback failures) → child stack:
    map entry → adopt → pop → the rest of the child → clear child.rollback
  → then the root's own completed steps → finalize with the saved failure
```

The same path runs when a **manual undo from the root** reaches a composed child: root
`Reactor#undo` → root `undo_all` → `ComposeStep#undo` → child `undo_all` → child `MapStep#undo`
hands off. Child `undo_all` records its failures and re-raises, and `Reactor#undo` records the root
`rollback {trigger: undo}`. On resume, child `undo_all` restores its failures, so none are lost.

## S-4: Inline map rollback (no hand-off)

```text
MapStep#undo (map_operations[step] absent)
  for each chunk of 100 positions from the tail of element_contexts:
    load contexts → Map::ElementRollback (same class as the job, in process) → collect failures, indexes
  started-index check → Success / Failure(rollback_failures)
```

## S-5: Recovery

| Lost thing | Detected by | Action |
| --- | --- | --- |
| Element rollback job (crash before storing the outcome) | `Map::Sweeper` rollback pass: a position `< offset` with no outcome and no live element lock | Re-enqueue that position. The element resumes after its last saved undo. |
| Batch trigger (the job at `kB-1` died after storing its outcome) | `Map::Sweeper`: offset `< total` and every claimed position settled | Claim and enqueue the next batch. |
| Owner resume (after `rollback:signalled` was set) | `RubyReactor::Sweeper`: `rolling_back`, no `async:` lock | Re-enqueue the owner. `resume_rollback` adopts the settled map. |
| Owner resume (after `owner_signalled` was set) | `RubyReactor::Sweeper`: `running`, no `async:` lock (existing) | Re-enqueue the owner. `MapStep#run` adopts. |
| Collector | `Map::Sweeper` recollect (existing), with the owner's `async:` lock checked instead of the parent's | Re-trigger the collector. `owner_signalled` keeps it to one resume. |

## S-6: Legacy in-flight work across the upgrade

| Payload | Handling |
| --- | --- |
| Element / dispatcher / collector / retry job carrying `fail_fast` | `Map::Helpers.normalize_arguments` maps it to `atomic`. |
| Map metadata without `owner_context_id` (a map started before the upgrade) | Collector falls back to `parent_context_id` / `parent_reactor_class_name`. This is correct for root-level maps. A map inside a composed child started before the upgrade keeps the old hang; documented in CHANGELOG. |
| Map metadata without `batch_size` | The rollback uses `DEFAULT_BATCH_SIZE`. |
| Element index with duplicate ids | Safe: an empty undo stack reports `undone`, and a concurrent duplicate waits on the element lock or reports `element_in_flight`. |
