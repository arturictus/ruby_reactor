---

description: "Task list for Step-Scoped Retry Declarations"
---

# Tasks: Step-Scoped Retry Declarations

**Input**: Design documents from `specs/006-step-retry-declarations/`

**Prerequisites**: [plan.md](plan.md), [spec.md](spec.md), [research.md](research.md),
[data-model.md](data-model.md), [contracts/dsl-surface.md](contracts/dsl-surface.md),
[quickstart.md](quickstart.md)

**Tests**: REQUIRED. Constitution III requires test-first: write every spec task first and
see it fail before starting the implementation tasks in the same phase. Run specs against
real Redis. Background-path specs must use **constant-named** reactor and step classes (as in
`spec/ruby_reactor/retry_signals_spec.rb`), because a worker rehydrates reactors by class
name.

**Delivery order (spec FR-017)**: Phase 2 (US1, removing `retry_defaults`) is committed as a
standalone `feat!` with the suite green **before any later phase starts**. No later task may
read or mention `retry_defaults`, except the removal stub and its spec.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: can run in parallel (different files, no dependency on an incomplete task)
- **[Story]**: the user story from spec.md (US1–US7)

## Path Conventions

Gem: `lib/ruby_reactor/`, `spec/`. Demo: `demo_app/`. New feature specs:
`spec/ruby_reactor/step_retries/` (one file per story).

---

## Phase 1: Setup

**Purpose**: record a green baseline so the regressions in the later phases can be told apart.

- [X] T001 Confirm Redis is reachable and record the baseline: run `bundle exec rspec spec/async_retry_dsl_spec.rb spec/async_retry_integration_spec.rb spec/ruby_reactor_spec.rb spec/ruby_reactor/retry_signals_spec.rb spec/ruby_reactor/retry_reexecution_spec.rb spec/ruby_reactor/order_processing_reactor_spec.rb` and `bundle exec rubocop` from the repo root. Note any pre-existing failures in the PR description (see the flaky-spec note: rerun a failing file alone before treating it as real).
- [X] T002 Create the directory `spec/ruby_reactor/step_retries/` for the new feature specs.

---

## Phase 2: User Story 1 — Remove reactor-wide retry defaults first (Priority: P1) 🎯 MVP, ships first

**Goal**: `retry_defaults` no longer exists. Calling it fails at class definition. A step
with no `retries` runs once. Nothing reads a reactor-level default.

**Independent Test**: `Class.new(RubyReactor::Reactor) { retry_defaults max_attempts: 3 }`
raises `DeprecatedDslError`. A reactor whose failing step declares nothing runs it once.
`grep -rn retry_defaults lib spec demo_app documentation README.md llms*.txt` matches only
the stub and its spec.

### Tests for User Story 1 (write first, confirm failing)

- [X] T003 [US1] In `spec/async_retry_dsl_spec.rb`, replace the example `"supports retry_defaults class method"` (lines 23-33) with `"rejects the removed reactor-level retry_defaults"`. It should expect `Class.new(RubyReactor::Reactor) { retry_defaults max_attempts: 5, backoff: :linear, base_delay: 2 }` to raise `RubyReactor::Error::DeprecatedDslError` with a message matching `/retry_defaults.*removed/m` and `/retries/`. Add a second example: calling `retry_defaults` with no arguments on a reactor class raises the same error.
- [X] T004 [P] [US1] Create `spec/ruby_reactor/step_retries/removal_spec.rb` with these cases:
  - (a) an anonymous reactor whose step `run` always returns `Failure("boom")`, with no `retries` anywhere, returns a failure after exactly 1 attempt (`reactor.context.retry_context.attempts_for_step(:x) == 1`, error not prefixed "failed after");
  - (b) the same for a `compose` step whose block declares no `retries`: `steps[:c].retry_config[:max_attempts] == 1`;
  - (c) the same for `async_reactor`: `steps[:a].retry_config[:max_attempts] == 1`;
  - (d) the `DeprecatedDslError` message names the reactor when the class is constant-named (define `RemovalSpecNamedReactor` via `stub_const` + `Class.new`, then call `retry_defaults` inside `class_eval`).

### Implementation for User Story 1

- [X] T005 [US1] In `lib/ruby_reactor/dsl/reactor.rb`:
  - delete line 14 (`base.instance_variable_set(:@retry_defaults, …)`);
  - replace `def retry_defaults(**kwargs) … end` (lines 58-68) with `def retry_defaults(*, **)`, which raises `RubyReactor::Error::DeprecatedDslError`. Model the message on the `async` removal stub at lines 48-56 and follow the shape in `contracts/dsl-surface.md` §1: "`retry_defaults` has been removed from #{name || "this reactor"}: reactor-wide defaults silently applied only to steps declared after them. Declare `retries` on each step class (or step block) that should retry; a step with no `retries` runs once."
- [X] T006 [US1] In `lib/ruby_reactor/dsl/step_builder.rb`:
  - initialize `@retry_config = nil` (line 33, currently `{}`);
  - in `build` (line 163), pass `retry_config: @retry_config`;
  - in `StepConfig`, add `NO_RETRIES = { max_attempts: 1, backoff: :exponential, base_delay: 1 }.freeze` and change line 271 to `@retry_config = config[:retry_config] || NO_RETRIES`.

  Keep `StepBuilder#retries` for now (it is replaced in Phase 3).
- [X] T007 [P] [US1] In `lib/ruby_reactor/dsl/compose_builder.rb`, initialize `@retry_config = nil` (line 23) and pass `retry_config: @retry_config` in `build` (line 74).
- [X] T008 [P] [US1] In `lib/ruby_reactor/dsl/async_reactor_builder.rb`, initialize `@retry_config = nil` (line 20) and pass `retry_config: @retry_config` in `build` (line 52).
- [X] T009 [P] [US1] In `lib/ruby_reactor/executor/retry_manager.rb` (lines 27-35), make `calculate_backoff_delay` read only `step_config.retry_config[:backoff]` and `[:base_delay]`. Drop the now-unused `reactor_class` parameter from `calculate_backoff_delay` and from its callers `requeue_job_for_step_retry` and `handle_sync_retry` (keep `reactor_class` wherever it is still used, e.g. for `async?` and `MaxRetriesExhaustedFailure`).
- [X] T010 [P] [US1] In `lib/ruby_reactor/rspec/test_subject.rb`, delete the three `@retry_defaults = superclass.instance_variable_get(:@retry_defaults)` lines (559, 651, 739).
- [X] T011 [US1] Run `grep -rn "retry_config" lib` and check that no consumer calls `.empty?` on a builder's `@retry_config` or assumes it is a Hash before `StepConfig` normalizes it. Fix any hit in place.
- [X] T012 [P] [US1] Migrate `spec/ruby_reactor_spec.rb`:
  - remove `retry_defaults max_attempts: 3` (line 14) and add `retries max_attempts: 3` inside the `validate_email`, `hash_password` and `create_user` step blocks;
  - remove `retry_defaults max_attempts: 3` (line 221) and add `retries max_attempts: 3` inside `step :flaky_step`.

  Do not change any assertion.
- [X] T013 [P] [US1] Migrate `spec/support/order_processing_reactor.rb`: remove `retry_defaults max_attempts: 5, backoff: :fixed, base_delay: 2` (line 28) and add `retries max_attempts: 5, backoff: :fixed, base_delay: 2` to each step without its own `retries` (`validate_order`, `check_inventory`, `reserve_inventory`, `process_payment`). Do not change `spec/ruby_reactor/order_processing_reactor_spec.rb`.
- [X] T014 [P] [US1] Apply the identical migration to `demo_app/spec/support/order_processing_reactor.rb` (the file is byte-identical to the gem copy today; keep it that way).
- [X] T015 [US1] Run `bundle exec rspec` (full suite) and `bundle exec rubocop`; everything is green, including T003/T004.

### Documentation for User Story 1 (REQUIRED, Constitution Development Workflow)

- [X] T016 [P] [US1] In `documentation/retry_configuration.md`:
  - delete "### Reactor-Level Defaults" (lines 48-70);
  - rewrite the "Complex Retry Scenarios" example (≈ line 176) so each step declares its own `retries`;
  - change the intro sentence "configured at both reactor and step levels" to step level only;
  - add a section "## Migrating from `retry_defaults`" with a before/after example (move the values onto each step that needs them; a step without `retries` runs once; `max_attempts: 0` is not valid, use `1`).
- [X] T017 [P] [US1] In `documentation/core_concepts.md`:
  - line 327: drop "either reactor-level defaults or";
  - line 345: "Retries are configured per step";
  - ≈ line 360: replace the "Uses reactor defaults" step with an explicit `retries` line or no retries, and adjust the surrounding example so it no longer declares `retry_defaults`.
- [X] T018 [P] [US1] In `documentation/background_and_async.md`, delete "### Reactor-Level Defaults" (≈ lines 514-530) and adjust any cross-reference to it.
- [X] T019 [P] [US1] In `documentation/examples/order_processing.md` (line 95), `documentation/examples/payment_processing.md` (lines 77, 228, 300) and `documentation/examples/inventory_management.md` (lines 51, 461), replace each `retry_defaults …` with `retries …` on the step(s) in that example that do external I/O. Keep the same values.
- [X] T020 [P] [US1] Apply the same changes to the stale copies under `demo_app/documentation/`: `retry_configuration.md` (48-70, 173), `core_concepts.md` (220, 238, 253), `async_reactors.md` (394-404), and `examples/{payment_processing (47, 230, 302, 389), order_processing (47), inventory_management (49, 460)}.md`.
- [X] T021 [P] [US1] In `README.md` line 1486, change "how to configure retries at the reactor or step level" to "how to configure retries per step". Run `grep -n "retry_defaults" llms.txt llms-full.txt` and fix any hit.
- [X] T022 [US1] Gate: `grep -rn "retry_defaults" lib spec demo_app documentation README.md llms.txt llms-full.txt` matches only `lib/ruby_reactor/dsl/reactor.rb`, `spec/async_retry_dsl_spec.rb` and `spec/ruby_reactor/step_retries/removal_spec.rb`. `bundle exec rspec` and `bundle exec rubocop` are green. Commit as `feat!: remove reactor-wide retry_defaults`, with a `BREAKING CHANGE:` footer carrying the migration text from T016 (including the `max_attempts: 0` → `1` note, which applies from Phase 3).

**Checkpoint**: US1 is shippable on its own. Do not start Phase 3 until T022 is committed.

---

## Phase 3: Foundational — shared `retries` vocabulary (blocks US2–US7)

**Purpose**: one `Dsl::Retryable` module gives step classes and every builder the same
`retries` keyword arguments, defaults and validation (research R3, R4; FR-001, FR-002,
FR-004).

**⚠️ CRITICAL**: no US2–US7 work until this phase is green.

- [ ] T023 [P] Create `spec/ruby_reactor/step_retries/declaration_spec.rb` (validation, FR-004). For both a step class (`Class.new(RubyReactor::Step) { retries … }`) and an inline step block (`Class.new(RubyReactor::Reactor) { step(:s) { retries …; run { Success() } } }`):
  - `retries` with no args stores `{max_attempts: 3, backoff: :exponential, base_delay: 1}`;
  - `retries max_attempts: 5` keeps the other defaults;
  - `ArgumentError` for `max_attempts: 0`, `-1`, `2.5` and `"3"` (message names the owner and `max_attempts`), for `backoff: :bogus` (names `backoff`) and for `base_delay: -1` (names `base_delay`);
  - `base_delay: 0` and `base_delay: 0.5` are accepted.

  Also assert that `compose` and `async_reactor` blocks raise the same `ArgumentError` for `backoff: :bogus`.
- [ ] T024 Create `lib/ruby_reactor/dsl/retryable.rb` defining `RubyReactor::Dsl::Retryable` with:
  - `BACKOFF_STRATEGIES = %i[exponential linear fixed].freeze`;
  - `attr_reader :retry_config`;
  - `retries(max_attempts: 3, backoff: :exponential, base_delay: 1)`, which validates as in `data-model.md` (Integer >= 1; strategy in the list; Numeric >= 0) and raises `ArgumentError, "#{retry_owner_label}: retries #{option} must be … (got #{value.inspect})"`, then sets `@retry_config = { max_attempts:, backoff:, base_delay: }`;
  - `inherited(subclass)`: `super`, then copy `@retry_config` to the subclass when set (mirror `Dsl::Lockable::ClassMethods#inherited`, `lib/ruby_reactor/dsl/lockable.rb:33-40`);
  - a private `retry_owner_label` returning `name&.to_s || inspect`.

  Add `require_relative "ruby_reactor/dsl/retryable"` in `lib/ruby_reactor.rb` right after the `dsl/lockable` require (line 9).
- [ ] T025 In `lib/ruby_reactor/step.rb`, add `extend RubyReactor::Dsl::Retryable` next to `extend RubyReactor::Dsl::Lockable::ClassMethods` (line 36), and update the class header comment ("The one `extend` is …") to mention both modules.
- [ ] T026 In `lib/ruby_reactor/dsl/step_builder.rb`, `include RubyReactor::Dsl::Retryable`, delete `StepBuilder#retries` (lines 133-139), and remove `:retry_config` from the `attr_accessor` list (line 16). The module's reader replaces it.
- [ ] T027 [P] In `lib/ruby_reactor/dsl/compose_builder.rb`, `include RubyReactor::Dsl::Retryable` and delete `ComposeBuilder#retries` (lines 47-53).
- [ ] T028 [P] In `lib/ruby_reactor/dsl/async_reactor_builder.rb`, `include RubyReactor::Dsl::Retryable` and delete `AsyncReactorBuilder#retries` (lines 28-30).
- [ ] T029 Run T023 plus `bundle exec rspec spec/async_retry_dsl_spec.rb spec/ruby_reactor/retry_signals_spec.rb spec/compose_spec.rb spec/ruby_reactor/dsl/` and `bundle exec rubocop lib/ruby_reactor/dsl/retryable.rb`. All green.

**Checkpoint**: the `retries` vocabulary is shared. Step classes can declare it, but reactors
don't read it yet.

---

## Phase 4: User Story 2 — A step class declares its own retry policy (Priority: P1)

**Goal**: a reactor using a step class with no retry wiring gets the class's policy (FR-001,
FR-008 fallback, FR-011, FR-012). A direct call runs once (FR-013).

**Independent Test**: a class step declaring `retries max_attempts: 3, base_delay: 0`, whose
body fails twice, succeeds on attempt 3 in a reactor that has no `retries` line. When the body
always fails, the reactor fails after 3 attempts and compensates the earlier steps.

### Tests for User Story 2 (write first, confirm failing)

- [ ] T030 [P] [US2] Create `spec/ruby_reactor/step_retries/class_policy_spec.rb` with:
  - (a) fail twice then succeed → success, `attempts_for_step == 3`;
  - (b) always fail → `RubyReactor::MaxRetriesExhaustedFailure` with message `"Step 'charge' failed after 3 attempts: …"`, and an earlier step's `compensate`/`undo` ran;
  - (c) `retries max_attempts: 3, backoff: :linear, base_delay: 0.01` → the sleeps between attempts follow linear backoff: `allow_any_instance_of(RubyReactor::Executor::RetryManager).to receive(:sleep)`, then expect it to have received `sleep(0.01)` and then `sleep(0.02)`;
  - (d) `retries max_attempts: 3` only → `steps[:charge].retry_config == {max_attempts: 3, backoff: :exponential, base_delay: 1}`;
  - (e) a body doing `fail!(StandardError.new("x"), retry: false)` makes 1 attempt;
  - (f) a step class with `input :amount, :integer` given `amount: "x"` makes 1 attempt (contract failure is non-retryable);
  - (g) the step skipped by `where { false }` makes 0 attempts.
- [ ] T031 [P] [US2] In `spec/ruby_reactor/step_retries/class_policy_spec.rb`, add a `describe "direct invocation"` example (FR-013): a step class with `retries max_attempts: 3` whose `run` counts calls and returns `Failure("x")`; `klass.run({})` returns a `Failure`, and the counter is 1. Repeat with the step called from another class step's `run` body inside a reactor: the inner direct call runs once per outer attempt.

### Implementation for User Story 2

- [ ] T032 [US2] In `StepConfig` (`lib/ruby_reactor/dsl/step_builder.rb`), store the raw declaration (`@retry_config = config[:retry_config]`, no default). Remove `:retry_config` from `StepConfig`'s `attr_reader` and add, next to `lock_config` (≈ line 286): `def retry_config = @retry_config || (impl.retry_config if impl.respond_to?(:retry_config)) || NO_RETRIES`. Confirm that `retryable?` (≈ line 376) still reads through it.
- [ ] T033 [US2] Check (no change expected, research R7) that `lib/ruby_reactor/executor/step_coordination.rb` `retry_pending?` (lines 533-540) is guarded by `context_state?` before touching `step_config.retry_config`. When `step_config` is a `Step` class, `retry_config` may be `nil` and must never be indexed. If there is any unguarded path, guard it with `&.` there.
- [ ] T034 [US2] Run T030/T031 and `bundle exec rspec spec/ruby_reactor/step_spec.rb spec/ruby_reactor/step_inheritance_spec.rb spec/ruby_reactor/step_contract_retryable_spec.rb`. All green.

**Checkpoint**: the core feature works on the in-process path.

---

## Phase 5: User Story 3 — Existing step-level declarations keep working (Priority: P1)

**Goal**: inline and step-block `retries` behave exactly as before, and the same line works
in a class body (FR-002, FR-003).

**Independent Test**: the existing retry specs pass unchanged, and an inline step and a class
step with the same declaration give identical outcomes.

- [ ] T035 [P] [US3] Create `spec/ruby_reactor/step_retries/step_block_parity_spec.rb` with:
  - (a) an inline step with `retries max_attempts: 3, backoff: :fixed, base_delay: 0` and a `run` block, failing twice → success on attempt 3;
  - (b) a class step with **no** `retries` plus `step :s, Klass do retries max_attempts: 3, base_delay: 0 end` → retried 3 times, and `steps[:s].retry_config[:max_attempts] == 3`;
  - (c) a parity table: the same failure sequence (fail, fail, succeed) and (always fail) run through an inline step and through a class step declaring the identical `retries` line → equal attempt counts, equal final result class, equal error message.
- [ ] T036 [US3] Run the existing retry specs unchanged: `spec/async_retry_dsl_spec.rb`, `spec/async_retry_integration_spec.rb`, `spec/ruby_reactor/retry_signals_spec.rb`, `spec/ruby_reactor/retry_reexecution_spec.rb`, `spec/ruby_reactor/order_processing_reactor_spec.rb`, `spec/compose_spec.rb`. All green, with no edits to them in this phase.

---

## Phase 6: User Story 4 — One declaration per step (Priority: P1)

**Goal**: `retries` on both the class and the step block is refused at reactor definition
(FR-009).

**Independent Test**: adding `retries` to a reactor step block for a class that declares
`retries` raises `Error::ValidationError` naming the reactor, the step and the class.

- [ ] T037 [P] [US4] Create `spec/ruby_reactor/step_retries/conflict_spec.rb` with:
  - (a) a class with `retries max_attempts: 3` plus `step :charge, Klass do retries max_attempts: 5 end` → `RubyReactor::Error::ValidationError` matching `/step :charge declares `retries` inline, but .* declares it too/` and `/subclass/`;
  - (b) the same with the class's policy **inherited** from a parent → still refused;
  - (c) a class without `retries` plus a block `retries` → no error;
  - (d) a class with `retries max_attempts: 1` in a reactor → not retried (`attempts == 1`).
- [ ] T038 [US4] In `lib/ruby_reactor/dsl/step_builder.rb`, add a private `check_retry_conflict!` next to `check_coordination_conflicts!` (≈ line 180) and call it from `build`. It returns unless `@retry_config && @impl.respond_to?(:retry_config) && @impl.retry_config`, then raises `Error::ValidationError`: "#{reactor_label} step :#{@name} declares `retries` inline, but #{@impl} declares it too. Keep ONE: drop the inline declaration to use #{@impl}'s, or remove it from #{@impl}. To vary the policy per workflow, subclass #{@impl} and declare `retries` there."
- [ ] T039 [US4] Run T037 and `spec/ruby_reactor/step_coordination/declaration_spec.rb` (to check the neighboring lock conflict check is untouched). Green.

---

## Phase 7: User Story 5 — The policy follows the step on every execution path (Priority: P2)

**Goal**: a class policy applies in background hand-off, mid-workflow hand-off,
`async_step`, and resume, and attempts carry across requeues (FR-011, FR-012).

**Independent Test**: the same always-failing class step makes exactly the declared number of
attempts synchronously and under `background all: true`.

- [ ] T040 [P] [US5] Create `spec/ruby_reactor/step_retries/execution_paths_spec.rb` with constant-named classes defined at the top of the file (`StepRetriesPathsChargeStep < RubyReactor::Step` with `retries max_attempts: 3, backoff: :fixed, base_delay: 0` and a class-level attempt counter, plus reactors below). Cases:
  - (a) a reactor with `background all: true`, run and drained (follow the pattern in `spec/ruby_reactor/retry_signals_spec.rb` / `spec/async_retry_integration_spec.rb`), always failing → final context failed, 3 attempts, earlier step compensated;
  - (b) fail twice then succeed under `background all: true` → success, and `retry_context.attempts_for_step` stayed consistent across requeues;
  - (c) a reactor with `background after: :first_step` → same count as (a);
  - (d) `async_step :charge, StepRetriesPathsChargeStep` → `StepWorker` retries 3 times (`lib/ruby_reactor/step_worker.rb:344-349` reads `step_config.retry_config`);
  - (e) a reactor with an `interrupt` before `:charge`, resumed, then failing → 3 attempts after the resume.
- [ ] T041 [US5] Run T040. No runtime change is expected (research R5). If (d) fails, fix `lib/ruby_reactor/step_worker.rb` so it reads only `step_config.retry_config` (never `@retry_config` or `impl` directly). If (a)–(c) fail, fix the same kind of issue in `lib/ruby_reactor/executor/retry_manager.rb`.

---

## Phase 8: User Story 6 — Step subclasses inherit the policy (Priority: P2)

**Goal**: subclasses inherit and can override, and the parent is unaffected (FR-010).

**Independent Test**: a base class with `retries max_attempts: 4`, one subclass that inherits
it and one that overrides with 2 → 4/4/2 attempts respectively.

- [ ] T042 [P] [US6] Create `spec/ruby_reactor/step_retries/inheritance_spec.rb` with:
  - (a) a subclass without `retries` → `retry_config` equals the parent's, and in a reactor it makes 4 attempts;
  - (b) a subclass with `retries max_attempts: 2` → 2 attempts; the parent and a sibling still show 4;
  - (c) a subclass-per-workflow: `ReactorA` uses the base class and `ReactorB` uses a subclass with its own policy; both load without a conflict error and retry as declared;
  - (d) a subclass also inherits the parent's `with_lock` and `input` contract alongside `retries` (regression guard that `Retryable#inherited` calls `super`).
- [ ] T043 [US6] Run T042. If (d) fails, fix the `super` chain in `lib/ruby_reactor/dsl/retryable.rb` `inherited`.

---

## Phase 9: User Story 7 — Tests and operators can see the policy (Priority: P2)

**Goal**: the effective policy and its source can be looked up, and the shipped test surface
exercises class policies (FR-014, FR-015, FR-016).

**Independent Test**: `steps[:charge].retry_source == :step_class`, and `failing_at(:charge)`
on a class step is retried under the class policy (`have_retried_step(:charge).times(2)`).

- [ ] T044 [P] [US7] Create `spec/ruby_reactor/step_retries/introspection_spec.rb` with:
  - (a) `retry_source` is `:step_class`, `:step_block` or `:none` for the three kinds of steps;
  - (b) `retry_config` for each matches the declaration or `NO_RETRIES`;
  - (c) with a middleware registered (see `spec/ruby_reactor/middleware_spec.rb` for the pattern), a failing class step with `retries max_attempts: 3, base_delay: 0` emits `:retry_attempt` twice, with the step name and attempt numbers 1 and 2.
- [ ] T045 [P] [US7] Create `spec/ruby_reactor/step_retries/test_surface_spec.rb` (`type: :reactor`, using only `test_reactor`, `failing_at`, `mock_step`, `have_retried_step`, `be_failure`, `be_success`):
  - (a) `test_reactor(R, inputs).failing_at(:charge)` where `:charge` is a class step with `retries max_attempts: 3, base_delay: 0` → `be_failure` and `have_retried_step(:charge).times(2)`;
  - (b) `mock_step(:charge) { |_a, ctx| ctx.retry_context.attempts_for_step(:charge) < 2 ? RubyReactor.Failure("x") : RubyReactor.Success(1) }` → `be_success` and `have_retried_step(:charge).times(1)`.
- [ ] T046 [US7] In `StepConfig` (`lib/ruby_reactor/dsl/step_builder.rb`), add `retry_source`: `:step_block` if `@retry_config`, else `:step_class` if `impl.respond_to?(:retry_config) && impl.retry_config`, else `:none`. Run T044/T045. Green.

---

## Phase 10: Demo (Constitution VI)

**Purpose**: a runnable proof through the public DSL (FR-018).

- [ ] T047 [P] Create `demo_app/app/reactors/step_retry_demo_reactor.rb` defining, in one file:
  - `StepRetryDemoLog` (a class-level attempt log with `reset!`);
  - `FlakyChargeStep < RubyReactor::Step` with `input :fail_times, :integer` and `retries max_attempts: 3, backoff: :fixed, base_delay: 0.05`, which fails until the attempt counter reaches `fail_times` (log each attempt);
  - `ReserveStockStep < RubyReactor::Step` with a `compensate` that records `StepRetryDemoLog.compensated = true`;
  - `NotifyStep < RubyReactor::Step` with no `retries`, which fails when `fail_notify` is true.

  `StepRetryDemoReactor < RubyReactor::Reactor` has inputs `fail_times` and `fail_notify` and steps `reserve_stock` → `charge` → `notify`, with no `retries` lines anywhere in the reactor. Model the file layout on `demo_app/app/reactors/step_lock_demo_reactor.rb`.
- [ ] T048 Add `desc "StepRetryDemoReactor — retries declared on the STEP class; succeed-after-retry, exhaust-and-compensate, undeclared step runs once"` and `task step_retry: [:environment, :flush_redis]` to `demo_app/lib/tasks/demo_reactors.rake`. Touch `StepRetryDemoReactor` first (Zeitwerk note as in the `step_lock` task, ≈ line 685). It prints three scenarios:
  1. `fail_times: 2` → `attempts=3 success?=true`;
  2. `fail_times: 5` → `success?=false attempts=3 compensated=true`;
  3. `fail_times: 0, fail_notify: true` → `notify attempts=1 success?=false`.
- [ ] T049 [P] Create `demo_app/spec/reactors/step_retry_demo_reactor_spec.rb` (`type: :reactor`, `require "rails_helper"`) using only the shipped surface. It covers the three scenarios with `be_success`/`be_failure`, `have_retried_step(:charge).times(2)`, and `expect(reactor).not_to have_retried_step(:notify)`. The compensation assertion reads `StepRetryDemoLog.compensated` (application state, not reactor internals).
- [ ] T050 Run the demo end to end in an isolated compose project: `docker compose -p rr-retry run --rm demo-app bin/rails demo:step_retry` and `docker compose -p rr-retry run --rm demo-app bundle exec rspec spec/reactors/step_retry_demo_reactor_spec.rb`. Confirm the printed outcomes match T048.

---

## Phase 11: Polish & Cross-Cutting Concerns

- [ ] T051 [P] In `documentation/retry_configuration.md`, add "### Declaring retries on a step class (preferred)" as the first example under "Basic Retry Configuration", with `ChargeCard` using `with_lock`, `input` and `retries` together (as in `contracts/dsl-surface.md` §2). Keep the inline example after it. Add:
  - "### Where a step's policy comes from": the step block, then the step class, then none (runs once);
  - "### One declaration per step": the conflict error and the subclassing recipe;
  - "### Direct calls run once": `ChargeCard.run(args)` never retries, because only a reactor coordinates retries; contrast this with locks, which a direct call does take;
  - validation rules for `max_attempts`, `backoff` and `base_delay`.
- [ ] T052 [P] In `documentation/core_concepts.md` line 108 (the class-step lifecycle paragraph that says direct calls are coordinated like reactor calls), append: "Retries are not: a direct call runs once — only a reactor retries a step (see [Retry Configuration](retry_configuration.md#direct-calls-run-once))." In the retry section (≈ 345), lead with the step-class form.
- [ ] T053 [P] In `README.md`:
  - Features bullet (line 24): "**Retries**: per-step retry policies (declared on the step class or step block) with exponential, linear, or fixed backoff.";
  - in "Defining Steps" (≈ line 245, the class-step example), add a `retries max_attempts: 3` line to the example step class with a one-line comment;
  - Retry Configuration blurb (line 1486): mention the step-class form.
- [ ] T054 [P] Mirror T051–T052 into `demo_app/documentation/retry_configuration.md` and `demo_app/documentation/core_concepts.md`.
- [ ] T055 [P] Update `llms.txt` / `llms-full.txt` if they describe the retry DSL (`grep -n "retries" llms*.txt`), so they show the step-class form.
- [ ] T056 Final gate: `bundle exec rspec`, `bundle exec rubocop`, and T050 are all green. Walk through `quickstart.md` Phase B. Commit as `feat: declare retries on step classes`.

---

## Dependencies & Execution Order

### Phase Dependencies

- **Phase 1 (Setup)**: none.
- **Phase 2 (US1, removal)**: after Setup. **Must be committed (T022) before anything else
  starts** (spec FR-017).
- **Phase 3 (Foundational)**: after T022. Blocks US2–US7.
- **Phase 4 (US2)**: after Phase 3. T032 is the change the class policy needs to take effect.
- **Phases 5–9 (US3–US7)**: after Phase 4 (they all run class steps through a reactor, so they
  need T032). They are independent of each other after that.
- **Phase 10 (Demo)**: after Phase 4. Its spec uses matchers exercised in US7 but needs no US7
  code.
- **Phase 11 (Polish)**: after the stories it documents. T056 goes last.

### User Story Dependencies

```text
US1 (removal) ──commit──▶ Foundational ──▶ US2 ──┬──▶ US3
                                                 ├──▶ US4
                                                 ├──▶ US5
                                                 ├──▶ US6
                                                 ├──▶ US7
                                                 └──▶ Demo ──▶ Polish
```

### Within Each Phase

- Spec tasks are written first and must fail before the implementation tasks of that phase.
- `lib/ruby_reactor/dsl/step_builder.rb` is touched by T006, T026, T032, T038 and T046, in that
  order, so those tasks are never [P] with each other.

### Parallel Opportunities

- **US1**: T004 ∥ T003 (different files); T007 ∥ T008 ∥ T009 ∥ T010 after T006; T012 ∥ T013
  ∥ T014; T016–T021 all in parallel.
- **Foundational**: T023 ∥ T024; T027 ∥ T028 after T024.
- **After US2**: the spec files T035, T037, T040, T042, T044 and T045 are all separate files
  and can be written in parallel. The demo files T047 and T049 can run in parallel with
  those.
- **Polish**: T051–T055 are separate files.

---

## Parallel Example: after Phase 4

```bash
Task: "T035 step_block_parity_spec.rb (US3)"
Task: "T037 conflict_spec.rb (US4)"
Task: "T040 execution_paths_spec.rb (US5)"
Task: "T042 inheritance_spec.rb (US6)"
Task: "T044 introspection_spec.rb + T045 test_surface_spec.rb (US7)"
Task: "T047 step_retry_demo_reactor.rb + T049 its spec (Demo)"
```

---

## Implementation Strategy

### MVP = US1 (removal), shipped alone

1. Phase 1 → Phase 2.
2. **STOP**: T022 gate, `feat!` commit. This is releasable on its own and already makes
   retries predictable (a step's policy is always on the step).

### Then the core feature

3. Phase 3 → Phase 4 (US2): step classes carry their policy. Validate independently with
   T030/T031.
4. US4 (conflict) next: it is the correctness guard.
5. Then US3, US5, US6, US7 in any order or in parallel.
6. Demo → Polish → T056 `feat:` commit.

---

## Notes

- Keep `lib/ruby_reactor/rspec/test_subject.rb` free of retry special cases. Mocks keep
  `impl`, so the class policy follows automatically (research R8).
- Do not add a policy object or a reactor-level fallback of any kind (research R3, spec
  FR-006).
- Spec quirk: specs sharing test Redis under load can flake (the async parked-wait spec and
  the 1s Redis ping). Rerun a failing file alone before debugging.
