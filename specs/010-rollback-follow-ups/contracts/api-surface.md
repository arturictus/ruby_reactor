# Contract: Public API Surface

Changes to what gem users call, receive, or observe. Internals appear only where a spec pins them.

## 1. `Reactor.continue` / `Reactor#continue` / `Reactor.continue_by_correlation_id`

Signatures are unchanged: `continue(id:, payload:, step_name:, idempotency_key: nil)` on the class,
`continue(payload:, step_name:, idempotency_key: nil)` on an instance.

### Outcomes

| Situation | Today | After 010 |
| --- | --- | --- |
| Valid payload, run `paused`, gates free | resumes inline and returns its result (`Success`, `Failure`, `InterruptResult` or `DispatchResult`) | unchanged |
| Valid payload, the reactor's `with_lock` / `with_semaphore` is held by another run | raises `Lock::AcquisitionError` / `Semaphore::AcquisitionError`; the run stays `paused` | **returns `DispatchResult`**; the run is `running`; a Worker resumes it once the lock frees (FR-009, FR-010) |
| Valid payload, `resume: :background` interrupt | returns `DispatchResult` | unchanged |
| Valid payload for a ready interrupt, run `running` (another resume, or the run is executing) | raises `ValidationError` "the reactor is running, not paused" | **returns `DispatchResult`**; the payload is applied once the run is free (FR-017–FR-019) |
| Second resume of the same interrupt (concurrent or later) | may run twice (inline mode) or race | **raises `ValidationError`** "Cannot resume: interrupt :x was already resumed" (FR-015, FR-020) |
| Invalid payload | the class method raises `InputValidationError`; the instance method returns `Failure(invalid_payload: true)`; one attempt counted | unchanged; the attempt is now counted in its own record (data-model §3) |
| Invalid payload at `max_attempts` | undoes, then saves `failed` (two unlocked writes) | same outcome, under the run's lock (R-08, R-09); may raise `Lock::AcquisitionError` if another execution holds the run for more than 5s |
| Interrupt not ready | raises `ValidationError` | unchanged |
| Run finished, `aborted`, `rolling_back`, or cancelled | raises `ValidationError` | unchanged (008 FR-032) |

A `DispatchResult` from a hand-off carries `execution_id: <run id>`. In inline job-testing mode, a
hand-off that already finished returns the reloaded result, as `resume: :background` does today
(`check_for_inline_completion`).

**Migration** (CHANGELOG): a `rescue Lock::AcquisitionError` / `Semaphore::AcquisitionError` around
`continue` no longer fires; the resume was accepted. Callers that treat any non-`Failure` result as
"resumed" need no change.

### Web dashboard API

`POST /api/reactors/:id/continue`:

- a `DispatchResult` answers `{ success: true, message: "Resume accepted" }`;
- an "already resumed" rejection answers 422 with the error.

## 2. `Reactor.undo(id)` on an `aborted` run

The signature is unchanged.

- If the run was interrupted during its failing step's `compensate`, that `compensate` runs again
  first, with the recorded arguments and failure, before the completed steps are undone (FR-022 to
  FR-025).
- The `reason` passed to the re-run `compensate`:
  - the original `String`, if the failure was a string;
  - an `RubyReactor::Error::RecordedFailure` (`StandardError`) otherwise, whose `message` is the
    original message and whose `original_class` is the original class name.
- A failing re-run is reported as any compensation failure is: a `:compensate` trace entry, a
  `:failed_compensation` middleware event, and a rollback failure. The undo stack is still replayed.
  The run still ends `cancelled` ("Undo triggered"), as manual undo does today.

Dashboard API (`GET /api/reactors/:id`): an `aborted` run whose `compensate` did not finish adds
`"pending_compensation": { "step": "<name>" }`. The GUI shows it on the run's detail view.

## 3. `map ... undo_all`

```ruby
map :refunds do
  source input(:payments)
  argument :payment, element(:refunds)
  step :charge, ChargeStep
  returns :charge
  fan_out batch_size: 100

  # Called once per rollback of this map, with the completed elements' results
  # (a lazy Enumerable, in index order), INSTEAD of each element's own undos.
  undo_all do |completed_results|
    Payments.bulk_refund(completed_results.map { |charge| charge[:id] })
  end
end
```

| Rule | Behavior |
| --- | --- |
| Declaration | optional; at most once per map; needs a block. Otherwise `Error::ValidationError` at class definition |
| When it is called | every rollback of the map: an atomic map's failure, a later step's failure, a manual undo |
| Argument | a lazy `Enumerable` of the results of the elements that completed, in index order; never every element's state at once |
| Not included | failed elements (they roll themselves back), halted, skipped |
| Not called | no element completed |
| Inline map with an `aborted` element (an interrupted run) | that element replays its own undos first; it is not passed |
| Return | `RubyReactor::Failure` or a raise is a failure; anything else is success |
| Failure | one rollback failure `{ step: <map>, kind: :undo_all, reason:, message: }`; the steps before the map are still undone |
| Fan-out | no element rollback jobs, no rollback records |
| Repetition | once per map rollback; at least once if the executing process dies mid-call |

## 4. Synchronous `Reactor.run`

The signature and results are unchanged. The run holds its liveness lock (`async:<id>`) while it
executes in the caller's process (R-01). Observable effects:

- `RubyReactor::Sweeper` / `RubyReactor.sweep_once` no longer re-enqueue it while it executes.
- `Reactor.undo(id)` of that run waits up to 5s, then raises `Lock::AcquisitionError`, as for a run
  executing in a worker today.

## 5. Worker behavior (background jobs)

| Change | Observable effect |
| --- | --- |
| It takes the run's liveness lock before it reads the run (waits up to 2s) | a Worker enqueued by a caller still finishing its hand-off starts within about 2s instead of racing it |
| It returns on terminal statuses, and on a `paused` run without claimed payloads | stray or duplicate Workers do nothing |
| Admitted runs are not limited by `lock_snooze_max_attempts` | a resumed run waiting on a reactor lock or semaphore is never marked `failed` without rollback; it logs `ruby_reactor.resume.waiting` once at the limit |

## 6. Structured logs (key=value)

| Event | Level | Fields |
| --- | --- | --- |
| `ruby_reactor.resume.deferred` | info | `reactor`, `context_id`, `step`, `reason` (`lock`, `semaphore`, `run_busy`, `background`), `key` |
| `ruby_reactor.resume.waiting` | warn | `reactor`, `context_id`, `error` (names the contended key), `snooze_count` |
| `ruby_reactor.map.rollback.undo_all.started` | info | `reactor`, `context_id`, `map_step`, `count` |
| `ruby_reactor.map.rollback.undo_all.completed` | info | `reactor`, `context_id`, `map_step`, `count`, `failed` |

## 7. RSpec surface (`lib/ruby_reactor/rspec/`)

| Addition | Contract |
| --- | --- |
| `TestSubject#resume(payload:, step:, process_jobs: nil)` | Accepts a `paused` **or `running`** run with a ready interrupt, mirroring `continue`. `process_jobs: false` leaves a hand-off pending; `nil` keeps the subject's setting. |
| `be_resume_deferred` | Passes when the subject's last `resume` returned a `DispatchResult` and the run is `running`. |
| `have_run_undo_all(:map_step)` / `.with_elements(n)` | Passes when the run's execution trace has an `:undo_all` entry for that map, with a count of `n`. |

The existing `hold_lock`, `be_paused_at`, `have_ready_interrupts`, `have_rollback_failure` and
`be_success` / `be_failure` are unchanged.
