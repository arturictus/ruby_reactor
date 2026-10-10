# 010 Rollback and Resume Follow-ups

Closes the seven "Rollback follow-ups (008)" items from `specs/future_improvements.md`.
Spec: `specs/010-rollback-follow-ups/spec.md` · Plan: `plan.md` · Decisions: `research.md` (R-01..R-19).

## What changes

| Story | Fix |
| --- | --- |
| US1 (P1): the sweeper re-ran live caller-process runs | `Executor#execute` holds the run's `async:<id>` liveness lock, auto-extended, and saves before releasing it (R-01). The sweeper is unchanged: it already skips locked runs. A killed process is recovered once the lock lapses. |
| US2 (P1): a caller's final save overwrote a worker's progress | With US1's lock, plus `Worker#perform` takes the run's lock **before** it reads the run (waiting up to 2s), and hands its owner to the executor, which re-enters the lock (R-02, R-03). |
| US3 (P1): a resume contended on the reactor's lock/semaphore raised and was lost | `continue` validates the payload, claims the interrupt, then either owns the run (lock, then reload, then resume inline) or hands the resume to a worker and returns a `DispatchResult` (R-05). After admission, `lock_snooze_max_attempts` no longer escalates a run to `failed` without rollback; it warns once with `ruby_reactor.resume.waiting` (R-07). |
| US4 (P2): two resumes of one interrupt could both run | Per-interrupt claim, `SET NX` on `reactor:<Class>:context:<id>:resume:<step>`, in every mode, including `Sidekiq::Testing.inline!` (R-04). The loser raises "already resumed" and writes nothing. |
| US5 (P2): a resume for another interrupt was rejected while the run executed | A `running` run accepts a claim for a ready, unexecuted interrupt and hands it to a Worker. The Worker applies claims under the run's lock at resume start, and resumes a `paused` run only when it has an unapplied claim (R-06). Attempt counts move to their own `INCR` record, so `continue` never writes the run unlocked (R-08). `Reactor#undo` reloads under its lock (R-09). |
| US6 (P2): a cut-off `compensate` of the failing step was never re-run | `mark_aborted` records the failing step, its arguments and its reason in `context.rollback`. `Executor#undo_all` re-runs it before the undo stack, so this works at any depth (composed child, inline map element). The dashboard API adds `pending_compensation`, and `ReactorDetail` shows it (R-10, R-11). |
| US7 (P3): map-level `undo_all` | `map ... undo_all { |completed_results| }` is called once per rollback with a lazy, index-ordered Enumerable. A fan-out map reads its result slots 1,000 at a time and dispatches no rollback jobs. An inline map reads element contexts one at a time, and `aborted` elements still replay their own steps (R-12, R-13). |

New RSpec surface:

- `TestSubject#resume(process_jobs:)`, which also accepts `running` subjects;
- `be_resume_deferred`;
- `have_run_undo_all(:map).with_elements(n)`.

Demo (Constitution VI):

- `BulkRefundDemoReactor` with `BulkRefundChargeReactor`, `ContendedApprovalDemoReactor` and
  `DualApprovalDemoReactor`;
- rake `demo:map_undo_all`, `demo:contended_resume` and `demo:concurrent_interrupts`, grouped as
  `demo:rollback_follow_ups` in `demo:all`;
- matcher-only specs.

Docs:

- README: Durability, Interrupts, Locks, Map;
- `documentation/`: `interrupts.md`, `locks_and_semaphores.md`, `background_and_async.md`,
  `data_pipelines.md`, `core_concepts.md`, `testing.md`;
- `demo_app/documentation/data_pipelines.md`;
- CHANGELOG;
- `specs/future_improvements.md`.

## Migration notes (also in CHANGELOG)

1. `continue` returns a `DispatchResult` where it raised `Lock::AcquisitionError` /
   `Semaphore::AcquisitionError`; a `rescue` of those simply stops firing.
2. A second resume of the same interrupt raises `ValidationError` "already resumed".
3. A resume for another ready interrupt of a `running` run is accepted (`DispatchResult`).
4. Interrupt attempt counts restart for runs paused across the upgrade.
5. A synchronous `Reactor.run` holds the run's liveness lock; `Reactor.undo` of such a live run
   waits, then raises `Lock::AcquisitionError`.

## Verification

- **Baseline (T002)**: `bundle exec rspec` on `5ca7d1d1`: 1479 examples, 0 failures, 2 pending.
- **After (T072)**: 1570 examples, 0 failures, 2 pending (the same two pending: the 009
  interrupt-inside-a-composed-child examples). Run on a dedicated test Redis DB
  (`RUBY_REACTOR_TEST_REDIS_URL=redis://localhost:6780/11`).
- **Tagged (T073)**: `--tag slow` (10,000-element `undo_all`: one call, memory flat across the
  enumeration, about 0.16s for the call) and `--tag fork` (a `SIGKILL`ed caller process is
  recovered): both pass.
- **`bundle exec rubocop`**: no offenses. **GUI**: `vitest` 69 tests pass; the bundle is rebuilt
  into `lib/ruby_reactor/web/public`.
- **Demo app (T075)**: 152 examples, 0 failures (local, test Redis DB 5).
- **Docker acceptance (T076)**: in an isolated compose project, `bin/rails demo:rollback_follow_ups`:
  - `demo:map_undo_all`: bulk refund called once with 12 charges, 0 per-element refunds, run
    `failed`. ✅
  - `demo:contended_resume`: resume accepted (`DispatchResult`) while the lock was held, run
    `completed` after release. ✅
  - `demo:concurrent_interrupts`: finance accepted (background), legal accepted while running,
    `completed` with both approvals. ✅

### `demo:all`: failures that are already on `main`

`demo:all` runs every demo against one Redis that is flushed once, with one Sidekiq process. On
`main` (run the same way, in a separate compose project) it already fails:

- `distributed_map_rollback` (70 charges for 40 orders);
- `composed_fan_out`, happy path and rollback (8 shipped instead of 5);
- `default_batch_size`;
- one `async_step` unit wait;
- `AsyncReactorDemoReactor(user_7)` (async wait timeout).

On this branch the same set fails, minus `default_batch_size` and the `async_step` unit. Each of
those demos passes when run alone (checked `demo:map_execution_undo` and
`demo:async_reactor_demo` on this branch). The three new tasks wait up to 120s, so they pass
inside `demo:all` too. The `demo:all` interference is out of scope here and worth its own issue.

## Regression proofs (red before green)

- **US1 (T014)**: with `Executor#execute`'s liveness lock removed, 5 of the 7 examples in
  `caller_process_liveness_spec.rb` fail.
- **US2 (T018)**: with the same line removed, the owner Worker started by the map's completion
  writes the run four times while the caller is still inside `execute`. With it, the Worker
  snoozes without reading or writing, and the run finishes once.
- **US4 (T032)**: with the claim disabled, the 200-iteration race accepts both resumes.
- **US6 (T046)**: with `compensate_pending!` disabled, 5 of the 9 examples fail.
- **The inline payload (found by the demo suite)**: with the caller's payload not applied as
  given, a string-keyed payload reached the step symbolized (`WebhookInterruptReactor` was
  rejected). Guarded by `interrupt_claims_spec.rb` ("as given, string keys included").

## Deviations from tasks.md

- **Spec placement**:
  - T015's example lives in `caller_process_liveness_spec.rb`;
  - T046 and T047 in a new `rollback/aborted_compensate_spec.rb`.
- **No `lib/reactors.ts` type for `pending_compensation`** (T054): the detail response is
  untyped.
- **`continue` on a `running` run always hands off.** It never tries the lock or runs another
  execution's run inline (research R-05, updated).
- **The `ruby_reactor.resume.waiting` line carries `error`** (whose message names the key), not a
  separate `key` field (contracts updated).
