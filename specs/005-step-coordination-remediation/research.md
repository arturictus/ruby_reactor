# Research: Step Coordination Review Remediation

**Feature**: [spec.md](./spec.md) | **Plan**: [plan.md](./plan.md) | **Date**: 2026-09-23
**Input**: [`specs/step-coordination-review-remediation.md`](../step-coordination-review-remediation.md)
(the review), checked against `independent_step_locks@ca963444`.

The Technical Context had no open questions: the stack, storage and test setup are the same as
in 003. Phase 0 had two jobs:

1. check every claim in the review against the code;
2. make each design decision the review left open or only sketched.

## 1. Verification of the review's claims

| Finding | Claim | Verified by | Result |
|---|---|---|---|
| F1 | Rollback re-takes the lock with the forward `wait:`, which defaults to 0 | `step_coordination.rb:203-214` (`wait: config[:wait]`), `dsl/lockable.rb` (`with_lock(… wait: 0 …)`) | Confirmed |
| F1 | An undo that did not run shows up only in the trace and the hook, never on the Failure | `compensation_manager.rb:64-73` (`@undo_trace` only), `result_handler.rb:183-197` (a fresh Failure with no rollback data) | Confirmed. `RubyReactor::Failure` (`ruby_reactor.rb:134`) has no field for it. |
| F2 | The root releases its reactor lock when a composed child returns `RetryQueuedResult` | `executor.rb:276` (`release_locks unless @parked`); `@parked` is set only by `park_held_primitives!`, which the child's callback calls on the *child* executor | Confirmed |
| F2 | The rate limit is charged again on redelivery | `executor.rb:406` (`first_execution?` reads `current_step`), `context.rb:111-117` (`with_step` resets it) | Confirmed |
| F2/A.2 | A composed child releases its own lock on `AsyncResultPending` | `executor.rb:152-165` (re-raise, then `ensure release_locks`) | Confirmed |
| F3 | A synchronous out-of-turn arrival calls `advance(failed: true)` | `step_coordination.rb:303-311` | Confirmed |
| F3 | That records `fail_key` for any nonce ahead of the cursor | `redis_ordered_locking.rb` ADVANCE_SCRIPT (`if failed and my > last`) | Confirmed |
| F3/D-F3 | `advance(failed: false)` from a position that is not at the head lets later positions pass immediately | ADVANCE_SCRIPT runs only `hdel at_key my` when `my ~= last+1`. CAN_PROCEED_SCRIPT then drains any blocker with `at == 0` ("the timer is gone … advance past it") | Confirmed. This is the mechanism D-F3 (a) relies on. |
| F4 | `current_step` is non-nil for a reactor-level event after a park | follows from F2's `current_step` pinning; `coordinating_step` is a transient `attr_accessor` (`context.rb:43`), not serialized, and set only inside `StepCoordination#emit` | Confirmed. The docs-only fix is enough. |
| F5 | `record_contention` blind-overwrites the root blob | `step_worker.rb:159-171` → `save_root` (`:453-462`), which takes no context lock | Confirmed |
| F6 | A step park keeps the reactor hold and reattaches it on every redelivery | `executor.rb:591-607`, `:530` | Confirmed. It is intended (D-A2). Docs only. |
| F7 | `:stale_batch` falls through and runs the body | `step_coordination.rb:285-296` handles only `:skip_chain_failed`, and any other symbol runs | Confirmed. `:drained_go` also falls through, which is correct for a straggler. |
| F8 | The heartbeat stops only on `StandardError` or success | `step_coordination.rb:436-469` (no `ensure`) | Confirmed |
| F9 | A direct call names the caller's `current_step` | `step_coordination.rb:698-704` (it never checks `@direct`) | Confirmed |

### New finding: F10 (pre-existing on `main@6608f7b9`)

**`AsyncResultPending` raised inside a composed child is swallowed and becomes a Failure of
the parent.** The exception travels:

1. the child executor `execute` re-raises it;
2. `ComposeStep#run`;
3. `StepCoordination.call_body`, which rescues only `Contended` and `KeyError`;
4. the parent's `StepExecutor#safe_execute_step_sync`, whose `rescue StandardError` turns it
   into a Failure;
5. the Failure is non-retryable, so rollback runs.

A throwaway spec reproduced it on `ca963444`. A background parent composes a child that reads
`result(:send_email)` of an `async_step`. It returned `RubyReactor::Failure: Step 'child'
failed after 1 attempts: async result for 'send_email' still pending … parking the call`,
where it should have raised `AsyncResultPending` to the worker. The review's A.2 assumed this
park already reached the root. It does not. A.1 has to route every park signal past
`safe_execute_step_sync` in any case, so F10 is fixed by the same change (R-04). It gets its
own regression spec (R6 in [quickstart.md](./quickstart.md)).

## 2. Decisions

The three decisions the review asked for (D-F1, D-F3, D-A2) are recorded here first. The FR-025
task also copies them into `specs/003-step-lock-declarations/research.md`, so a review of 003
finds them there.

### D-F1: Rollback waits with a bounded wait of its own, and reports undos that did not run

- **Decision**: option (a).
  - `with_lock` and `with_semaphore` take a new `rollback_wait:`.
  - It defaults to the lock's `ttl:`, and to 60 seconds for a semaphore, which has no hold
    expiry.
  - Rollback uses it in place of the forward `wait:`.
  - Every undo or compensation that did not complete is listed on
    `Failure#rollback_failures`.
- **Rationale**: the forward holder either finishes or its lock expires at `ttl`. Waiting up to
  `ttl` therefore always outlasts a holder that has crashed, and nearly always outlasts a live
  one. Reporting on the Failure is the only surface a synchronous caller reads.
- **Alternatives rejected**:
  - (b) Run the undo without the lock and log a warning. This reintroduces the race that US6
    exists to close: a refund running alongside a charge.
  - (c) Park the rollback. That needs resumable rollback, which is large, and 003 decided that
    rollback never parks.
- **Consequence to accept**: in a worker, a rollback can block the worker thread for up to
  `rollback_wait`, 60 seconds by default. Rollback runs rarely and is already mid-failure. An
  author with a long `ttl` can lower `rollback_wait`.
- **Semaphore default**: a fixed 60 seconds, the lock's default `ttl`. It is a constant, not a
  new config key. Add a key if someone asks for one.

### D-F3: A synchronous out-of-turn arrival does not poison the chain

- **Decision**: option (a).
  - A `WaitError` at the gate means the position is not at the head. The position is handed
    back with `advance(failed: false)`.
  - A position that passed the gate and then failed still uses `failed: true`. This covers
    synchronous lock, semaphore or rate-limit contention after the gate, since the position was
    at the head.
- **Rationale**: the failed execution never held the turn, so it has no failed work for
  successors to be protected from. The reactor level reaches the same state once the poison
  pill passes the abandoned nonce. This only gets there without the wait.
- **Alternative rejected**: (b) strict purity with visible skips. Every later position would
  be skipped until the batch drains, which for a steady stream is forever. That is the silent
  data loss F3 describes.
- **Docs**: copy the reactor-level "use only on `background all: true`" warning
  (`locks_and_semaphores.md:494`, `:665`) into the step section.

### D-A2: Every executor on the stack keeps its holds on a park

- **Decision**: option (a). When a park signal passes through any `Executor#execute` or
  `#resume_execution` in a worker (`inline_async_execution`), that executor calls
  `park_held_primitives!`. It stores `parked_primitives` on its own context, which is saved
  inside the root blob through `composed_contexts`. On redelivery it re-adopts them through
  `consume_parked_primitives!`.
- **Rationale**: this is FR-018 and `locks_and_semaphores.md:778` taken literally. With root
  only, a composed child's exclusion lapses partway through an execution.
- **Alternative rejected**: (b) root only, with narrower docs. It is less code, but it
  documents a gap in exclusion as a feature.

### R-01: One park mechanism, an exception (review A.1)

- **Decision**:
  - Add a base class `Error::ExecutionParked < Error::Base`.
  - `AsyncResultPending` changes its superclass from `Base` to `ExecutionParked`. It stays a
    `Base`, so existing rescues are unaffected.
  - Add `Error::StepContentionPark < ExecutionParked`. It carries the `Contended` and delegates
    `original` and `retry_after_seconds` to it, so `Worker.snooze_delay` and
    `Worker.hinted_retry?` work unchanged.
  - `StepExecutor#handle_contention` keeps:
    - the ceiling check (moved in from `RetryManager#park_for_contention`);
    - giving back the retry attempt;
    - the `:contention_park` trace entry, the `:step_contention` marker and the log line;
    - pinning `current_step`.

    It then raises `StepContentionPark` where it used to requeue.
- **Removed**:
  - the `on_contention_park` callback (`executor.rb:56-63`, `step_executor.rb:18`);
  - `RetryManager#park_for_contention` and its requeue;
  - `RetryQueuedResult` as a contention outcome.

  `RetryQueuedResult` stays for failure retries. A retry requeue is not a park: it releases the
  reactor hold as it does on `main`, and that is out of scope.
- **Rationale**:
  - The requeue now happens at the top of the stack (`Worker`, `ElementExecutor`), *after*
    every executor's `ensure` has parked its holds and saved.
  - The race the callback existed for (a redelivery starting before the parked marker is
    saved) cannot happen by construction.
  - A composed park then takes the same path as a root park.
- **Rescue sites that must let park signals through or handle them.** Listing them is the core
  of this change:

  | Site | Today | After |
  |---|---|---|
  | `StepExecutor#safe_execute_step_sync` | `rescue StandardError` swallows them (F10) | `rescue Error::ExecutionParked; raise`, placed before `StandardError` |
  | `StepExecutor#execute_step` `rescue Exception` | emits `:failed_step` | emits `:snooze_step` for a park signal (R-04), then re-raises |
  | `StepCoordination#around_run` `rescue StandardError` | clears contention state | re-raise a park signal untouched: not terminal |
  | `StepCoordination#run_under_ordered_lock` | `rescue StandardError` → `advance(failed: true)` | the outcome is `:parked`, so no advance (R-07) |
  | `Executor#execute` `rescue AsyncResultPending` | re-raise; child releases its locks | `rescue Error::ExecutionParked`: `park_held_primitives!` when `inline_async_execution`, then re-raise |
  | `Executor#resume_execution` `rescue AsyncResultPending` | park, then re-raise | `rescue Error::ExecutionParked`, same body |
  | `Worker#perform` snooze list | `AsyncResultPending` | `Error::ExecutionParked` |
  | `Worker#handle_snooze` `capped` | uncapped for `AsyncResultPending` | uncapped for `Error::ExecutionParked`. Contention is capped at the raise site with the per-step counter. |
  | `Map::ElementExecutor.perform_element` | reads `RetryQueuedResult` | `rescue Error::StepContentionPark`: re-serialize the element context and call `perform_map_element_in(Worker.snooze_delay(...))` |
  | `StepWorker` (async_step) | own `Contended` park | unchanged. It is not a reactor run. |

- **Map elements and `AsyncResultPending`**: `ElementExecutor` does not rescue it today, so a
  map element that waits on a background result goes to the backend's retry. That is on
  `main` and out of scope. The new rescue covers `StepContentionPark` only.
- **Alternative rejected**: keep `RetryQueuedResult` and make every executor park when it sees
  a contention-flagged one. The requeue has already been saved and enqueued deep inside
  `RetryManager` by the time outer executors see the result, so their parked markers would
  land after the save. That is the exact race the callback was added for, now at every level.

### R-02: Parks at the child level (D-A2 mechanics)

- `Executor#execute` is the entry point for a composed child's first run, and for a map
  element's first run. It gains the same park branch as `resume_execution`. It parks only
  when `@context.inline_async_execution`. A synchronous caller never parks, and no park signal
  is raised there.
- `ensure release_locks` becomes `release_locks unless @parked`, as in `resume_execution`.
- `ComposeStep#execute_child_reactor` chooses `resume_execution` over `execute` when the child
  has been admitted (R-03), not when `child_context.current_step` is set. The reason: when a
  park happens two levels down, the grandchild's compose step runs inside the child's
  `with_step`, which resets the child's `current_step`. The child would then go through
  `execute`, re-charge its rate limit, and fresh-acquire its own lock instead of reattaching.
  The same owner makes that a re-entrant count++, which leaks one count until the TTL.

### R-03: An explicit admission marker replaces the "first run" inference (review A.3)

- **Decision**: `private_data[:admitted] = true` is set on the executor's own context once its
  reactor-level gates have passed:
  - in `execute`, after the post-lock period re-check;
  - in `resume_execution`, after the post-lock period re-check, on a first run.

  `first_execution?` and `fresh_ordered_lock_start?` both become
  `!admitted? && current_step.nil? && intermediate_results.empty?`. The old inference is kept,
  AND-ed in, so a context saved before this change, and in flight during an upgrade, still
  resumes correctly.
- **Rationale**: `current_step` stops being a gate input and is only the resume cursor. A park
  at any depth, and any exception unwinding through `with_step`, can no longer make an
  execution look fresh.
- **Alternative rejected**: pin `current_step` on every ancestor context at park time. It
  keeps the three-job overload the review names as a root cause, and any future park path has
  to remember to pin.

### R-04: Park signals and step lifecycle events

- **Decision**: when a park signal passes `StepExecutor#execute_step`, emit
  `:snooze_step(step_name, error, context)`, never `:failed_step`. It mirrors the existing
  `:snooze_reactor`. `OpenTelemetry` gains `on_snooze_step`, which finishes the step span with
  `step.status = "parked"` and status OK.
- **Rationale**: today a contention park emits `:complete_step(RetryQueuedResult)`, which
  closes the OTel span. With the exception, neither `complete` nor `failed` would fire, so the
  step span would never finish, and it is keyed by step name so it would leak. A new event is
  additive: `MiddlewareRunner` dispatches by `respond_to?`, so middlewares that do not define it
  are unaffected.
- **Out of scope**: `:snooze_reactor` has no OTel handler, so the reactor span leaks on every
  snooze on `main` too. Note it in the out-of-scope list and do not fix it here.

### R-05: The Worker's delay and ceiling for `StepContentionPark`

- The delay is `Worker.snooze_delay(config, error)`, unchanged. `StepContentionPark` delegates
  `original` and `retry_after_seconds`, so an ordered-lock wait still re-polls at the base
  delay and a rate limit still uses its hint.
- The ceiling is the per-step `RetryContext#contention_attempts`, checked in
  `handle_contention` before raising. Crossing it returns the terminal Failure, as
  `park_for_contention` does today, including `discard_parked_state!`. The Worker's
  `snooze_count` does not apply.
- `retry_context.next_retry_at` is no longer set on a contention park. Its only readers are
  the OTel `RetryQueuedResult` mappers, which no longer see parks.

### R-06: One ordered-lock gate classifier (review B.1)

- **Decision**: add `OrderedLockSupport.gate(info, fresh:)`. It calls `OrderedLock#check!` and
  maps the result with an **exhaustive** `case` (an `else` raises) to one of these outcomes, or
  lets `WaitError` propagate:

  | Outcome | Condition |
  |---|---|
  | `:go` | `go`, `poison_advance` |
  | `:skip_chain` | `:skip_chain_failed` and `fresh` |
  | `:stale` | `:stale_batch` |
  | `:drained` | `:drained_go` |

  - The reactor level calls it from `enter_ordered_lock_scope` with
    `fresh: fresh_ordered_lock_start?`. It keeps its own drained-replay check, which reads the
    stored status.
  - The step level calls it with `fresh: true`. A step's gate always runs before its body, so
    the position has never started.
  - The step level maps `:stale` to `Skipped(reason: :ordered_lock_stale_batch)` with no
    advance, since the epoch fence makes an advance a no-op, and deletes the stash. It maps
    `:drained` to run.
- **Rationale**: F7 happened because a symbol nobody handled fell through to "run". With one
  exhaustive classifier, a new state has to be handled in one place before either level can
  compile it in. A parity spec runs each state at both levels.
- **Alternative rejected**: fully unify the reactor-level and step-level lifecycles into one
  block helper. At the reactor level, the enter and leave calls sit in the `begin` and `ensure`
  of `execute` and `resume_execution`, so a block wrapper would restructure both methods for no
  change in behavior.

### R-07: One position lifecycle at the step level (review B.2)

- **Decision**: `run_under_ordered_lock` keeps a single `outcome` variable and finishes in
  `ensure`:

  ```text
  outcome = :abandoned                      # default: non-StandardError exits
  yield → outcome = retry_pending? ? :retry_pending : (chain_failed? ? :failed : :succeeded)
  rescue Contended  → outcome = parking? ? :parked : :failed    (at head: D-F3 keeps failed)
  rescue ExecutionParked → outcome = :parked
  rescue StandardError → outcome = :failed
  ensure heartbeat.stop; finish_position(info, outcome)
  ```

  `finish_position`:

  | Outcome | Action |
  |---|---|
  | `:succeeded` | `advance(failed: false)` and delete the stash |
  | `:failed` | `advance(failed: true)` and delete the stash |
  | `:parked`, `:retry_pending` | keep |
  | `:abandoned` | keep. Only the heartbeat stops, and the poison pill releases the position within `poison_pill_timeout`. |

- **Why `:abandoned` does not advance**: `Sidekiq::Shutdown` is an `Interrupt`, and a job
  interrupted by it is pushed back and runs again. Advancing with `failed: true` would poison
  successors, and advancing at all would drop the redelivery's place. Stopping the heartbeat
  is all F8 needs: the position then expires on the normal poison-pill schedule (SC-007).
- The gate-level `rescue Contended`, for an out-of-turn arrival, moves into the same decision:
  synchronous is `advance(failed: false)` (D-F3), and parking keeps the position.

### R-08: `Failure#rollback_failures` (FR-004)

- **Shape**: an Array of Hashes. Each hash is
  `{ step:, kind: :undo | :compensate, key:, reason:, message: }`, where `reason` is one of:
  - `:coordination_unavailable`: the key was not free within `rollback_wait`;
  - `:returned_failure`: the undo returned a Failure;
  - `:raised`: the undo raised.

  The array defaults to `[]`, is included in `Failure#to_h` and is read back by
  `extract_attributes_from_hash`, so it survives the async failure blob.
- **Collection**: `CompensationManager` appends to its own `@rollback_failures`:
  - from `undo_step`, for a Failure result or a rescued exception;
  - from `compensate_step`, for a Failure result.

  `StepCoordination#rollback_failure` returns `Failure(Contended.new(…))` in place of a bare
  string, so the entry can read `key` and `primitive` from `result.error`. `Contended` is reused
  and no new class is added.
- **Attachment**: one choke point. `ResultHandler#handle_execution_error` builds every
  reactor-level Failure that follows a rollback (`StepFailureError`, `InputValidationError`, a
  `CompensationError` or other `Error::Base`). It concatenates
  `@compensation_manager.rollback_failures` onto the result before returning it.
- **Nesting**:
  - A composed child's Failure reaches the parent as a step result. `ResultHandler#handle_failure`
    folds `result.rollback_failures` into the parent manager's list before raising, so the
    child's entries come first, in rollback order.
  - `ComposeStep#undo`/`#compensate` returns `Failure` carrying the child's list when
    `undo_all` recorded any. The parent's `undo_step` flattens a Failure that has
    `rollback_failures`, and does not add one opaque entry for `:child`.
- **Out of scope**: map elements and `async_reactor` children keep the behavior they have on
  `main`. Their failures are separate records.

### R-09: F5, background step park state moves to the Step Result Record

- **On park**, `StepWorker#mark_record_parked` also writes:
  - `record["ordered_lock"]`: the step's stash entry, if there is one;
  - `record["waiting"]`: `{ step, primitive, key, attempts }`.

  `record_contention` keeps the log line and **no longer calls `save_root`**, and it does not
  append to the parent's trace.
- **On load**, `load_step_context` reads the record. When `record["ordered_lock"]` is present,
  it copies it (symbolized) into `found.private_data[:step_ordered_locks][step_name]`.
  `StepCoordination` then sees the stash exactly as before, and does not change.
- **Terminal**: `complete` writes a fresh record hash, so `ordered_lock` and `waiting` drop
  out of it. `discard_parked_state!` still advances the loaded stash when the ceiling is hit.
- **Dashboard**: `CoordinationSerializer` derives `waiting` for an `async_step` (by
  `step_config.async_dispatch == :step`) from the record's `waiting` field, and keeps
  `private_data[:step_contention]` for same-process steps.
- **Trade-off**: the parent's execution trace loses the `:contention_park` entry for an
  async_step park. The trace belongs to the parent, which is its one writer. The record and the
  structured `ruby_reactor.async_step.parked` log line carry the same facts.

### R-10: F9 attribution for a direct call

`StepCoordination#step_name` returns `step_config.name` when `@direct`. `Contended` messages,
`emit`'s `coordinating_step`, and rollback failures then name the class that was invoked.

### R-11: Documentation (FR-005, FR-016, FR-022–FR-024, FR-031)

| File | Change |
|---|---|
| `documentation/middlewares.md:128-140` | Use `context.coordinating_step`, with the example rewritten. Document `:snooze_step`. |
| `documentation/locks_and_semaphores.md` Step Contention (`:769-780`) | A park at any depth keeps every level's holds. Add the cross-level nesting-order rule and the A→B / B→A example (F6). |
| `documentation/locks_and_semaphores.md` Step Rollback (`:793-803`) | `rollback_wait:`, its defaults, and that it blocks a worker thread. `Failure#rollback_failures`. Correct the trace and hook names: a `type: :undo` entry plus `on_failed_undo`, and `type: :undo_failure` when raised. |
| `documentation/locks_and_semaphores.md` step ordered lock | The "background only" warning (D-F3). The stale-batch skip reason. |
| `documentation/locks_and_semaphores.md:866` | Use `coordinating_step`. |
| `README.md` | The `rollback_wait:` row in the step-coordination summary, if the options are listed there. `Failure#rollback_failures` in the Failure section. |
| `CHANGELOG.md` | Bug Fixes: F1–F10. Features: `rollback_wait:`, `Failure#rollback_failures`, `:snooze_step`. |

### R-12: Regression suite layout (FR-027, FR-028)

- New behavior files under `spec/ruby_reactor/step_coordination/`: `park_spec.rb`,
  `rollback_under_contention_spec.rb`, `ordering_parity_spec.rb` and
  `attribution_spec.rb`. The R-repros are written into these files first, and must fail on
  `ca963444`.
- Fold `review_fixes_spec.rb` (444 lines), `review_fixes_round3_spec.rb` (320) and
  `review_fixes_round4_spec.rb` (126) into the behavior files: park, rollback, ordering and
  observability, plus the existing `contention_spec.rb`, `rollback_spec.rb` and
  `observability_spec.rb`.
  - Compare example counts before and after, so no example is lost (SC-010).
  - Delete the three round files.
- Specs that assert the D4 **mechanism**, and not the behavior, change their assertion only:
  - `observability_spec.rb:141`, `primitives_spec.rb:286,291` and
    `review_fixes_round3_spec.rb:258` expect `RetryQueuedResult` from `executor.execute`.
  - They become `expect { … }.to raise_error(Error::StepContentionPark)`, or they drive the
    `Worker`.
  - FR-029 allows this: the park behavior is unchanged, and only its carrier moves.

### R-13: Demo (FR-030, Constitution VI)

- Extend `demo_app/app/reactors/step_lock_demo_reactor.rb`, or add a sibling
  `step_lock_rollback_demo_reactor.rb` if the existing reactor's inputs do not fit, with a
  rollback-under-contention path. A step holds the key briefly as an external owner, then
  fails. The locked step's undo waits and runs.
- Show the reporting path by setting `rollback_wait:` shorter than the hold.
- Add a `demo:step_lock` output line for each.
- Add a matcher `have_rollback_failure(step_name)`, optionally chained with
  `.for_key(key)` and `.because(reason)`, in `lib/ruby_reactor/rspec/matchers.rb`. The demo spec
  asserts through it.

## 3. Open risks

| Risk | Mitigation |
|---|---|
| The exception-based park misses a rescue site that swallows it. This is how F10 happened. | The table in R-01 is the checklist. R2, R4 and R6 exercise the composed path end to end. `grep -n "rescue StandardError"` over `lib/ruby_reactor/{executor,step,step_worker}*` is a review step in tasks. |
| Contexts saved before the upgrade lack `admitted` | The old inference is AND-ed in (R-03), so a legacy context behaves exactly as today. |
| `rollback_wait` blocks a worker thread for up to `ttl` | Documented, with an explicit knob. It happens only during rollback, and only under contention. |
| Changing `AsyncResultPending`'s superclass | It still inherits from `Error::Base`, and nothing matches its superclass by identity (`grep` shows 5 sites, all by name). |
| Map elements and `AsyncResultPending` (on `main`) | Out of scope, and listed in the spec's out-of-scope section via this research. The new rescue covers contention only. |
