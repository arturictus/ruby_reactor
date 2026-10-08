# Contract: Run Ownership and Resume Protocol

The sequences the implementation must follow and the invariants the specs pin. The records are
defined in [data-model.md](../data-model.md). This extends the invariants I-1 to I-8 of
`specs/009-distributed-map-undo/contracts/rollback-protocol.md`.

## Invariants

- **J-1: a live run holds its lock.** While a run executes anywhere (a worker, the caller's process
  through `execute`, `continue`, or `undo`), its `async:<id>` lock is held and auto-extended.
  Exception: inline job-testing mode, which takes no context lock (R-14). The sweeper re-enqueues
  only `running` and `rolling_back` runs with no lock holder.
- **J-2: lock, then load.** A Worker, `continue` and `Reactor#undo` read the run only after taking
  its lock. A synchronous `execute` creates the run, so it has nothing older to read.
- **J-3: save before release** (009 I-6, extended to `execute`). Every holder persists its final
  state before its lock count reaches zero.
- **J-4: one claim per interrupt.** At most one payload is accepted per interrupt per run (the
  `SET NX` claim). Rejected resumes write nothing.
- **J-5: claims are applied only by the lock owner.** A claimed payload enters the run's context
  only in the execution holding `async:<id>`, at the start of `resume_execution`. `continue` never
  writes the context without the lock.
- **J-6: an accepted resume is not stranded.** After a successful claim, either the claiming
  `continue` owns the run and resumes it, or a Worker for the run is enqueued. A Worker that finds
  the run `paused` with an unapplied claim resumes it.
- **J-7: validated once.** A claimed payload is never validated again (FR-011).
- **J-8: no escalation after admission.** An admitted run is never marked `failed` by snooze
  escalation (R-07).
- **J-9: no `compensate` is lost.** An `aborted` run whose failing step's `compensate` had not
  returned keeps a record of it. Manual undo runs it before the undo stack, at each level where it
  was recorded.

## P-1: Synchronous run with a fan-out hand-off (US1, US2)

```text
caller process                                   element jobs / collector       Worker(run)
──────────────                                   ────────────────────────       ───────────
Reactor.run → Executor#execute
  take async:<id> (wait 0, auto-extend)          ◀── sweeper sees it held: skip
  steps…; MapStep#run dispatches, returns DispatchResult
                                                  elements run; all settled →
                                                  enqueue Worker(run) ─────────▶ take async:<id> (wait ≤ 2s)
  ensure: save final state (J-3)                                                    …blocked…
          release async:<id> ──────────────────────────────────────────────────▶ acquired
  return DispatchResult                                                          load (sees caller's final save, J-2)
                                                                                 resume_execution (re-entrant) → adopt map → …
                                                                                 save; release
```

If the caller takes more than 2s to release, the Worker snoozes as a `ContextLockContention`
(uncapped) and retries. It has loaded and written nothing.

## P-2: Resume while the reactor's lock is held (US3)

```text
webhook → Reactor.continue(id, payload, :approve)
  find (snapshot) → status paused ✓, :approve ready ✓
  validate payload ✓ (in this process)
  SET NX resume:approve ✓
  take async:<id> ✓ → reload → Executor(owner).resume_execution
      apply claims → status running → with_lock contended → ensure: save → raise Lock::AcquisitionError
  rescue: release async:<id> → enqueue Worker(run) → log resume.deferred(reason=lock)
  return DispatchResult
Worker(run): lock, then load → running → resume_execution → apply claims (none left) → with_lock
  contended → snooze (uncapped: admitted) … lock freed → acquire → steps run → final save
```

## P-3: Two resumes of the same interrupt (US4)

```text
caller A                       caller B
find: paused                   find: paused
validate ✓                     validate ✓
SET NX resume:approve ✓        SET NX resume:approve ✗ → raise "already resumed" (nothing written)
take lock, reload, resume …
```

The same holds in inline job-testing mode: the claim does not depend on the context lock.

## P-4: Resuming a second interrupt while the first executes (US5)

```text
caller A (approve_a)                              caller B (approve_b)                  Worker(run)
SET NX resume:approve_a ✓; take async:<id> ✓
reload; resume_execution: apply claim a
  running; steps after a…                         find: running; approve_b ready ✓
                                                  validate ✓; SET NX resume:approve_b ✓
                                                  take async:<id> ✗ (held by A)
                                                  enqueue Worker(run); log deferred(run_busy)
                                                  return DispatchResult
  reaches approve_b (no result) → pauses
  save paused; release ───────────────────────────────────────────────────────────▶ take lock; load: paused
                                                                                    claim b unapplied → resume_execution
                                                                                    apply claim b → steps → completed
```

- If A's run reaches its end before B's claim, it pauses at `approve_b`, and the Worker resumes it.
- If A's run fails and rolls back first, the Worker loads a `failed` run and returns. Claim b is
  never applied (FR-021).

## P-5: Manual undo of an aborted run (US6)

```text
caller process: Step X fails → handle_step_failure records @pending{step X, args, error}
  compensate(X) … SIGTERM → rescue Exception → mark_aborted:
     status aborted; rollback = {trigger: failure, step: X, compensated: false, arguments, error}
  ensure: save; release async:<id>
operator: Reactor.undo(id)
  take async:<id> (wait 5s) → reload (J-2)
  rollback merged {trigger: undo, step: X, compensated: false, arguments, error}
  Executor#undo_all → compensate_pending!: compensate(X, recorded error, recorded args)
                     → compensated: true
                     → rollback_completed_steps (newest first)
  status cancelled ("Undo triggered"); save; release
```

A composed child or inline map element that was cut off records the same, on its own context. Its
level's `undo_all` (called through `ComposeStep#undo` or `Map::ElementRollback`) runs it before
that level's undo stack.

## P-6: Map rollback through `undo_all` (US7)

```text
executor rollback reaches the map's undo entry (or compensates a failed atomic map)
  MapStep#compensate → undo_all_block declared → bulk_rollback
    fan-out: report indexes with no result slot; enum = result slots (Success values, index order)
    inline:  pass 1 → aborted elements → Map::ElementRollback (per-element replay)
             enum = completed element contexts, one at a time, index order
    count == 0 → skip the call
    log undo_all.started → block.call(enum) → trace :undo_all → log undo_all.completed
    failure → rollback failure {step: map, kind: :undo_all}
  return Success / Failure(rollback_failures) → the executor pops the entry → steps before the map
```
