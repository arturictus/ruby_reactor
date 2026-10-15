# Changelog

## Unreleased

### ⚠ BREAKING CHANGES

* **`retries` on a `compose` or an `async_reactor` raises `RubyReactor::Error::DeprecatedDslError`
  at class definition.** A parent never retries a nested reactor as a whole: the child retries its
  own steps. Before, a compose-level retry resumed a child whose earlier steps had already been
  undone. Declare `retries` on the child's steps instead.
  See *Migration notes: reliable rollback* below.
* **`where` and `guard` are removed.** Declaring either on a `step`, `async_step` or `interrupt`
  raises `RubyReactor::Error::DeprecatedDslError` at class definition. A step that should not run
  returns `Skipped(value)` (or calls `skip!(value)`) from its body.
  See *Migration notes: reliable rollback* below.
* **`Skipped` no longer changes execution.** It is an instrumentation mark (the trace records it;
  `skipped?` is true): a `background after:` step that returns `Skipped` now hands the rest of
  the run off like any completed step (before, the rest ran in the calling process), and a
  `with_period` step whose body returns `Skipped` marks its bucket. A skipped step is still never
  undone.
* **An exception that is not a `StandardError` fails the step and rolls back.** A
  `NotImplementedError`, a `LoadError`, a `SystemStackError` or a custom `Exception` subclass
  raised by reactor code (a step body, an argument transform, a `compensate`/`undo`, a key proc, a
  `collect` block) is now that step's failure: the step is compensated if its body ran, completed
  steps are undone, and `Reactor.run` returns the `Failure` instead of raising. Only interruptions
  (`SignalException` including `Interrupt`, `SystemExit`, `NoMemoryError`, and an enclosing
  `Timeout.timeout`'s interruption) still skip rollback and propagate.
  See *Migration notes: reliable rollback* below.
* **An `async_step`'s `compensate` runs, in the unit's own job, when its final attempt fails.**
  Before, `compensate`/`undo` blocks on an `async_step` were accepted and never ran. Now the unit
  compensates itself once, after its last retry, whether or not any step reads its result —
  never for a retried attempt, a halt, or a body that never started. The outcome is recorded on
  the unit's Step Result Record as `compensation: { status, rollback_failures, completed_at }`,
  and the compensation middleware events fire in the unit's job. A reader that surfaces the
  failure no longer leads to a second compensation of the unit.
  See *Migration notes: reliable rollback* below.

* **An inline `undo` inside `async_step` raises `RubyReactor::Error::ValidationError` at class
  definition.** An independent async unit is never undone, so the block could never run. A step
  class that defines `undo` and is used with `async_step` prints a definition-time warning
  instead (the same class may be reused by ordinary steps, where its `undo` runs).
  See *Migration notes: reliable rollback* below.
* **A map rolls back the elements that completed.** When a map fails (an element fails under
  `fail_fast`, or `collect` raises), and when a later step fails or the run is undone manually,
  every completed element is rolled back by replaying its own step `undo`s, highest index first —
  in inline and fan-out mode, whatever order the element jobs ran in. Before, completed elements
  were never rolled back. A fail-fast fan-out map now waits for elements already in flight before
  it reports its failure, and settles the elements it never started as skipped (which also stops
  the map sweeper re-dispatching them). An element rollback that does not complete is listed in
  `Failure#rollback_failures` with `map_step:` and `element_index:`; an element whose context
  (or the map's element index) expired is reported with `reason: :context_unavailable`, and a
  still-running duplicate with `reason: :element_in_flight`. A fan-out map whose rollback is
  incomplete fails with the same `CompensationError` shape as an inline map.
  See *Migration notes: reliable rollback* below.
* **`RubyReactor::Step` is now a base class, not a mixin.** `include RubyReactor::Step` on a
  plain class with `def self.run(arguments, context)` is gone — no compatibility shim, no dual
  authoring style. A step subclasses `RubyReactor::Step` and writes `run` (and optionally
  `compensate`/`undo`) as **instance** methods reading the validated arguments and the context
  through `inputs`/`context` accessors instead of parameters. Every instance is built fresh for
  its one action (`run`, `undo`, or `compensate`) from the stored arguments/result/reason alone —
  nothing an author sets in `run` is visible in a later `undo`/`compensate`, which is exactly what
  makes rollback behave identically whether it lands in the same process as `run` or, as with an
  `async_step`, in a separate later one. `inputs` holds the same values in all three actions: the
  arguments with the contract's defaults applied. Only `run` enforces the contract; `undo` and
  `compensate` never do, so rollback cannot fail on the inputs that caused the failure.

  ```ruby
  # Before
  class ChargeStep
    include RubyReactor::Step

    input :amount, :integer, gteq?: 1

    def self.run(arguments, context)
      Success(charge!(arguments[:amount]))
    end

    def self.undo(result, arguments, context)
      refund!(result[:charge_id])
      Success()
    end
  end

  # After
  class ChargeStep < RubyReactor::Step
    input :amount, :integer, gteq?: 1

    def run
      Success(charge!(inputs[:amount]))
    end

    def undo
      refund!(result[:charge_id])
      Success()
    end
  end
  ```

  **Migration:** for every class step, replace `include RubyReactor::Step` with
  `< RubyReactor::Step`, turn `def self.run(args, ctx)` into `def run` reading `inputs`/`context`,
  and likewise for `def self.undo(result, args, ctx)` / `def self.compensate(reason, args, ctx)` →
  `def undo` / `def compensate` reading `result`/`reason`/`inputs`/`context`. The class-level
  `MyStep.run(arguments, context)` / `.call` / `.undo(result, arguments, context)` /
  `.compensate(reason, arguments, context)` entry points every caller (executor, worker, a direct
  unit-test call) already used are unchanged. Inline `step { run { |args, ctx| ... } }` blocks are
  untouched by this change.

* **A class step's signal helpers (`success!`/`fail!`/`skip!`/`halt!`) now translate correctly on
  every execution path, including the `async_step`/`background` worker.** Previously the worker had
  no `catch` of its own, so a signal thrown from a class step running there escaped as an
  `UncaughtThrowError` instead of the intended `Success`/`Failure`/`Skipped`/`Halt` — the base
  class's class-level `run`/`undo`/`compensate` now own that translation, so every caller gets it
  for free with no worker change. Known remaining gap, unchanged by this release: an **inline**
  `run`/`compensate`/`undo` block's signals are still uncaught on the worker path.

* **A step's own input-validation failure is now guaranteed non-retryable on every path.**
  `result.retryable?` is `false` whether the violation happened synchronously, inside an
  `async_step`/`background` worker, or inside a `compose`d child's own step — previously only the
  async worker path got this right; the synchronous path and a validation failure surfacing
  through `compose` both defaulted to `retryable? == true`.

* **`Failure(...)` takes the same arguments everywhere.** Inside a class step and inside an inline
  `run`/`compensate`/`undo` block, `Failure` now forwards every argument to `RubyReactor.Failure`,
  so options such as `Failure("declined", retryable: false)` work instead of raising
  `ArgumentError`. A bare `Failure()` with no error is no longer accepted, matching
  `RubyReactor.Failure`, and a hash error needs braces, `Failure({ code: 1 })`, because a braceless
  `Failure(code: 1)` is now read as options.


### Migration notes: reliable rollback

Every breaking or shape-changing item of the rollback work, with what to change.

1. **Map element `undo`s now run** (breaking, behavior). They run when the map fails, when a later
   step fails, and on a manual `Reactor.undo(id)`. Make them idempotent.

   ```ruby
   # Before: this undo never ran for a map element; charges stayed on a failure.
   # After: it refunds each charged element, highest index first. Guard against a double refund.
   class ChargeStep < RubyReactor::Step
     def undo
       Payments.refund(result[:charge_id]) unless Payments.refunded?(result[:charge_id])
       Success()
     end
   end
   ```

2. **An `async_step`'s `compensate` now runs in the unit's job** (breaking, behavior), once, after
   its final attempt fails, whether or not a reader exists. Move reader-only cleanup into the
   reader.

   ```ruby
   # Before: never ran.
   async_step :notify, NotifyStep do
     compensate { |error, inputs, _ctx| Audit.undelivered(inputs.user_id, error) }
   end
   # After: runs in the unit's job after the last retry; the outcome is on the unit's record
   # as `compensation`. Cleanup that should run only when a reader fails the reactor:
   step :confirm do
     argument :delivery, result(:notify)
     run { |inputs, _ctx| inputs.delivery.is_a?(RubyReactor::Failure) ? Failure("undelivered") : Success() }
     compensate { |_error, _inputs, _ctx| Support.open_ticket }
   end
   ```

3. **An inline `undo` inside `async_step` raises at class definition** (breaking, API).

   ```ruby
   # Before: accepted, never ran.
   async_step(:notify) { run { ... }; undo { ... } }
   # After: raises RubyReactor::Error::ValidationError. Use the unit's `compensate`, a reader's
   # `compensate`, or an `async_reactor` child whose steps declare `undo`.
   async_reactor :notify, NotifyReactor   # NotifyReactor's steps declare `undo`
   ```

4. **`retries` on `compose` / `async_reactor` raises at class definition** (breaking, API). Move
   the retries onto the child step that can fail transiently. The child retries it itself; the
   other child steps run once.

   ```ruby
   # Before: retried the whole child from the parent.
   compose(:booking, BookingReactor) { retries max_attempts: 2 }
   # After: raises RubyReactor::Error::DeprecatedDslError. Declare it on the child's step:
   class ConfirmBookingStep < RubyReactor::Step
     retries max_attempts: 2
   end
   compose :booking, BookingReactor
   ```

5. **`where` / `guard` are removed** (breaking, API). Skip from the step body. Unlike `where`,
   the body decides after the step started: its arguments are resolved and validated (a step
   that relied on `where` to avoid invalid arguments now fails on them), and its lock, semaphore
   and rate-limit slot are taken first. A `background before:` hand-off at that step now always
   fires; the body decides in the worker.

   ```ruby
   # Before
   step :sync_user do
     where { |ctx| ctx.get_input(:enabled) }
     run { |inputs, _ctx| Success(sync!(inputs.user)) }
   end
   # After
   step :sync_user do
     run do |inputs, ctx|
       next Skipped(nil) unless ctx.get_input(:enabled)
       Success(sync!(inputs.user))
     end
   end
   ```

6. **Non-`StandardError` exceptions from reactor code roll back** (breaking, behavior). They no
   longer propagate out of `Reactor.run`; check the returned `Failure` instead. A test assertion
   error raised inside a step body (an RSpec expectation, a strict double) now surfaces as the
   step's `Failure`, so assert on the result.

   ```ruby
   # Before: NotImplementedError propagated; nothing was undone; the run was stored `aborted`.
   # After:
   result = MyReactor.run(inputs)
   result.failure?         # => true, completed steps undone
   result.exception_class  # => "NotImplementedError"
   ```

7. **Argument and unknown errors roll back and carry `step_name`** (fix). The Failure's
   shape changes on these paths.

   ```ruby
   # Before: "Execution failed: invalid value for Float(): 'abc'", step_name nil, nothing undone.
   # After: "Step 'charge' failed: Step 'charge' could not resolve its arguments: …",
   #        step_name :charge, exception_class "ArgumentError", completed steps undone.
   result.step_name        # => :charge
   result.exception_class  # => "ArgumentError"
   ```

8. **New `aborted` status** (additive), only for runs in the caller's process cut short by an
   interruption. Dashboards and status filters gain a value; an `aborted` run needs
   `MyReactor.undo(id)` to roll back.

9. **`rollback_failures` entries may carry `map_step:` / `element_index:`** and the reasons
   `:context_unavailable` / `:element_in_flight` (additive).

### Migration notes: rollback and resume follow-ups

1. **A resume that meets the reactor's held `with_lock` or `with_semaphore` no longer raises.**
   `continue` used to raise `Lock::AcquisitionError` / `Semaphore::AcquisitionError` and leave
   the run paused. It now validates the payload, accepts the resume, and returns a
   `RubyReactor::DispatchResult`; a worker waits for the lock and finishes the run. A `rescue` of
   those errors around `continue` simply stops firing. An invalid payload is still answered at
   once, as before.
2. **A second resume of the same interrupt raises `ValidationError`** ("Cannot resume: interrupt
   :x was already resumed"), in every execution mode, including `Sidekiq::Testing.inline!`.
3. **A resume for another ready interrupt of a `running` run is accepted** (it used to raise "the
   reactor is running") and returns a `DispatchResult`.
4. **Interrupt attempt counts restart** for runs paused across the upgrade: they move out of the
   run's context into their own record, so such a run may take up to `max_attempts - 1` extra
   invalid payloads.
5. **A synchronous `Reactor.run` holds the run's liveness lock** while it executes. A
   `Reactor.undo(id)` of a run still executing in its caller's process now waits for it, then
   raises `Lock::AcquisitionError`, as it does for a run executing in a worker.

### Features

* **An `interrupt` inside a composed child pauses the top-level run.** Before, the compose step
  failed with `NoMethodError` and the run rolled back. Now the top-level run is stored `paused`, at
  any compose depth and after a `fan_out` map in the child, and the paused result carries its id.
  Resume it on the top-level class by the interrupt's step path, an Array of the compose step names
  then the interrupt (`continue(id:, payload:, step_name: [:approval, :wait_for_manager])`), by id
  or by the child interrupt's correlation id. Payload validation, `max_attempts`,
  `resume: :background` and the resume guards apply as for a top-level interrupt. A resume
  contended on the child's own `with_lock`/`with_semaphore` fails and rolls back the run. Contention
  on the top-level reactor's lock hands the resume to a worker. `Reactor.undo`
  of the paused run rolls back the child's completed steps, then the parent's. A composed child
  refuses a `continue` of its own. New `Reactor#ready_interrupt_steps` lists the pending
  interrupts (Symbols, and paths for nested ones). `be_paused_at`, `have_ready_interrupts` and
  `TestSubject#resume(step:)` accept paths. A `continue` must now name a pending interrupt: naming
  another ready step, which used to store the payload as that step's result, raises
  `ValidationError`. An `interrupt` inside a `map` element now fails that element with "not
  supported inside a map element" instead of `NoMethodError`.
  See [Interrupts inside composed reactors](documentation/interrupts.md#interrupts-inside-composed-reactors).
* **`undo_all` on a map: one call rolls back every completed element.** A map declaring
  `undo_all { |completed_results| ... }` is rolled back (an atomic map's failure, a later step's
  failure, or `Reactor.undo`) by calling the block once with a lazy, index-ordered Enumerable of
  the completed elements' results, instead of replaying each element's own undos. A fan-out map
  reads its stored results and dispatches no element rollback jobs; nothing is held in memory all
  at once. Failed elements still roll themselves back; a block that raises or returns a
  `Failure` is reported as one rollback failure (`kind: :undo_all`) and the steps before the map
  are still undone. New matcher: `have_run_undo_all(:map).with_elements(n)`.
* **A resume contended on the reactor's lock or semaphore is accepted, not lost** (see migration
  note 1). New test helpers: `resume(..., process_jobs: false)` and the `be_resume_deferred`
  matcher.
* **Several interrupts can be resumed at once** (see migration note 3): each accepted resume is
  applied once.
* **`fan_out` without `batch_size` is back-pressured: at most 50 element jobs per throw**
  (`RubyReactor::Map::DEFAULT_BATCH_SIZE`), forward and rollback. Before, every element was
  enqueued at once. A map of more than 50 elements with no declared `batch_size` now runs in
  throws of 50, which can lower its peak throughput: declare a larger `batch_size` to keep more
  element jobs in flight.
* **Distributed rollback of fan-out maps.** A `fan_out` map that must be rolled back (it failed,
  a later step failed, or `Reactor.undo`) now rolls back the way it ran: one
  `MapElementRollbackWorker` job per started element, enqueued `batch_size` per throw with the
  forward run's back pressure, each loading one element's state. Before, one process loaded every
  element and undid them one after another. The run ends with the same `Failure` as an inline map's
  rollback. An element's rollback saves after every undone step, so a worker killed mid-rollback
  resumes after the last one (the undo that was cut off runs again: keep undos idempotent). Both
  sweepers recover lost rollback jobs and resumes. Inline maps keep rolling back in process, now
  reading element states 100 at a time.
* **`rolling_back` execution status.** A run whose rollback handed off at a fan-out map, until the
  last element reports; then a worker undoes the steps before the map and the run ends `failed`
  (`cancelled` for an undo). `Reactor.cancel` and `Reactor.undo` raise
  `RubyReactor::Error::ValidationError` on it. The dashboard shows it (amber) in every status
  surface, with the map's rollback progress (`total`, `settled`, `outstanding`, `failed`).
* **Router methods `perform_map_element_rollback_async` / `perform_map_element_rollback_in`** on both
  shipped routers, with a `MapElementRollbackWorker` per adapter, on the queue `MapElementWorker`
  uses. A custom router needs both methods for fan-out map rollback.
* **`be_rolling_back` matcher.** `pending_async_jobs` / `drain_async_jobs` work on the ActiveJob
  test adapter too, and `worker_class` names a pending job's class on both backends.
* **`Reactor.undo` holds the run's context lock**, and raises `RubyReactor::Lock::AcquisitionError`
  while a live run or rollback holds it.

* **`aborted` execution status.** A run in the caller's process that an interruption
  (`SignalException` including `Interrupt`, `SystemExit`, `NoMemoryError`, or an enclosing
  `Timeout.timeout`) cuts short runs no rollback code: the exception reaches the caller unchanged,
  and the run is stored as `aborted` with only the steps not yet undone still outstanding (an
  interruption during a rollback keeps exactly the rest, whichever failure started that rollback).
  Workers and the sweeper never resume it; `Reactor.undo(id)` rolls it back, including the steps a
  composed child or the elements of an inline `map` completed when the interruption hit inside
  them. The dashboard and web API show and filter it, next to `failed`. A worker run is unchanged
  (its job is redelivered).
* **Step-scoped coordination.** Steps can declare `with_lock`, `with_semaphore`, `with_rate_limit`,
  `with_period`, and `with_ordered_lock` — the same macros as the reactor form, keyed on the step's
  own resolved arguments instead of the reactor's inputs — so one step of a workflow can be
  serialized (or rate-limited, deduped, or strictly ordered) without serializing the whole
  workflow. Works on class steps and inline `step :x do ... end` blocks (or both on one step —
  taken once, in one fixed order); a direct `MyStep.run(args)` call is protected too, as its own
  unit of work that waits then fails. Contention parks the execution in a worker (bounded by
  `lock_snooze_max_attempts`, never consuming the step's own `retries` budget; the parked step
  releases what it took and never spends a rate-limit slot on a park) and waits-then-fails
  synchronously. Re-entrancy, the async dispatch deadlock guard, and rollback
  (`compensate`/`undo` re-take lock/semaphore only) all follow the same rules as reactor-level
  coordination. See
  [Step-Scoped Coordination](documentation/locks_and_semaphores.md#step-scoped-coordination).
* **Step input contracts.** A step class declares its own inputs with `input :name, :type, **predicates`
  (plus `optional:`, `default:`, `redact:`, the `do |i| ... end` macro block and `validate:`) and
  cross-field rules with `validate_inputs`. The contract is enforced before `run` on every path
  (inline, retries, `async_step` and `background` workers, resume, `map`, and a direct
  `Step.run(args, context)` call), and a violation fails with `validation_errors` and the step's
  name after completed steps are rolled back. Subclasses inherit and extend the contract.
  Introspection: `input_contract`, `declared_inputs`, `required_input_names`, `declares_inputs?`.
* **Inline step contracts.** `inputs do ... end` inside a `step` block takes the same `input` /
  `validate_inputs` lines as a step class and is enforced the same way.
* **Wiring by name.** A declared input with no `argument` resolves from the reactor input of the
  same name (never from a step result). A required input that is neither wired nor a reactor input
  raises `Error::ValidationError` before any step runs. `Reactor.validate_definition!` runs that
  check on demand, e.g. from an initializer or CI.
* For a step that owns a contract, a type or predicate on `argument`, `validate_args`, or an
  `argument` for an undeclared input raises `Error::ValidationError` when the `step` line is
  evaluated.
* `have_validation_error` now also matches validation failures raised at a step, not only
  reactor-input failures.
* `Failure#to_h` includes `retryable`, so a non-retryable failure stays non-retryable after it
  crosses a worker boundary.
* A step that returns another unit's validation failure (e.g. an `async_step` reader propagating
  the worker's `Failure`) keeps its `validation_errors` on the reactor's final failure.

* **`rollback_wait:` on step `with_lock` / `with_semaphore`.** How long a step's `undo` /
  `compensate` waits to re-take its key. Defaults to the lock's `ttl` (60 s for a semaphore);
  rollback still never parks, so in a worker the wait blocks the thread.
* **`Failure#rollback_failures`.** Every undo or compensation that did not complete —
  `{ step:, kind: :undo | :compensate, key:, reason: :coordination_unavailable | :returned_failure | :raised, message: }`,
  including composed children's (flattened). Always an Array; part of `Failure#to_h` and the
  stored failure of a background run.
* **`:snooze_step` middleware event** (`on_snooze_step(step_name, error, context)`): a step's
  attempt ended in a park — it lost its own contention in a worker, or it is a `compose` step whose
  child parked — at any nesting depth. Never `:failed_step`. A step whose own arguments wait on a
  background result parks before it starts, so it fires neither `:start_step` nor `:snooze_step`.
  The OpenTelemetry middleware closes the span as `step.status = "parked"`.
* **`have_rollback_failure(step)` matcher**, with `.for_key(key)` and `.because(reason)`.

### Deprecations

* **`fail_fast` on a `map` is now `atomic`** (same meaning: every element succeeds, or none is
  kept). `fail_fast` keeps working and prints one deprecation line per declaration site naming
  `atomic`; it will be removed no earlier than the next major version. Declaring both on one map
  raises `RubyReactor::Error::ValidationError`. Element jobs enqueued before the upgrade, which
  carry `fail_fast`, keep the policy they were enqueued with.
* Rules on `argument` (`argument :x, src, :type, **predicates`) and `validate_args` keep working
  for steps without a contract, and print one deprecation notice per declaration site. Move them
  to `input` / `validate_inputs` on the step class, or into an `inputs do ... end` block for an
  inline step, and keep `argument :x, src` for wiring. Removal is no earlier than the next major
  version. See "Step Input Contracts" in the README for the migration.

### Bug Fixes

* **The recovery sweep no longer re-runs a run still executing in its caller's process.** A
  synchronous `Reactor.run` (or an inline `continue`) now holds the run's liveness lock, renewed
  while it executes, so a sweep during a long step leaves it alone; a killed process is still
  recovered once the lock lapses (`context_lock_ttl`).
* **A caller's final save no longer overwrites a worker's progress.** A synchronous run that hands
  off at a fan-out map (or a `background` step) keeps its lock until its final save, and a Worker
  now takes the run's lock (waiting up to 2s) before it reads the run, so it always resumes from
  the caller's final state.
* **Two resumes of one interrupt at the same instant: exactly one is accepted**, even in inline
  job-testing mode, where both used to run.
* **A resumed run waiting on a reactor lock or semaphore is no longer marked `failed` without
  rolling back.** The snooze limit (`lock_snooze_max_attempts`) now applies only before a run is
  admitted; an admitted run (a deferred or `resume: :background` resume) keeps waiting and logs
  `ruby_reactor.resume.waiting` once.
* **Manual undo finishes a `compensate` an interruption cut off.** A run aborted while its failing
  step's `compensate` ran now records that step; `Reactor.undo(id)` runs the `compensate` again,
  with the same arguments and reason, before undoing the completed steps (also inside composed
  children and inline map elements). The dashboard flags such a run.
* **A fan-out map inside a composed reactor no longer leaves the root running forever.** The map's
  completion resumed the child as a run of its own, and nothing resumed the root. Now the root
  resumes and finishes, and a failure of the map or of any later step rolls back through the root.
  A map that was already running inside a composed child when you upgraded keeps the old
  behavior: its metadata names no owner run.
* A fan-out map's completion now resumes the run through its own Worker, which adopts the map's
  outcome, instead of the collector job resuming the run itself. This costs one extra job per
  fan-out map completion, and removes the collector's write to the run's context.
* A map element re-dispatched by `RubyReactor::Map::Sweeper` kept neither `batch_size` nor
  `fail_fast`: the map metadata never stored them, so the element stopped triggering later
  batches and was no longer atomic. Both are stored now.
* `Executor#resume_execution` saves the context before it releases the run's context lock. Released
  first, a worker resuming the same run could load the pre-save state and have its progress
  overwritten by the late save.
* A map's undo record no longer stores the map's resolved source in the parent context.
* A step that returns another unit's `Failure` (a map adopting a failed element, a composed child)
  keeps that Failure's `exception_class` on the run's final Failure, also when the step's retries
  are exhausted. Before, an inline map whose element raised reported no `exception_class`.

* `Reactor.continue` accepts a resume only while the reactor is paused at an interrupt. A resume
  that arrives while the reactor is executing or rolling back, or after it finished or was
  aborted, raises `RubyReactor::Error::ValidationError` and changes nothing. Before, it resumed the
  run from its stored state, which could run a rolled-back or aborted run forward again. An
  accepted resume marks the run `running` before executing, so a concurrent second resume fails.
  A resume that cannot take the reactor's lock or semaphore raises its `AcquisitionError` and
  leaves the run paused, so the caller can retry it.
* A `background after:` step that returns `Halt` no longer hands the rest of the run to a worker:
  the run halts, as `Halt` promises. Before, the remaining steps ran in a worker.
* A stored `Failure` keeps at most 100 backtrace frames, plus a `"... N more frames"` line. A stack
  overflow's backtrace no longer inflates the stored context (about 2.4 MB to 23 KB).
* Every error after a completed step now rolls back, and the failure names its step. An `argument`
  source, `transform` or result path that raises fails the step with
  `RubyReactor::Error::ArgumentResolutionError`: completed steps are undone, the step is neither
  compensated (its body never started) nor retried, and the Failure carries `step_name`,
  `reactor_name` and the original `exception_class`. Before, an argument error rolled nothing back
  and carried no step. The same holds in a worker (an `async_step` unit, a `background` hand-off).
  Any other exception raised outside a step body ("Execution failed: …") now rolls back completed
  steps too, and a failure whose compensation raised ("Execution error: …") carries `step_name`.
* A supplied `false` reactor input or step result no longer resolves to `nil`.
  `Context#get_input`, `Context#get_result` and `Template::Result#fetch` now check whether the key
  exists instead of whether the value is truthy. Code that relied on `false` arriving as `nil`
  will now see `false`.
* An input-validation `Failure` stays non-retryable across serialization. `Failure`'s
  hash extractor and the reactor's stored `failure_reason` both dropped a `retryable: false`
  (`||` swallowed the `false`, and the reactor never stored the flag at all), so a failure
  rebuilt from JSON or reloaded with `Reactor.find` reported `retryable? == true`.
* A step-contract violation inside `compose` now reaches the parent with its `validation_errors`
  and retryability intact, instead of being rebuilt from the child's error message alone.
* A reactor reopened after its first run is re-checked: `validate_definition!` no longer memoizes,
  so a step declared later can no longer reach execution with a required input unwired.
* A class step that calls `halt!` under `async_step` is recorded as a halt rather than an
  ordinary `nil` success, and `result(:step)` hands the reader the `Halt` — the same way it
  already hands over a `Failure`.
* Step coordination (F1): a step's undo is no longer dropped because another execution holds its
  key at that moment — it waits up to `rollback_wait`, and one that still cannot run is reported
  on `Failure#rollback_failures` instead of only in the trace.
* Step coordination (F2): a park inside a composed child no longer releases the parent's reactor
  lock or semaphore, and no longer charges the parent's rate limit again on redelivery — every
  level keeps its own holds and is admitted once, at any depth.
* Step coordination (F3): a synchronous execution that reaches a strict step-level ordered lock
  out of turn fails without poisoning the chain; later arrivals run instead of being skipped.
* Step coordination (F4): the docs name `context.coordinating_step` (not `current_step`) as the
  attribution for coordination middleware events.
* Step coordination (F5): a parked `async_step` no longer overwrites its parent's saved context;
  its park state (ordered-lock position, "waiting" marker) lives on its own step result record.
* Step coordination (F6): documented the cross-level key-ordering rule that avoids two workflows
  waiting on each other's reactor and step locks.
* Step coordination (F7): a step whose ordered-lock batch expired before its retry is skipped
  (`Skipped(reason: :ordered_lock_stale_batch)`) instead of running unordered.
* Step coordination (F8): a step-level ordered-lock heartbeat stops when the step body exits
  abnormally (e.g. `Sidekiq::Shutdown`), so the poison pill can release the position.
* Step coordination (F9): a step class invoked directly from another step's body names itself in
  contention errors and coordination events, not the calling step.
* An `async_step` no longer writes its parent's context when it finishes (it already stopped
  doing so on a park). Its older snapshot overwrote whatever the parent saved while the unit ran —
  a parent could revert to "running" and lose later steps' results. The unit's run (arguments,
  attempts, start time) now lives on its Step Result Record, and the dashboard rebuilds it from the
  parent's link, at any composition depth. `context.execution_trace` no longer has a `:run` entry
  for an `async_step`, and changes an `async_step` body makes to `context` are not persisted.
* A park after a fan-out map (a later step's contention, or an awaited background result) now
  requeues the parent on its own worker instead of escaping the map collector and leaving the run
  "running" forever; the collector also no longer re-saves the parent after resuming it, which
  could overwrite a newer save by the parent's next worker.
* An `async_step` refused at dispatch because it would deadlock on a key the reactor holds is no
  longer compensated. It was never dispatched or run. The steps before it still roll back.
* A step of a composed child that reads a not-yet-finished background result in a worker (F10)
  parks the execution, keeping the child's lock, instead of failing the parent with
  "async result … still pending".
* A background reactor whose own `with_lock` / `with_semaphore` is busy when it starts no longer
  charges its `with_rate_limit` again on every snoozed redelivery.
* A `compensate` that raises no longer stops the rollback: the completed steps are still undone,
  and the reactor fails with `CompensationError` and a `reason: :raised` rollback failure.
* A composed child whose own `with_lock` / `with_semaphore` / `with_rate_limit` is busy inside a
  worker now parks the execution and snoozes the job instead of failing the parent. After
  `lock_snooze_max_attempts` parks it fails the `compose` step, which rolls the parent back.
* A park that comes up through a `compose` step (the child's contention, or its wait on a
  background result) no longer uses up that step's `retries` budget.
* Docs: `on_snooze_step` is documented for what it covers — a step's own contention park and a
  `compose` step whose child parked, not a step whose own arguments wait on a background result.
* Docs: a park keeps each level's lock without a second `:lock_acquired` only while the gap stays
  within the lock's `ttl`; a lapsed lock is acquired again.

## [0.8.8](https://github.com/arturictus/ruby_reactor/compare/v0.8.7...v0.8.8) (2026-10-10)


### Bug Fixes

* Rollback and Resume Follow-ups ([#72](https://github.com/arturictus/ruby_reactor/issues/72)) ([251fe9f](https://github.com/arturictus/ruby_reactor/commit/251fe9f6a9499738b6abcd6befd3a99e7cebec9f))

## [0.8.7](https://github.com/arturictus/ruby_reactor/compare/v0.8.6...v0.8.7) (2026-10-08)


### Features

* add support for interrupts inside composed children ([#71](https://github.com/arturictus/ruby_reactor/issues/71)) ([7be968e](https://github.com/arturictus/ruby_reactor/commit/7be968eb5dbfc6458e9419d8c6fddbf9d89cc80e))

## [0.8.6](https://github.com/arturictus/ruby_reactor/compare/v0.8.5...v0.8.6) (2026-10-08)


### Miscellaneous Chores

* release commit ([#68](https://github.com/arturictus/ruby_reactor/issues/68)) ([9fcb14c](https://github.com/arturictus/ruby_reactor/commit/9fcb14cb8aa6a2c9e48d3327cb8eb279022f59c0))

## [0.8.5](https://github.com/arturictus/ruby_reactor/compare/v0.8.4...v0.8.5) (2026-09-30)


### Miscellaneous Chores

* Execution flows improvements and consolidation ([#65](https://github.com/arturictus/ruby_reactor/issues/65)) ([21a4c59](https://github.com/arturictus/ruby_reactor/commit/21a4c59fa13c0e7e66c8e08ccb5f20ea43875353))

## [0.8.4](https://github.com/arturictus/ruby_reactor/compare/v0.8.3...v0.8.4) (2026-09-26)


### ⚠ BREAKING CHANGES

* `retry_defaults` on a reactor raises RubyReactor::Error::DeprecatedDslError. Migration: move the values onto each step that should retry (`retries max_attempts: 3, backoff: :exponential, base_delay: 2` inside the step block, or on the step class once supported). A step without `retries` runs once. `max_attempts: 0` is not valid: use `max_attempts: 1` (or omit `retries`) for a step that must never retry.

### Features

* implement step-scoped retry declarations ([#61](https://github.com/arturictus/ruby_reactor/issues/61)) ([75d9c4e](https://github.com/arturictus/ruby_reactor/commit/75d9c4edca1a6ec53183d56c9c6261e792c98cc2))
* Inputs protection ([#63](https://github.com/arturictus/ruby_reactor/issues/63)) ([faf90e8](https://github.com/arturictus/ruby_reactor/commit/faf90e8dbfff87f6492af863b90e8247c84bd673))

## [0.8.3](https://github.com/arturictus/ruby_reactor/compare/v0.8.2...v0.8.3) (2026-09-25)


### Features

* move locks declarations to step classes ([#56](https://github.com/arturictus/ruby_reactor/issues/56)) ([a7862ca](https://github.com/arturictus/ruby_reactor/commit/a7862ca765ae706aebb361d9eadcf4c0ead12caf))

## [0.8.2](https://github.com/arturictus/ruby_reactor/compare/v0.8.1...v0.8.2) (2026-09-22)


### Features

* Enhance mocking capabilities for nested reactors with scoped APIs and examples ([#58](https://github.com/arturictus/ruby_reactor/issues/58)) ([a462265](https://github.com/arturictus/ruby_reactor/commit/a462265b233f94f07fc39628b59a2bb038744fc9))

## [0.8.1](https://github.com/arturictus/ruby_reactor/compare/v0.8.0...v0.8.1) (2026-09-22)


### Miscellaneous Chores

* Update documentation clarifying background and async concepts ([#55](https://github.com/arturictus/ruby_reactor/issues/55)) ([968e32b](https://github.com/arturictus/ruby_reactor/commit/968e32bbc695e45471d04b7630d8cd437ff41624))

## [0.8.0](https://github.com/arturictus/ruby_reactor/compare/v0.7.1...v0.8.0) (2026-09-21)


### ⚠ BREAKING CHANGES

* Step Instance and input validations per step  ([#51](https://github.com/arturictus/ruby_reactor/issues/51))

### Features

* Step Instance and input validations per step  ([#51](https://github.com/arturictus/ruby_reactor/issues/51)) ([4a20583](https://github.com/arturictus/ruby_reactor/commit/4a2058399d73e9b3bf767659dd5ba080537dc291))

## [0.7.1](https://github.com/arturictus/ruby_reactor/compare/v0.7.0...v0.7.1) (2026-09-14)


### Features

* reactor signal semantics ([#52](https://github.com/arturictus/ruby_reactor/issues/52)) ([9147d06](https://github.com/arturictus/ruby_reactor/commit/9147d066da603c0afc1af6536b6afac7e165a034))

## [0.7.0](https://github.com/arturictus/ruby_reactor/compare/v0.6.0...v0.7.0) (2026-09-08)


### ⚠ BREAKING CHANGES

* `async` inside a `step` or `compose` block is removed. It was ambiguous — only the first flagged step in a reactor ever took effect and the rest were silently ignored — so it now raises `Error::DeprecatedDslError` at class-definition time, naming its replacements.

### Features

* Async steps and reactors, background DSL instead of `async` ([#46](https://github.com/arturictus/ruby_reactor/issues/46)) ([9326433](https://github.com/arturictus/ruby_reactor/commit/93264331ad69f648f30d9e365048705cd9b0d82d))

## [0.6.0](https://github.com/arturictus/ruby_reactor/compare/v0.5.4...v0.6.0) (2026-08-16)


### Features

* ActiveJob Support ([#42](https://github.com/arturictus/ruby_reactor/issues/42)) ([0fb6dc4](https://github.com/arturictus/ruby_reactor/commit/0fb6dc4ae4b16c34e0aa33a66f95df3e14ae0807))
## Unreleased

### ⚠ BREAKING CHANGES

* **The per-step `async` flag is removed.** `async true` inside a `step` **or a
  `compose`** block now raises `RubyReactor::Error::DeprecatedDslError` (a
  subclass of `Error::ValidationError`) at reactor **class-definition** time.

  It was ambiguous: only the **first** flagged step in a reactor ever took
  effect, and every later one was silently ignored. A reactor now declares one
  hand-off point instead, nameable from either side:

  ```ruby
  # Before — only the first `async true` did anything
  step :process_payment do
    async true
    # ...
  end

  # After — the exact equivalent
  step :process_payment do
    # ...
  end

  background before: :process_payment
  ```

  **Migration:** for a flagged step `:x`, use `background before: :x`. That
  reproduces the old semantics precisely — `:x` and everything after it move to
  the worker — without having to identify a predecessor step. The same applies to
  `async` inside a `compose` block. `after: :x` is the other side of the same cut
  point (`:x` stays in the calling process); the two coincide in a linear chain
  but pin different steps in a DAG.

  Also affected: the map-internal element dispatch option was renamed from
  `async true` to `fan_out`, so `map :items do async true, batch_size: 2 end`
  now raises and should become `map :items do fan_out batch_size: 2 end`.

  One behavior change falls out of "exactly one hand-off point per reactor":
  resuming a reactor past its hand-off point now finishes in the resuming
  process, where the old per-step flag would queue a second, undeclared hand-off.

* `RubyReactor::Dsl::StepConfig#async?` and the per-step `async:` field in the
  dashboard's `Web::API` step structure are gone. The dashboard now exposes the
  reactor's normalized hand-off point once, as `background_handoff`.

* **Whole-reactor `async true` is removed.** It named the same hand-off idea as
  `background`, with a different word, and read confusingly next to the new
  `async_step` / `async_reactor` step macros (both "async" + "reactor", meaning
  different things). Using it now raises `RubyReactor::Error::DeprecatedDslError`
  at class-definition time.

  ```ruby
  # Before
  class OrderProcessingReactor < RubyReactor::Reactor
    async true
    # ...
  end

  # After — identical behavior, including validating inputs inside the worker
  class OrderProcessingReactor < RubyReactor::Reactor
    background all: true
    # ...
  end
  ```

  **Migration:** replace `async true` with `background all: true`. `async?` (the
  reader) is unchanged and still answers the same question.

* **`RubyReactor::AsyncResult` is renamed to `RubyReactor::DispatchResult`.** The
  old name no longer fit: the class is the sentinel returned whenever a step's
  work is handed to a worker and not yet resolved, produced alike by
  `background`, `async_step`, `async_reactor`, and map's async element dispatch
  — not specific to "async" as a concept.

  **Migration:** replace any `RubyReactor::AsyncResult` reference (e.g. in a
  custom `async_router`, or `result.is_a?(RubyReactor::AsyncResult)` checks)
  with `RubyReactor::DispatchResult`.

### Features

* **`background after:` / `background before:` / `background all:`** — one
  unambiguous, reactor-level cut point between what runs in the calling process
  and what runs in a worker (`all:` — the whole reactor, replacing the old
  whole-reactor `async true`).
* **`async_step`** — dispatch one step's work to its own job while the reactor
  keeps running every other ready step. Dependent steps read the outcome through
  the existing `result(:name)` helper, which gains a bounded notified wait.
* **`async_reactor`** — dispatch a whole nested reactor to run independently,
  linked to the parent by execution id for traceability but excluded from its
  compensation graph. A dispatch-time guard fails loudly instead of deadlocking
  when a child declares a lock key the parent holds.
* **`Configuration#async_wait_timeout`** (default `30` seconds) — bounds how long
  a step blocks reading a dispatched result. Never an unbounded wait.
* The dashboard renders both new step types and drills into an `async_reactor`
  child's own execution.

**Compensation for the two new units is opt-in, by design.** A failing
`async_step` / `async_reactor` does not automatically compensate its parent — it
was dispatched precisely so the parent would not depend on it. A later step that
reads the result and returns `Failure` triggers compensation normally, so no
failure is unrecoverable, just not automatic.

* Reactor signal semantics: `Skipped` is renamed to `Halt` (the existing clean-stop behaviour, unchanged otherwise), and `Skipped` is reused with new meaning — marking a single step skipped while the reactor continues, with its value flowing to dependants exactly like `Success`. One-line outcome helpers `success!`, `fail!`, `skip!`, and `halt!` end a step immediately from any call depth. `Failure` (and `fail!`) accept a `retry:` spelling alongside the existing `retryable:`. `compensate`/`undo` now default to `Skipped` instead of `Success`, so the execution trace distinguishes rollback logic that ran from rollback logic that was never written.

  **Migration**: `Skipped(reason: "...")` (the old halt) is now `Halt(reason: "...")`; `result.skipped?` for a clean halt is now `result.halted?`; the `be_skipped` matcher for a clean halt is now `be_halted`. The old call shape raises `ArgumentError` naming `Halt` — there is no silent compatibility path. Run status `:skipped` is renamed `:halted`; contexts persisted by a pre-upgrade version with status `"skipped"` are still read back correctly as halted.

## [0.5.4](https://github.com/arturictus/ruby_reactor/compare/v0.5.3...v0.5.4) (2026-06-18)


### documentation

* emphasize class-based steps as preferred way  ([#38](https://github.com/arturictus/ruby_reactor/issues/38)) ([0ee6234](https://github.com/arturictus/ruby_reactor/commit/0ee62346fd0c49d97c57cef780a6a7135d4253cd))

## [0.5.3](https://github.com/arturictus/ruby_reactor/compare/v0.5.2...v0.5.3) (2026-06-17)


### Features

* Durability & Recovery ([#39](https://github.com/arturictus/ruby_reactor/issues/39)) ([103e583](https://github.com/arturictus/ruby_reactor/commit/103e5835b413eec2302fa63f3e998d487cfd9eaf))

## [0.5.2](https://github.com/arturictus/ruby_reactor/compare/v0.5.1...v0.5.2) (2026-06-14)


### Features

* Nonce lock ([#26](https://github.com/arturictus/ruby_reactor/issues/26)) ([5925cac](https://github.com/arturictus/ruby_reactor/commit/5925cac7af93f59be6c0a8a98ab020f96080f60b))

## [0.5.1](https://github.com/arturictus/ruby_reactor/compare/v0.5.0...v0.5.1) (2026-06-14)


### Features

* streamline input validation DSL and enhance error handling ([#35](https://github.com/arturictus/ruby_reactor/issues/35)) ([e32f3ec](https://github.com/arturictus/ruby_reactor/commit/e32f3ec91d87cf7a5060558ee705089f1dc76ca6))

## [0.5.0](https://github.com/arturictus/ruby_reactor/compare/v0.4.1...v0.5.0) (2026-06-11)


### Features

* Middlewares & OpenTelemetry ([#32](https://github.com/arturictus/ruby_reactor/issues/32)) ([a9e10ce](https://github.com/arturictus/ruby_reactor/commit/a9e10ceb6fa6381ead57a5905931343f8d1182d1))

## [0.4.1](https://github.com/arturictus/ruby_reactor/compare/v0.4.0...v0.4.1) (2026-05-25)


### Bug Fixes

* trigger release pipeline ([#29](https://github.com/arturictus/ruby_reactor/issues/29)) ([862478b](https://github.com/arturictus/ruby_reactor/commit/862478b3d0811b00e920119057bf4c1bfb1808af))
* trigger release workflows ([#31](https://github.com/arturictus/ruby_reactor/issues/31)) ([ed44dcd](https://github.com/arturictus/ruby_reactor/commit/ed44dcd00e3288e2fab99f9794821943dacc1d4b))

## [0.4.0](https://github.com/arturictus/ruby_reactor/compare/ruby_reactor-v0.3.2...ruby_reactor/v0.4.0) (2026-05-17)


### Features

* `DispatchResult` returning intermediate_results ([#10](https://github.com/arturictus/ruby_reactor/issues/10)) ([0cb96d6](https://github.com/arturictus/ruby_reactor/commit/0cb96d66e88097665998601276e38e1c2249c581))
* enhance deserialization error handling in Sidekiq worker ([#23](https://github.com/arturictus/ruby_reactor/issues/23)) ([60dde95](https://github.com/arturictus/ruby_reactor/commit/60dde95606d52cc6a9d352ad0117b4092a1ebb9d))
* Enhance failure messages with step, reactor, redacted inputs, a… ([#11](https://github.com/arturictus/ruby_reactor/issues/11)) ([952feae](https://github.com/arturictus/ruby_reactor/commit/952feaeb6ebbe5fbe2daf470263d8e769ba64138))
* Introduce reactor interrupt functionality, allowing pausing and… ([#13](https://github.com/arturictus/ruby_reactor/issues/13)) ([53d0861](https://github.com/arturictus/ruby_reactor/commit/53d0861f0238f0e2247e581b0a27cba2f42cfba6))
* Rspec helpers ([#19](https://github.com/arturictus/ruby_reactor/issues/19)) ([cb71f80](https://github.com/arturictus/ruby_reactor/commit/cb71f80c0708dacf6c10c0beac88446b00f30f54))
* Web Dashboard ([#14](https://github.com/arturictus/ruby_reactor/issues/14)) ([80255dd](https://github.com/arturictus/ruby_reactor/commit/80255dd40800af8f6ed804de9c6f151331742fd5))
