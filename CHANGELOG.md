# Changelog

## Unreleased

### ⚠ BREAKING CHANGES

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

### Features

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

* Rules on `argument` (`argument :x, src, :type, **predicates`) and `validate_args` keep working
  for steps without a contract, and print one deprecation notice per declaration site. Move them
  to `input` / `validate_inputs` on the step class, or into an `inputs do ... end` block for an
  inline step, and keep `argument :x, src` for wiring. Removal is no earlier than the next major
  version. See "Step Input Contracts" in the README for the migration.

### Bug Fixes

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
