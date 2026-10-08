# Research: Rollback and Resume Follow-ups

**Feature**: [spec.md](spec.md) | **Plan**: [plan.md](plan.md) | **Date**: 2026-10-08

Each decision names the code it rests on. Line numbers are as of `5ca7d1d1`.

## R-01 Caller-process runs hold the run's liveness lock (US1, US2)

**Decision**: `Executor#execute` takes the run's `async:<id>` liveness lock, as
`resume_execution` already does (`executor.rb:666` `acquire_context_lock`). Conditions:

- root executor only;
- not inside a worker (`!inline_async_execution`);
- not in inline job-testing mode.

The lock is auto-extended, with `wait: 0`. `execute` saves the context **before** releasing the
lock, the same order 009 R-13 gave `resume_execution`. `RubyReactor::Sweeper` is unchanged: it
already skips a run whose lock is held (`sweeper.rb:54`).

**Rationale**:

- One signal serves every reader that already asks "is this run live?": the reactor sweeper, the
  map sweeper's owner check (`map/sweeper.rb:136`), manual undo (009 R-12), and now the Worker
  (R-02).
- The lock's auto-extender is the heartbeat. A step that runs longer than `context_lock_ttl` stays
  live (FR-002). A killed process stops extending, and the lock lapses within one
  `context_lock_ttl` (60s by default, FR-003).
- A `SIGTERM`-style interruption is rescued, so the run is marked `aborted` and its lock is
  released; the sweeper never re-enqueues an `aborted` run.

**Alternatives considered**:

- *A heartbeat timestamp on the context.* It needs blob writes or a new key, plus staleness rules in
  the sweeper. The lock already is a renewed heartbeat with a TTL.
- *A separate "caller-process" liveness key.* That gives two liveness signals for one run, and the
  map sweeper, undo and Worker would all have to read both.
- *Marking caller-process runs so the sweeper skips them until a timestamp goes stale.* A long step
  either looks dead (re-run) or delays crash recovery. It cannot satisfy both FR-002 and FR-003.

**Cost**: one `SET NX`, one release, and one extender thread per synchronous run. Map elements and
composed children are not root executors or run in a worker, so they take nothing new.

## R-02 The Worker takes the liveness lock before it loads (US2)

**Decision**: `Worker#perform` acquires `async:<id>` **before** it reads the context:

- Owner: a fresh UUID. Wait: up to `Worker::CONTEXT_LOCK_WAIT = 2` seconds, polling with 0.1s
  sleeps, as `Lock#acquire` does. No BLPOP: the adapter shares one client per process.
- It then loads the context and hands the owner to the executor (R-03), which re-enters the lock.
- If the lock is still held after the wait, the worker snoozes as for `ContextLockContention`:
  uncapped, nothing loaded, nothing written.
- It releases the lock in `ensure` on every exit (`aborted` return, deserialization failure,
  terminal status).
- Inline job-testing mode skips it, as `acquire_context_lock` does.

**Rationale**: with R-01, a caller's final save happens while it holds the lock. Holding the lock
before loading guarantees the Worker reads the caller's final state, so its own later save cannot
replace anything newer (FR-005). This is part 2 ("lock, then load") of the "Fenced context writes"
proposal, applied only to the Worker. The 2s wait covers the usual case: a caller that enqueued the
hand-off and is milliseconds from releasing. A snooze would cost a whole Sidekiq scheduled-set poll
(about 5s) on every hand-off from a caller process.

It also fixes two places that enqueue the owner's Worker while still holding the lock: the rollback
hand-off handshake (`executor.rb:377`) and `Reactor#undo`'s hand-off. Those Workers now wait instead
of contending once and snoozing.

**Alternatives considered**:

- *Peek at `lock_held?` before loading, and snooze if held.* It leaves a check-then-read gap, and
  every `background` or fan-out hand-off from a caller process would pay a full snooze.
- *The full fence* (versioned, owner-checked writes). Out of scope (spec Assumptions); it would
  also close the paused-holder case.
- *Moving the map's `composed_contexts` reference before dispatch*, so the caller's final save adds
  nothing the Worker would miss. That fixes this one write, not the race.

## R-03 The executor accepts an already-held context lock

**Decision**: `Executor#context_lock_owner=` (an internal writer). When it is set,
`acquire_context_lock` acquires with that owner. `Lock` is re-entrant by owner (the Lua count), so
the acquire succeeds, and the executor's release only decrements the count. The outer holder (the
Worker or `continue`) releases last.

**Rationale**: the smallest change that lets "lock, then load" (R-02, R-05) reuse
`resume_execution` and `resume_rollback` unchanged.

## R-04 A resume is claimed per interrupt, atomically (US4, US5)

**Decision**: accepting a resume means writing a **claim**: `SET NX` of
`reactor:<Class>:context:<id>:resume:<step>`, holding the serialized payload, with TTL
`context_ttl`.

- The first `SET NX` wins. A loser gets `Error::ValidationError` ("interrupt :x was already
  resumed") and writes nothing else (FR-015).
- The claim key is never deleted. It expires with the run and remains the dedupe marker, even after
  the payload has been applied.
- The claim is the payload's only storage until it is applied. Only the execution that owns the
  run's lock applies it: it copies every claimed payload of an interrupt not yet in
  `intermediate_results` into the context, at the start of `resume_execution`, right after the
  context lock (R-05, R-06).

**Rationale**:

- `SET NX` is atomic in every execution mode. The per-run context lock is not: inline job-testing
  mode skips it (`executor.rb:673`), which is exactly 008's accepted gap (FR-016).
- Claiming per interrupt, not per run, lets different interrupts be accepted concurrently (US5),
  while the same interrupt is accepted once (US4).
- `continue` no longer writes the blob before it holds the lock. Today it saves `running` and the
  payload from an unlocked snapshot (`reactor.rb:177-190`), the "`Reactor#continue`" writer listed
  in "Fenced context writes". Applying the payload under the lock also gives US2's guarantee to
  resumes.

**Alternatives considered**:

- *A compare-and-set of the status inside the blob* (Lua plus cjson). It serializes every resume of
  the run, which blocks US5. It is still a write from outside the owning execution.
- *Relying on the context lock.* It is skipped in inline mode.
- *Deleting the claim once it is applied.* A late duplicate could then re-claim between the delete
  and its own readiness check, reading a stale snapshot.

## R-05 The `continue` flow (US3, US4, US5)

**Decision**: `Reactor#continue(payload:, step_name:)` runs these steps:

1. **Snapshot checks (unlocked)**:
   - Reject if `cancelled`, or if the status is not `paused` or `running`. That rejects
     finished, `aborted`, `rolling_back` and failed runs, as 008 FR-032 does today.
   - Reject if the step is not ready (`validate_continue_step!`, unchanged), or if it already has
     a result ("already resumed").
2. **Validate the payload in this process.** An invalid payload counts an attempt (R-08) and
   returns its failure as today. Nothing is claimed, stored or enqueued (FR-008).
3. **Claim** (R-04). If the claim is lost, raise "already resumed".
4. **Try to own the run.** Only a `paused` run is resumed here. A `running` run belongs to
   another execution (a resume, its first run in the caller's process or in a worker, a wait on
   background work), so the resume joins it through a Worker without trying the lock: the resume
   never runs someone else's execution in the calling process. For a paused run, take
   `async:<id>` with `wait: 0` (skipped in inline mode).
   - **Contended**, or the run turned `running` by the reload: hand off. Enqueue the run's Worker
     and return a `DispatchResult` (FR-017, FR-019). The Worker takes the lock when it frees and
     applies the claim (R-06).
   - Implementation note: the `current_step` check ("was it interrupted?") applies to paused runs
     only; a running run may not have one yet.
5. **Owned**: reload the run under the lock ("lock, then load").
   - If it has finished or been cancelled since step 1, release the lock and raise as step 1
     would.
6. **`resume: :background` interrupt**: apply the claims, mark the run `running`, save, release,
   enqueue the Worker, and return a `DispatchResult` (same outward behavior as today).
7. **Otherwise**: `Executor#resume_execution` with the held owner (R-03). It applies the claims,
   marks the run `running`, and runs the steps.
   - If it cannot take the reactor-level `with_lock` or `with_semaphore`, it raises
     `Lock::AcquisitionError` or `Semaphore::AcquisitionError`. By then it has saved the run as
     `running` with the claims applied, before raising (its `ensure`).
   - `continue` rescues those errors: it releases the context lock, **then** enqueues the Worker,
     logs `ruby_reactor.resume.deferred` (FR-014), and returns a `DispatchResult` (FR-009). Release
     first, so the Worker does not wait; a crash between the release and the enqueue leaves a
     `running` run with no lock, which the sweeper recovers.

`reopen_paused` and the `past_gates?` branch are deleted: a contended resume no longer reverts to
`paused`. Hand-off paths keep today's `check_for_inline_completion`, so inline job-testing mode
returns the finished result as it does for `resume: :background`.

**Rationale**:

- One acceptance point: a valid claim. One application point: the lock owner, at resume start.
- Every path that cannot run now (contended context lock, contended reactor lock or semaphore,
  background resume) becomes the same hand-off.
- The Worker never re-validates (FR-011): the payload stored in the claim was validated in step 2.

**Alternatives considered**:

- *Picking up claims inside the executing resume* when it reaches the claimed interrupt (US5's
  "the executing resume picks it up"). That needs a storage read at every interrupt step. The
  backstop Worker already guarantees FR-018, at the cost of one job hop and a transient `paused`.
  Add the pick-up only if that latency matters (marked `ponytail:` in code).
- *Returning a retryable error for US5.* That is the behavior the webhook problem in US3 asks to
  remove.

## R-06 What the Worker does, by status

**Decision**: after loading under the lock (R-02):

| Stored status | Worker action |
| --- | --- |
| terminal (`completed`, `failed`, `cancelled`, `skipped`, `aborted`, `halted`) | return. Today only `aborted` returns early; FR-013 extends it. |
| `paused` | resume only if a claim exists for an interrupt without a result; otherwise return. A stray Worker never advances a paused run. |
| `rolling_back` | `resume_rollback`, as today |
| `running` | `resume_execution`, as today, which now applies claims first |

**Rationale**: the backstop Worker of R-05 can arrive in any state. A paused run must advance only
with a payload: steps after the paused interrupt in the same ready set (`step_executor.rb:32-50`)
would otherwise run without one.

## R-07 The snooze limit applies only before admission (US3)

**Decision**: in `Worker#handle_snooze`, reactor-level contention is uncapped once
`context.admitted?`. That covers a lock or semaphore after a genuine resume, a background resume, or
a re-entry after a hand-off. At `lock_snooze_max_attempts` the worker logs one
`event="ruby_reactor.resume.waiting"` warning, and keeps snoozing.

**Rationale**:

- `escalate_snooze` (`worker.rb:228`) marks the run `failed` **without rolling back**. That is
  harmless before admission (nothing ran) and a saga violation after it: the completed steps keep
  their side effects (Constitution II).
- The same defect already exists for `resume: :background` interrupts and for a parked run whose
  lock reattach lapsed; this fixes them too.
- FR-010 asks the deferred resume to wait for the lock.
- A lock always expires by its TTL. A leaked semaphore slot does not, so the warning gives the
  operator a signal.

**Alternatives considered**:

- *Escalate with a full rollback.* That fails a run the user accepted because of an unrelated
  holder, and rolls back without the reactor-level lock it ran under.
- *Keep the cap.* An accepted resume could then end `failed` with nothing undone.

## R-08 Interrupt attempts move to an atomic counter

**Decision**: `validate_continue_payload` counts an invalid payload with
`INCR reactor:<Class>:context:<id>:resume_attempts:<step>` (TTL `context_ttl`), instead of updating
`private_data[:interrupt_attempts]` and saving the snapshot. When the limit is reached it calls
`Reactor#undo(failure: ...)`, which ends the run `failed` with the same `failure_reason` as today,
inside the undo's lock-then-load (R-09).

**Rationale**: once a `running` run accepts resumes (US5), an unlocked blob save from `continue`
would overwrite the executing resume's progress. The counter is the only blob write before the claim.

**Migration**: a run paused across the upgrade starts counting from 0. It can take at most
`max_attempts - 1` extra invalid attempts. Recorded in CHANGELOG.

## R-09 `Reactor#undo` reloads under its lock

**Decision**: after `acquire_undo_lock`, `Reactor#undo` reloads the context, then undoes. It takes
an internal `failure:` keyword: when given, the run ends `failed` with that reason instead of
`cancelled` (R-08), saved under the same lock. The reason also rides the `rollback` state
(`failure_reason`), so an undo that hands off at a fan-out map still ends `failed` when the worker
finishes it (`Executor#finish_undo`).

**Rationale**: "lock, then load", as R-02. A Worker that saved between `Reactor.undo`'s `find` and
its lock would otherwise be overwritten by an undo working from a stale undo stack.

## R-10 An aborted run records an unfinished `compensate` (US6)

**Decision**:

- `CompensationManager#handle_step_failure` keeps the failing step's `rollback_arguments` on
  `@pending`.
- `Executor#mark_aborted` writes `context.rollback` when `@pending` exists and is not `compensated`:

  ```ruby
  { "trigger" => "failure", "step" => name, "compensated" => false,
    "arguments" => serialized_arguments, "error" => { "class" => ..., "message" => ... } }
  ```

  Composed children and inline map elements are aborted too: each child executor's own
  `rescue Exception` marks its own context, which is embedded in, or stored beside, the root.
- `Reactor#undo` merges that record instead of overwriting it. It keeps `compensated: false`, the
  step, the arguments and the error.
- `Executor#undo_all` first runs `compensate_pending!`: if `rollback` names a step that is not
  `compensated` **and** carries `arguments`, it calls
  `CompensationManager#compensate(step_config, error, arguments)`, then sets `compensated` to true,
  then replays the undo stack.
- That compensate is reported as any compensation is: execution-trace entry, `:failed_compensation`
  event, rollback failure. Either way, the undo stack is still replayed (FR-024).
- **The error passed in**: an original `String` reason is passed as that string. An exception is
  passed as `Error::RecordedFailure` (a `StandardError` with the original `message` and
  `original_class`). The original object cannot be rebuilt.

**Rationale**:

- `undo_all` is the one entry point manual undo, a composed child's undo (`ComposeStep#undo`) and
  an inline element's rollback (`Map::ElementRollback`) all use, so FR-025 ("any depth") comes free.
- The `arguments` key tells this record apart from 009's hand-off state. That state uses the same
  `step` and `compensated` keys and is finished by `finish_rollback`, which needs no arguments: it
  adopts a map's or compose's settled state.

**Not changed**: manual undo still saves only at its end. An undo interrupted again re-runs the
whole remaining undo, `compensate` included; that is at-least-once, as documented. A worker run
still stays `running` and is redelivered (008 R-08).

## R-11 Showing the outstanding `compensate` (FR-026)

**Decision**:

- `Web::API` adds `pending_compensation: { step: }` to an `aborted` run whose `rollback` names a
  step that is not `compensated`.
- `ReactorDetail.tsx` shows one line on such a run: "Compensation of step `x` did not finish; run
  undo to complete it."
- The interrupts and core-concepts documentation say the same.

## R-12 The `undo_all` DSL (US7)

**Decision**: `MapBuilder#undo_all(&block)`:

- It raises `Error::ValidationError` with no block, or when declared twice (FR-027). That is the
  definition error `MapBuilder#build` already raises for `fail_fast` plus `atomic`.
- The block is stored as the map step argument `undo_all_block` (a `Template::Value`), like
  `collect_block`.
- At rollback it is read from the **static declaration**
  (`context.reactor_class.steps[name].arguments[:undo_all_block]`), because a map's undo record
  carries no arguments (009 R-14).
- The block receives one argument, a lazy `Enumerable` of completed elements' results. Its outcome:
  - a `RubyReactor::Failure` return or a raise is a failure;
  - any other return value is success.

## R-13 Rolling back through `undo_all`

**Decision**: when the block is declared, `MapStep#compensate` (and its alias `undo`) calls
`bulk_rollback` instead of `distributed_rollback` or `inline_rollback`.

1. **Fan-out map**:
   - Every index has settled before any map rollback (009 R-04), and its elements ran in workers,
     so none is `aborted`.
   - Results come from the forward result slots, through `Map::ResultEnumerator` (strict index
     order), keeping only successful values: no `_error`, `_halt` or `_skipped`.
   - Indexes with no slot (expired) are reported before the call, as `context_unavailable`
     entries, in chunks.
   - No rollback records and no element rollback jobs (FR-029).
2. **Inline map**:
   - The element index, read in `Map::ROLLBACK_CHUNK` chunks.
   - **Pass 1** replays each `aborted` element through `Map::ElementRollback`, as today. Only an
     interrupted run leaves one, the newest started. Expired contexts are reported as today.
   - **Pass 2** is the lazy enumerator: it deserializes one `completed` element at a time and
     yields its result (`returns` or the last step's result, as `Reactor#reconstruct_success_result`).
3. **No completed element** (the slot count, or pass 1's count, is 0): the block is not called
   (FR-031).
4. **The call**:
   - Log `ruby_reactor.map.rollback.undo_all.started` (fields `reactor`, `map_step`, `count`)
     before it and `.completed` (adding `failed`) after it (FR-034).
   - Append an execution-trace entry `{ type: :undo_all, step:, count:, result: }`.
   - A failure adds one rollback failure `{ step: <map step>, kind: :undo_all, reason:, message: }`
     (FR-032).
5. **What is returned**: `Success` when there are no failures, otherwise the map's usual
   `Failure("map :x rollback incomplete", rollback_failures:)`. The executor continues with the
   steps before the map, as today.

**At least once** (FR-033): the map's undo entry leaves the undo stack only after `undo` returns
(008 R-16). An execution killed mid-call re-runs it on recovery. Duplicate triggers are already
rejected by 009 FR-027.

**Alternatives considered**:

- *Read element contexts for fan-out too.* That deserializes 10,000 blobs; the result slots already
  hold the values.
- *A single pass over an inline map, replaying aborted elements as the enumerator meets them.* A
  block that stops iterating early would skip them.

## R-14 Inline job-testing mode

- The context lock stays skipped in inline mode (R-01, R-02, R-05), as today, because a nested
  re-entry would contend with itself.
- US4 holds there through the claim (R-04). One justified `inline!` spec covers it, like 009 T041.
- US5's overlap (a resume arriving **while** another executes) needs real concurrency and the lock,
  so its specs run in fake mode with threads. Sequential resumes in inline mode produce the same
  outcomes as before.

## R-15 Observability

New structured log lines (key=value):

- `event="ruby_reactor.resume.deferred"`: `reactor`, `context_id`, `step`,
  `reason=lock|semaphore|run_busy|background`, `key`. One per hand-off from `continue` (FR-014).
- `event="ruby_reactor.resume.waiting"`, at warn level: `reactor`, `context_id`, `error` (the
  contention message, which names the key), `snooze_count`. Logged once, when an admitted run
  passes the snooze limit (R-07).
- `event="ruby_reactor.map.rollback.undo_all.started"` and `.completed`: `reactor`, `context_id`,
  `map_step`, `count`, `failed` (FR-034).

Middleware events are unchanged. A re-run compensate fires `:start_compensation` and
`:complete_compensation` or `:failed_compensation`. A hand-off fires no `:failed_reactor`, because
`continue` returns.

## R-16 SemVer: MINOR

- **Features**: `undo_all`.
- **Bug fixes**:
  - the sweeper and caller-process runs;
  - lost progress after a hand-off;
  - lost resumes on lock contention;
  - double resumes;
  - concurrent interrupts;
  - manual undo re-running a cut-off `compensate`;
  - background or deferred resumes no longer escalated to `failed` without rollback.
- **Migration notes**:
  - `continue` returns a `DispatchResult` where it raised `Lock::AcquisitionError` or
    `Semaphore::AcquisitionError`. A `rescue` of those simply stops firing.
  - A second resume of the same interrupt raises "already resumed".
  - Interrupt attempt counts restart for runs paused across the upgrade.
  - A synchronous `Reactor.run` takes the run's liveness lock.

## R-17 Documentation impact

- **README.md**:
  - "Durability & Recovery": caller-process liveness.
  - "Interrupts (Pause & Resume)": acceptance, hand-off on contention, several interrupts at once,
    "already resumed".
  - "Locks, Semaphores & Ordered Locks": a contended resume is deferred, not raised.
  - "Map & Parallel Execution": `undo_all`.
- **documentation/**:
  - `interrupts.md`: resuming, concurrency, the attempt counter, aborted runs and `compensate`.
  - `locks_and_semaphores.md`: line 136, plus the snooze limit before admission.
  - `background_and_async.md`: the Worker's lock-then-load, sweeper liveness of caller-process runs.
  - `data_pipelines.md`: `undo_all`.
  - `core_concepts.md`: aborted runs (line 343).
  - `testing.md`: the new matchers and the `resume(process_jobs:)` option.
- **demo_app/documentation/data_pipelines.md**: kept in sync with `undo_all`.
- **CHANGELOG.md**: per R-16.
- **specs/future_improvements.md**:
  - remove the seven items;
  - in "Fenced context writes", mark the `Reactor#continue` and synchronous `Reactor.run` writers
    fixed, and part 2 done for the Worker and `continue`.

## R-18 Demo app (Constitution VI)

One reactor per file:

| Reactor | Shows | Rake task |
| --- | --- | --- |
| `BulkRefundDemoReactor` (with `BulkRefundChargeReactor` as its element) | a fan-out map with `undo_all`; a later step fails; one bulk refund call | `demo:map_undo_all` |
| `ContendedApprovalDemoReactor` | `with_lock`; a resume while another holder has the lock returns a hand-off; it finishes once the lock is released | `demo:contended_resume` |
| `DualApprovalDemoReactor` | two ready interrupts (`finance` as a background resume, `legal` inline); `legal` is resumed while `finance`'s resume is pending; both are applied once | `demo:concurrent_interrupts` |

- The three tasks are grouped as `demo:rollback_follow_ups`, which is added to `demo:all`.
- Specs use the shipped surface plus additions to `lib/ruby_reactor/rspec/`:
  - `TestSubject#resume(payload:, step:, process_jobs: nil)`. It accepts a `running` run with a
    ready interrupt, mirroring `continue`, and `process_jobs: false` leaves the hand-off pending.
  - Matcher `be_resume_deferred`: the last resume returned a `DispatchResult` and the run is
    `running`.
  - Matcher `have_run_undo_all(:step).with_elements(n)`: reads the `:undo_all` trace entry.
  - Plus the existing `hold_lock`, `be_paused_at`, `have_ready_interrupts` and
    `have_rollback_failure`.
- US1, US2, US4 and US6 are internal fixes, with no new public surface to demo. They are covered by
  gem specs.

## R-19 Deliberately not done

- **The full "Fenced context writes" proposal**: versioned writes, cancel requests, the other
  unlocked writers.
- **Picking up claims inside an executing resume** (R-05). The backstop Worker covers FR-018.
- **Per-entry checkpoints during manual undo** (R-10, not changed).
- **A configurable Worker lock wait.** The constant 2 matches `Collector::COLLECT_LOCK_WAIT`.
