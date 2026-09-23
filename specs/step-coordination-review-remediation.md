# Step-Scoped Coordination: Review Findings and Remediation Plan

**Feature**: `specs/003-step-lock-declarations/`
**Branch**: `independent_step_locks`, reviewed at `ca963444` against `main@6608f7b9`
**Date**: 2026-09-23
**Source**: `/speckit-review`. Verdict: **BLOCKED**, with 4 blockers and 5 findings.

## Summary

The branch is green: 1101 examples and 0 failures, `demo:step_lock` passes, and the demo_app
spec passes. The defects below are in paths the suite does not exercise: a contention park
inside a composed child, rollback while another execution holds the key, synchronous
contention on a step-level ordered lock, and a step or batch outliving
`poison_pill_timeout`. R1–R5 are small repro specs that demonstrate them. Each is described
under **Verification** so it can become a permanent spec.

**Recommendation.** Refactor two root causes (A and B), and fix the rest in isolation.

- **Why not a fix per finding.** This branch has already been through four review rounds
  (`review_fixes_spec.rb`, `review_fixes_round3_spec.rb`, `review_fixes_round4_spec.rb`).
  Patching each literal finding keeps opening the next hole. Five of the nine findings are
  two design flaws showing up in different places.
- **Why not a broad rewrite.** The redesign in `ca963444` held up. One enforcement site per
  invocation (D2), one argument derivation (`coordination_arguments` / `body_arguments`),
  and parks releasing the step's own holds (D6) all passed review. The retry (G3) and
  validation (G6) gates passed outright. Rewriting those would restart the review loop for
  no gain.

## Findings

| ID | Severity | Summary | Root cause | Reproduced |
|----|----------|---------|------------|------------|
| F1 | BLOCKER | Undo of a locked step is dropped when another execution holds the key; nothing retries it | C | R1 |
| F2 | BLOCKER | A contention park inside a composed child releases the parent's reactor lock and charges the parent's rate limit again | A | R2, R4 |
| F3 | BLOCKER | A synchronous out-of-turn arrival at a strict step-level ordered lock poisons the chain; later executions skip the step yet report success | B | R3 |
| F4 | BLOCKER (doc) | The docs say `context.current_step` is nil for reactor-level lock events; it is not on resumed runs | A | R5 |
| F5 | FINDING | The async_step worker persists park state by blind-overwriting the parent's root context blob | D | — |
| F6 | FINDING | Keeping the reactor hold across a step park allows a cross-reactor A→B / B→A livelock | E | — |
| F7 | FINDING | The step gate treats `:stale_batch` as "go" and runs the body unordered | B | — |
| F8 | FINDING | The step's ordered-lock heartbeat is not stopped on non-`StandardError` exits | B | — |
| F9 | FINDING | A nested direct `Step.run(args, context)` is attributed to the calling step | E | — |

---

## A. Two park mechanisms, and an overloaded `current_step` (F2, F4)

### Problem

An execution can park for two reasons, and each uses a different mechanism.

- **Async-result park.** `Error::AsyncResultPending` is an exception. It propagates up
  through every executor to the root `resume_execution` (`executor.rb:262`). The root parks
  its reactor-level holds (`park_held_primitives!`) and the `Worker` snoozes the job.
- **Step contention park** (D4). This is a return value. `StepExecutor#handle_contention`
  (`step_executor.rb:230`) calls `RetryManager#park_for_contention` (`retry_manager.rb:34`),
  which requeues the job and returns a `RetryQueuedResult`. The only executor that parks its
  holds is the one whose step contended, through the `on_contention_park` callback
  (`executor.rb:63`, called at `retry_manager.rb:77`).

When the contended step belongs to a composed child, the root executor receives a
`RetryQueuedResult` passed through `compose_step.rb:92`. The root has not parked
(`@parked == false`), so it releases its own reactor lock at `executor.rb:276`.
`handle_contention` pins `current_step` on the child's context only. The root's
`Context#with_step` resets the root's `current_step` on the way out
(`context.rb:111-117`). If the compose step is the root's first step, `first_execution?`
(`executor.rb:406`) is true on redelivery, so the root re-applies its reactor-level rate
limit and period gate.

That breaks two documented guarantees:

- `documentation/locks_and_semaphores.md:778`: "Coordination the *execution* already held
  before reaching the step (the reactor's own lock and semaphore) stays checked out across
  the gap".
- `documentation/locks_and_semaphores.md:780`: "a park never charges (or double-charges on
  redelivery) the reactor's own rate limit or period gate".

`current_step` is doing three jobs:

1. It is the resume cursor.
2. It drives the first-run inference (`first_execution?`, and `fresh_ordered_lock_start?` in
   `ordered_lock_support.rb:104`).
3. The docs tell middleware authors to use it to attribute events.

The third job is F4. `middlewares.md:132` and `locks_and_semaphores.md:866` say it is nil for
a reactor-level event. After a park redelivery, the reactor-level `:lock_released` fires with
`current_step = :charge`. The correct signal already exists: `context.coordinating_step`,
which `StepCoordination#emit` sets and `open_telemetry.rb` already reads.

### Proposed change

**A.1 Make both parks one mechanism.** Contention parks through an exception, like
`AsyncResultPending`. It would be a new `Error::StepContentionPark` that carries the
`Contended`, including `original` and `retry_after_seconds`, so `Worker.snooze_delay` works
unchanged.

- `StepExecutor#handle_contention` keeps the ceiling check, the `:contention_park` trace
  entry and the `:step_contention` marker. It then raises instead of requeuing.
- The root `resume_execution` rescues the new exception next to `AsyncResultPending`, calls
  `park_held_primitives!`, and re-raises.
- `Worker#perform` adds it to its snooze rescue list (`worker.rb:132-137`) and treats it as
  uncapped in `handle_snooze` (`worker.rb:193`). The ceiling is already enforced where it is
  raised, using the per-step counter in `RetryContext`.
- **Remove**: the `on_contention_park` callback, the requeue branch of `park_for_contention`,
  and `RetryQueuedResult` as a contention outcome.
- **Amends research D4.** The mechanism changes; the behavior (park and retry, a separate
  counter, a ceiling) does not.
- **Required alongside**: `Map::ElementExecutor` calls the executor directly, not through
  `Worker`. It currently relies on `RetryQueuedResult` (`element_executor.rb:72`), so it must
  rescue the new exception and requeue through `perform_map_element_in`. `StepWorker`
  (async_step) keeps its own park, because it is not a reactor run.

**A.2 Every executor on the stack parks its holds.** Today a composed child's `execute`
releases its own reactor lock on `AsyncResultPending` (`executor.rb:152`). The parent's hold
survives, but the child's does not. That leaves a gap in exclusion partway through an
execution, and it contradicts `:778` for the child's lock. See decision D-A2 below.

**A.3 Stop inferring "first run" from `current_step`.** Persist an explicit marker once the
reactor-level gates have passed, for example `private_data[:reactor_gates_passed] = true`.
Base `first_execution?` on that marker. Apply the same check to `fresh_ordered_lock_start?`.
A.1 alone does not fix the double charge: the exception still unwinds through the root's
`with_step`.

**A.4 (docs, can ship now).** Replace `current_step` with `context.coordinating_step` in
`middlewares.md:128-140` and `locks_and_semaphores.md:866`, including the code example.

---

## B. The step ordered-lock gate re-implements `OrderedLockSupport` (F3, F7, F8)

### Problem

`StepCoordination` (`step_coordination.rb:276-469`) has its own copy of the gate, the
heartbeat and the terminal advance. Each divergence from the reactor-level implementation
has become a defect:

| Aspect | Reactor level (`ordered_lock_support.rb`) | Step level (`step_coordination.rb`) | Finding |
|---|---|---|---|
| `:stale_batch` from `check!` | Short-circuits with a Halt (`:81`, `:125`) | Not handled; falls through and runs the body (`:285-296`) | F7 |
| Synchronous out-of-turn arrival | Raises `WaitError`; nothing is advanced and nothing is recorded as failed | `advance(failed: true)` (`:303-311`), which records `fail_key` for any nonce ahead of the cursor (`redis_ordered_locking.rb:214-218`) | F3 |
| Heartbeat stop | In `ensure` (`leave_ordered_lock_scope`) | Only in `rescue StandardError` and on the success path (`:436-469`) | F8 |

**F3 impact (R3).**

1. E1 holds its turn.
2. E2 reaches the step synchronously and fails with a contention error, which is expected.
3. E3 runs afterwards with no contention. It returns `success? == true`, but its ordered step
   was skipped: the value is nil and the body never ran.

This continues for every strict position until the batch drains. The step docs
(`locks_and_semaphores.md:776`) describe only the contended run failing.

**F7 impact.** A step that fails with a retryable error keeps its nonce (`retry_pending?`)
and stops heartbeating. If one backoff is longer than `poison_pill_timeout`, the steps
behind it skip past it and the batch drains. The retry's gate then returns `:stale_batch`,
and the body runs unordered, alongside the new batch's current holder.

**F8 impact.** If the body raises `SystemStackError` or `NoMemoryError`, the heartbeat thread
keeps refreshing the nonce for the life of the worker process. The poison-pill timeout never
releases it, so the key's sequence stalls until the process restarts.

### Proposed change

**B.1 One gate.** Extract from `OrderedLockSupport` a pure function that maps the result of
`OrderedLock#check!` to an outcome: `:go`, `:wait`, `:skip_chain`, `:stale`, `:drained`.
Reactor level and step level both call it. The step level then maps each outcome:

| Outcome | Step-level action |
|---|---|
| `:go` | Run |
| `:wait` | Raise `Contended`: park in a worker, fail when synchronous |
| `:skip_chain` | `Skipped(reason: :ordered_lock_chain_failed)`, then `advance(failed: false)` |
| `:stale` | `Skipped(reason: :ordered_lock_stale_batch)` with no advance (the epoch fence makes it a no-op anyway). Fixes F7. |
| `:drained` | Run: a late straggler, same as the reactor level. Replay is already impossible because the stash is deleted when the step finishes. |

**B.2 One position lifecycle.** A shared helper, for example
`OrderedLockSupport.with_position(info) { ... }`, that starts the heartbeat, yields, and stops
it in `ensure` (fixes F8). It advances once, from a single terminal-outcome decision:
success, failure, retry pending, parked, or synchronous contention.

**B.3 Synchronous out-of-turn does not poison the chain.** See decision D-F3. The
recommendation is `advance(failed: false)` for a position that was not at the head: it clears
the position's timer, so later positions proceed immediately, and records no `fail_key`.
Keep `failed: true` for a position that reached the head and then failed. Copy the
reactor-level "use only on `background all: true`" warning
(`locks_and_semaphores.md:494`, `:665`) into the step section.

---

## C. Rollback uses the forward-work contention policy (F1)

### Problem

`CompensationManager#coordinated_rollback` (`compensation_manager.rb:104`) re-takes the
step's lock using `StepCoordination#around_rollback`, and that uses the forward `wait:`
(`step_coordination.rb:203-214`). The default is 0 (`dsl/lockable.rb:52`).

**Failure scenario (R1).**

1. `:charge` (`with_lock`) succeeds.
2. A later step fails while another execution is inside `:charge` for the same account.
3. The undo fails immediately with "could not re-acquire lock … for rollback of :charge",
   so the refund never runs.

The caller's Failure names only the downstream error. The dropped undo is visible only as a
`type: :undo` trace entry and the `on_failed_undo` hook, and nothing retries it. The
contention the lock exists for is exactly the condition that skips the cleanup.

Two artifacts endorse this behavior and need correcting:

- **FR-026** ("reported rather than silently skipped") permits it. The research "Open risks"
  row claims "Compensation waits then reports", which does not happen with the default wait.
- `locks_and_semaphores.md:802` says "a `:failed_undo` trace entry". The trace entry type is
  `:undo`; `:failed_undo` is the middleware hook.

### Proposed change

See decision D-F1.

1. Give rollback its own bounded wait, for example a new `rollback_wait:` option that
   defaults to the lock's `ttl`, instead of the forward `wait:`. The forward holder's step
   will finish, and its lock expires at worst.
2. Show an undo that did not run on the reactor's `Failure`, for example
   `failure.rollback_failures`, so the caller can act on it. This also closes the existing
   gap for exceptions raised inside undo, which today are only traced.
3. Amend FR-026, the research open-risk row, and `locks_and_semaphores.md:802`.

---

## D. Two processes write the root context blob (F5)

### Problem

`StepWorker#record_contention` (`step_worker.rb:159-171`) persists an async_step's
ordered-lock position (`private_data[:step_ordered_locks]`) and its `:step_contention` marker
through `save_root` (`:453-462`). That overwrites the whole root blob with no context lock.
Meanwhile the parent executor may still be running sibling steps and checkpointing the same
blob.

- **Parent writes last.** The stash is erased. The redelivery takes a fresh nonce and loses
  its place, contradicting FR-018. The old nonce stays in flight and blocks every position
  behind it for `poison_pill_timeout` (600s by default).
- **Worker writes last.** The parent's newer checkpoint is lost. A crash before the parent's
  next write then re-runs steps that already completed.

### Proposed change

Keep async_step park state in the Step Result Record, which has one writer per unit and
already holds `parked_until` and `contention_attempts` (`mark_record_parked`, `:185-200`).

- On load, `StepWorker` copies the record's stashed position into the step context's
  `private_data` before running. On park, it writes the stash back to the record.
  `StepCoordination` does not change.
- Remove `save_root` from `record_contention`.
- The dashboard reads the waiting state of an async_step from the record.

---

## E. Isolated fixes (F6, F9)

- **F6.** `park_held_primitives!` (`executor.rb:591-607`) keeps the reactor lock across a
  step park, and each redelivery reattaches it and refreshes the TTL (`executor.rb:530`).
  Consider reactor X (reactor lock A, step lock B) and reactor Y (reactor lock B, step
  lock A). With `lock_snooze_max_attempts: :infinity` they wait on each other forever; with
  the default (20) both give up after about 20 snoozes.
  **Change:** add a nesting-order rule to `locks_and_semaphores.md` ("always nest keys in one
  global order across reactor and step levels"), and state that a step park keeps the
  reactor hold.
- **F9.** For a direct call, `StepCoordination#step_name` (`step_coordination.rb:698-704`)
  returns the caller's `context.current_step`. The `Contended` message and
  `coordinating_step` therefore name the calling step, not the class invoked, which violates
  US7-2.
  **Change:** when `@direct`, use `step_config.name`.

---

## Decisions needed before coding

Record these in `specs/003-step-lock-declarations/research.md` before implementing, so a later
review cannot reverse them without a written reason.

| ID | Question | Options | Recommendation |
|----|----------|---------|----------------|
| D-F1 | What does rollback do when the key is held? | (a) wait up to a rollback-specific bound (default `ttl`); (b) run the undo without the lock and log a warning; (c) park the rollback (needs resumable rollback: large) | (a), and show undos that did not run on the Failure |
| D-F3 | Does a synchronous out-of-turn arrival poison the strict chain? | (a) no: hand the position back with `failed: false`, allowing a gap, as the reactor level eventually does after the poison pill; (b) yes: strict purity, but document it and make the skipped positions visible | (a), plus the "background only" warning |
| D-A2 | On a park, does every executor on the stack keep its reactor holds, or only the root? | (a) every executor, matching FR-018 and `:778` literally; (b) root only, and narrow the docs | (a). Otherwise a composed child's exclusion lapses partway through an execution. |

## Order of work

1. **Docs-only fixes**: A.4 (F4), `:802` (F1 wording), F6 nesting rule. No risk; can ship at
   once.
2. **Decisions**: D-F1, D-F3 and D-A2 recorded in `research.md`. Amend FR-026 and D4.
3. **Refactor B** (F3, F7, F8). Self-contained, and covered by the existing ordered-lock
   specs at both levels. Add R3 first.
4. **Refactor A** (F2, and removal of the D4 mechanism). The riskiest step: it touches the
   executor, compose, `Map::ElementExecutor` and `Worker`. Add R2 and R4 first, and run the
   full suite and `demo:step_lock` afterwards.
5. **Isolated fixes**: C (F1, add R1 first), D (F5), F9.
6. **Spec cleanup**: fold `review_fixes_spec.rb`, `review_fixes_round3_spec.rb` and
   `review_fixes_round4_spec.rb` into files named by behavior (park, rollback, ordering,
   observability), so the next review groups by root cause, not by round.

## Verification

Each repro should become a permanent spec named by the behavior it protects. Each one failed
or showed the defect on `ca963444`.

| Repro | Setup | Expected after the fix |
|-------|-------|------------------------|
| R1: rollback under contention | Synchronous reactor. `:charge` is a step class with `with_lock` (default `wait:`) and an `undo`. The next step takes the same key as an external owner, then raises. | The undo runs (with D-F1 (a)), or the reactor Failure lists the undo that did not run. Today: `UNDONE == []`, and the trace shows `could not re-acquire lock`. |
| R2: parent rate limit across a composed park | `background all: true` parent with `with_rate_limit`, composing a child whose first step has `with_lock`. Hold the child's key externally; perform the worker job once (it parks), release the key, perform again. | Parent rate-limit count == 1. Today: 2; the no-contention control is 1. |
| R3: sync out-of-turn ordered step | Synchronous reactor with a strict `with_ordered_lock` step. E1 in a thread sleeps inside the step; E2 runs synchronously; E3 runs after E1 finishes. | E3's step body runs. Today: E3 returns `success?` true, its step value is nil, and only E1's body ran. |
| R4: parent lock across a composed park | As R2, but the parent has `with_lock`. Check `lock_info` for the parent key after the first (parking) perform. | Parent lock held. Today: released. The same setup with the locked step at root level keeps it held. |
| R5: middleware attribution | `background all: true` reactor with `with_lock`, a step with `with_lock`, and a recording middleware. Park the step once, then complete. | Reactor-level events have `coordinating_step == nil`. The docs name `coordinating_step`. Today, `:lock_released` for the reactor key has `current_step == :charge`. |
| F7 (new) | Ordered step with retries; stub `OrderedLock#check!` to return `:stale_batch` on the retry. | The step is Skipped with `:ordered_lock_stale_batch`; the body does not run. |
| F8 (new) | Ordered step whose body raises a non-`StandardError` (for example `NoMemoryError`, stubbed). | The heartbeat thread is stopped (`Thread#alive?` false). |

Commands:

```bash
bundle exec rubocop
bundle exec rspec
docker compose run --rm demo-app bin/rails demo:step_lock
docker compose run --rm -e RAILS_ENV=test demo-app bundle exec rspec spec/reactors/step_lock_demo_reactor_spec.rb
```

## Out of scope (existing on `main`, noted during review)

- `StepWorker#complete` also calls `save_root` (it was there before this branch). It has the
  same two-writer risk as F5, but for the completion record. Worth addressing together with D
  if it is cheap.
- Reactor-level `release_locks` emits `:lock_released` with the prefixed key
  (`"lock:<key>"`), while `:lock_acquired` and all step-level events use the bare key. R5
  showed this. Middleware consumers see two formats.
- `bundle exec rubocop` reports one offense in `spec/map/map_inline_execution_spec.rb:103`
  (`RSpec/MultipleMemoizedHelpers`), a file this branch does not touch.
