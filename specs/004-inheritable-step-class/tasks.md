# Tasks: Inheritable Step Class

**Input**: Design documents from `/specs/004-inheritable-step-class/`

**Prerequisites**: plan.md, spec.md, research.md (D1–D10), data-model.md, contracts/step-lifecycle.md, quickstart.md

**Tests**: REQUIRED. Constitution Principle III mandates Red-Green-Refactor with RSpec against real Redis. Every test task below is written first and confirmed failing before its implementation task.

**Organization**: Grouped by user story. This is a refactor of one subsystem, so the Foundational phase is larger than usual: `require "ruby_reactor"` cannot even load until `step.rb`, the four namespace reopenings, and the three built-in steps change together (research.md D9). Everything after that is migration and proof, story by story.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (US1–US5 from spec.md)
- Every task names its exact file path(s)

## Path Conventions

Single Ruby gem: `lib/ruby_reactor/`, `spec/`, plus the `demo_app/` Rails example (own Gemfile; run its specs from inside `demo_app/` or via `docker compose run --rm demo-app`). Migration grep pattern throughout: `grep -rnE "include RubyReactor::Step\b"` (the `\b` excludes the legitimate `StepSignals` include).

---

## Phase 1: Setup (Baseline)

**Purpose**: Capture the pre-refactor green state so SC-003 ("identical outcomes") is provable, not asserted.

- [X] T001 Run `bundle exec rspec` and `bundle exec rubocop` on the untouched branch; record pass counts and any pre-existing failures in `specs/004-inheritable-step-class/baseline.md` (this file is the comparison target for T047 and is deleted before merge)
- [X] T002 [P] Run the demo acceptance suite via `docker compose run --rm demo-app bin/rails demo:all` and `docker compose run --rm demo-app bundle exec rspec spec/reactors`; append printed outcomes and spec counts to `specs/004-inheritable-step-class/baseline.md`

---

## Phase 2: Foundational (Base Class + Namespace Flip + Built-ins)

**Purpose**: The one atomic change the library needs to boot again. After this phase `require "ruby_reactor"` loads, the three built-in steps work, and the new base class has its own green spec. Every user-authored step in `spec/` and `demo_app/` is still on the old form and will fail to load until its story phase — that is expected; run only the files named in each task until Phase 3 lands.

**⚠️ CRITICAL**: T004–T009 must land in one commit. A `module Step` reopening loaded after `class Step` raises `TypeError` (D9), and `include RubyReactor::Step` on a class raises `TypeError: wrong argument type Class` once `Step` is a class.

- [X] T003 Write the red lifecycle spec `spec/ruby_reactor/step_spec.rb` per data-model.md and contracts/step-lifecycle.md: (a) a subclass with `input :n, :integer` and instance `run` reading `inputs[:n]` and `context` returns the body's `Success`; (b) `.call` is an alias of `.run`; (c) violating inputs raise `Error::InputValidationError` with `step_name` set and the body never runs; (d) a subclass declaring no inputs receives arbitrary arguments unchanged; (e) `fail!`/`success!`/`skip!`/`halt!` inside `run`, `undo`, and `compensate` each return the matching wrapper from the class-level call, never `UncaughtThrowError`; (f) omitted `undo`/`compensate` return `Skipped`; (g) omitted `run` raises `NotImplementedError` naming the subclass; (h) fresh instance per action: an ivar set inside `run` is `nil` inside a subsequent `undo` on the same class (D2); (i) `undo` sees `result`, `compensate` sees `reason`. Confirm the file fails (it cannot load: `RubyReactor::Step` is a module today)
- [X] T004 Rewrite `lib/ruby_reactor/step.rb` as `class RubyReactor::Step`: delete `InputEnforcement`, `ClassMethods`, `self.included`, and `inherited`; keep the class-level DSL (`input`, `validate_inputs`, `input_contract` with parent-first merge, `declared_inputs`, `required_input_names`, `declares_inputs?`, private `own_input_contract`) verbatim as `class << self` methods; add `initialize(inputs, context, result: nil, reason: nil)` with `attr_reader :inputs, :context, :result, :reason`; add instance `run` (raises `NotImplementedError, "#{self.class} must implement #run"`), instance `undo`/`compensate` (return `RubyReactor.Skipped()`); `include RubyReactor::StepSignals` at instance level and define instance `Success`/`Failure`/`Halt`/`Skipped` delegating to `RubyReactor.*`; add class-level `run(arguments, context)` = enforce contract (raise with `step_name = name` on `InputValidationError`, outside the catch) → `new(validated, context)` → `catch(StepSignals::TAG) { instance.run }`; `undo(result, arguments, context)` and `compensate(reason, arguments, context)` = `new(arguments, context, result:/reason:)` → `catch(StepSignals::TAG) { instance.undo/compensate }`; `class << self; alias_method :call, :run; end`. Header comment states the lifecycle order and the fresh-instance rule (FR-009, FR-011)
- [X] T005 [P] Change `module Step` to `class Step` in `lib/ruby_reactor/step/input_contract.rb` (namespace line only; no logic change)
- [X] T006 [P] Migrate `lib/ruby_reactor/step/compose_step.rb`: `class Step` namespace, `class ComposeStep < RubyReactor::Step`, delete the dead `initialize(composed_reactor_class, argument_mappings)` and its `attr_reader`s (D6), move `self.run`/`self.compensate`/`self.undo` bodies to instance methods reading `inputs`/`context`/`reason`/`result`, move the `class << self; private` helpers to private instance methods
- [X] T007 [P] Migrate `lib/ruby_reactor/step/map_step.rb`: `class Step` namespace, `class MapStep < RubyReactor::Step`, instance `run`/`compensate` reading `inputs`/`context`, private helpers to private instance methods — EXCEPT `build_mapped_inputs` and `resolve_element`, which stay public class methods because `lib/ruby_reactor/map/helpers.rb:32` calls them (D6)
- [X] T008 [P] Migrate `lib/ruby_reactor/step/async_reactor_step.rb`: `class Step` namespace, `class AsyncReactorStep < RubyReactor::Step`, instance `run` reading `inputs`/`context`, private `class << self` helpers to private instance methods
- [X] T009 Update the catch-site comment in `lib/ruby_reactor/step_signals.rb` (lines 10–13) to say class steps are caught at `RubyReactor::Step`'s class-level `run`/`undo`/`compensate` and inline blocks at `step_executor.rb`/`compensation_manager.rb` (D4)
- [X] T010 Run `bundle exec rspec spec/ruby_reactor/step_spec.rb spec/ruby_reactor/step/map_step_spec.rb spec/compose_spec.rb spec/map spec/ruby_reactor/dsl/async_step_spec.rb` and `bundle exec rubocop lib/ruby_reactor/step.rb lib/ruby_reactor/step/`; all green before any story phase starts

**Checkpoint**: Library loads, base class contract proven, built-ins behave as before. Old-form steps in `spec/` and `demo_app/` still fail to load — expected until Phases 3–7.

---

## Phase 3: User Story 1 — Author a step by inheriting from the base step (Priority: P1) 🎯 MVP

**Goal**: Every step-authoring suite in `spec/` uses the inheriting form and passes, proving scenarios 1–6 of US1 against real suites, not just the new lifecycle spec.

**Independent Test**: `bundle exec rspec spec/ruby_reactor/step_spec.rb spec/ruby_reactor/step_signals_spec.rb spec/ruby_reactor/step_contract_enforcement_spec.rb spec/ruby_reactor/dsl/step_input_contract_spec.rb spec/ruby_reactor/halt_helper_spec.rb` is green with zero `include RubyReactor::Step` in those files.

### Implementation for User Story 1

Each migration below means: replace `include RubyReactor::Step` with `< RubyReactor::Step`, turn `def self.run(args, ctx)` into `def run` reading `inputs`/`context`, `def self.undo(result, args, ctx)` into `def undo` reading `result`/`inputs`/`context`, `def self.compensate(reason, args, ctx)` into `def compensate` reading `reason`/`inputs`/`context`; keep every assertion unchanged.

- [X] T011 [P] [US1] Migrate step classes in `spec/ruby_reactor/step_signals_spec.rb` (includes `compensate and undo bodies` examples at line ~190)
- [X] T012 [P] [US1] Migrate step classes in `spec/ruby_reactor/step_contract_enforcement_spec.rb`
- [X] T013 [P] [US1] Migrate step classes in `spec/ruby_reactor/dsl/step_input_contract_spec.rb`
- [X] T014 [P] [US1] Migrate step classes in `spec/ruby_reactor/dsl/inline_step_contract_spec.rb` (inline `inputs do ... end` blocks stay as they are; only class steps change)
- [X] T015 [P] [US1] Migrate step classes in `spec/ruby_reactor/dsl/step_contract_conflict_spec.rb`
- [X] T016 [P] [US1] Migrate step classes in `spec/ruby_reactor/dsl/step_contract_wiring_spec.rb`
- [X] T017 [P] [US1] Migrate step classes in `spec/ruby_reactor/step_contract_deprecation_spec.rb`
- [X] T018 [P] [US1] Migrate step classes in `spec/ruby_reactor/halt_helper_spec.rb`
- [X] T019 [P] [US1] Migrate step classes in `spec/ruby_reactor/falsey_input_resolution_spec.rb`
- [X] T020 [P] [US1] Migrate shared step classes in `spec/support/reactors/step_contract_reactors.rb`
- [X] T021 [US1] Run the Independent Test command above plus every file touched in T011–T020; all green

**Checkpoint**: US1 delivered — a developer can author, validate, and signal from an inheriting step, and the existing contract/signal suites prove it.

---

## Phase 4: User Story 2 — Reactor execution paths use the new step uniformly (Priority: P1)

**Goal**: Sync executor, async worker, retry, compensation/undo, compose, map, middleware, telemetry, and the RSpec `TestSubject` interception surface all pass against inheriting steps; the worker-path signal bug (D4) is fixed with a red-first test; and a validation failure is non-retryable on every one of those paths (D10), also proven red-first.

**Independent Test**: `bundle exec rspec spec/ruby_reactor/step_signals_worker_spec.rb spec/ruby_reactor/step_contract_retryable_spec.rb spec/ruby_reactor/rspec/test_subject_mock_step_spec.rb spec/ruby_reactor/middleware_spec.rb spec/ruby_reactor/telemetry_spec.rb spec/integration spec/async_retry_integration_spec.rb spec/compose_spec.rb` is green.

### Tests for User Story 2

- [X] T022 [US2] Write the red spec `spec/ruby_reactor/step_signals_worker_spec.rb`: a `class WorkerFailStep < RubyReactor::Step` whose `run` calls `fail!("nope")`, wired via `async_step :boom, WorkerFailStep` in a reactor; run with `test_reactor` + `drain_async_jobs`; assert `be_failure` and `result.error == "nope"`. Before T004 this failed with an `UncaughtThrowError` error value — with the base class in place it should already pass; keep it as the regression guard for the worker path (D4, US2 scenario 2). If it still fails, `StepWorker#execute_step_body` is bypassing `impl.run` somewhere — fix there, never by adding a `catch` to the worker
- [X] T023 [US2] Write the red spec `spec/ruby_reactor/step_contract_retryable_spec.rb` (FR-017, research.md D10): (a) a reactor whose only step declares `input :n, :integer` and is run synchronously with a violating value — assert `result.retryable?` is `false`; (b) the same violating step wired as the child of a `compose` — assert the **parent** reactor's `Failure.retryable?` is also `false` (proves `ComposeStep#handle_execution_result` does not silently reset it). Confirm both are red today: neither `Executor::ResultHandler#build_validation_failure` nor `Step::ComposeStep#handle_execution_result` passes `retryable:` explicitly, so `RubyReactor::Failure`'s default (`error.respond_to?(:retryable?) ? error.retryable? : true`) currently resolves to `true` in both cases — `Error::InputValidationError` has no `retryable?` method yet
- [X] T024 [US2] Add `def retryable? = false` to `lib/ruby_reactor/error/input_validation_error.rb`, mirroring `Error::StepFailureError#retryable?` (`lib/ruby_reactor/error/step_failure_error.rb`). Run T023's spec plus `spec/ruby_reactor/step_contract_async_spec.rb` (the existing worker-path regression guard, lines 24–33 and 54–59); all green with no other file touched — this one method is the entire fix (D10)

### Implementation for User Story 2

- [X] T025 [P] [US2] Migrate step classes in `spec/ruby_reactor/rspec/test_subject_mock_step_spec.rb` (exercises `TestSubject#apply_mock_interceptor`'s `impl.run` path)
- [X] T026 [P] [US2] Migrate the duck-typed `MiddlewareTestStep` in `spec/ruby_reactor/middleware_spec.rb` (plain class with `def self.run`, no mixin — still a class step, must inherit per SC-002)
- [X] T027 [P] [US2] Migrate the duck-typed `TelemetrySimpleStep` and `TelemetrySensitiveStep` in `spec/ruby_reactor/telemetry_spec.rb`
- [X] T028 [P] [US2] Migrate step classes in `spec/support/payment_workflow.rb` (compensation/undo bodies; used by integration and compose suites)
- [X] T029 [P] [US2] Migrate step classes in `spec/support/examples/data_pipeline.rb`
- [X] T030 [US2] Run `bundle exec rspec` (full suite) and `bundle exec rubocop`; compare against `specs/004-inheritable-step-class/baseline.md` — same pass count, no new failures, no new offenses. Grep confirms zero `include RubyReactor::Step\b` and zero mixin-free `def self.run(args, ctx)` step classes under `spec/`

**Checkpoint**: Every library execution path proven against the new class, including the non-retryable guarantee on validation failures; US1 + US2 together are the gem-level MVP.

---

## Phase 5: User Story 3 — Wrap an existing service as a step (Priority: P2)

**Goal**: A brownfield service class with no library dependency is wrapped by a ≤10-line adapter subclass, proven in the demo app end to end (success, failure/rollback, invalid inputs never instantiate the service).

**Independent Test**: `docker compose run --rm demo-app bin/rails demo:inheritable_step` prints success, failure-with-rollback, and validation-rejected outcomes; `docker compose run --rm demo-app bundle exec rspec spec/reactors/inheritable_step_demo_reactor_spec.rb` is green using only shipped matchers.

### Implementation for User Story 3 (Constitution Principle VI artifacts)

- [X] T031 [P] [US3] Create `demo_app/app/reactors/inheritable_step_demo_reactor.rb` containing: a plain `LegacyChargeService` (own `initialize(user_id)` + `call` returning an object with `success?`/`id`/`error`, no RubyReactor reference); `ChargeStep < RubyReactor::Step` with `input :user_id, :integer, gt?: 0` and a `run` delegating to the service (≤10 lines, SC-004) plus an `undo` that records the refund; a second inheriting step that `fail!`s when `inputs[:fail]` is true to force rollback; and `InheritableStepDemoReactor < RubyReactor::Reactor` wiring them with `input :user_id`, `input :fail`
- [X] T032 [US3] Register `demo:inheritable_step` in `demo_app/lib/tasks/demo_reactors.rake` with a `desc` and `[:environment, :flush_redis]`, printing three runs: valid inputs (success), `fail: true` (failure + `ChargeStep` undo printed), `user_id: 0` (validation failure, service never instantiated, and the printed result shows it is non-retryable per FR-017); add `:inheritable_step` to the `demo:all` dependency list at line ~242
- [X] T033 [P] [US3] Create `demo_app/spec/reactors/inheritable_step_demo_reactor_spec.rb` (`type: :reactor`) asserting `be_success`, `be_failure` + `have_run_step(:charge)` + rollback, and `have_validation_error` for `user_id: 0` — using only `test_reactor`, `drain_async_jobs`, and the shipped matchers from `lib/ruby_reactor/rspec.rb`; if an assertion needs a matcher that does not exist, add it to `lib/ruby_reactor/rspec/` in the same commit
- [X] T034 [US3] Run the Independent Test commands above; both green

**Checkpoint**: Brownfield use case proven the way users consume the gem.

---

## Phase 6: User Story 4 — Step contracts and behaviour inherit across subclasses (Priority: P2)

**Goal**: Parent-first contract merging and body overriding survive the move to a real class hierarchy with `inherited` deleted.

**Independent Test**: `bundle exec rspec spec/ruby_reactor/step_inheritance_spec.rb` is green.

### Tests for User Story 4

- [X] T035 [US4] Write `spec/ruby_reactor/step_inheritance_spec.rb`: `BaseStep < RubyReactor::Step` declares `input :a, :integer`; `ChildStep < BaseStep` declares `input :b, :integer` and defines `run` returning `Success(sum: inputs[:a] + inputs[:b])`; assert (1) invoking `ChildStep` without `:a` raises `InputValidationError` naming `:a`; (2) with both, the child's body runs and sees both; (3) a `GrandchildStep < ChildStep` overriding `run` still has validation run first (invalid `:b` never reaches the override); (4) `ChildStep.input_contract.declarations.keys == [:a, :b]` and `BaseStep.input_contract.declarations.keys == [:a]` (parent not mutated). Confirm red if T004 left any `inherited`-dependent memoization bug; otherwise it passes immediately and stays as the regression guard

### Implementation for User Story 4

- [X] T036 [US4] Run T035's spec plus `spec/ruby_reactor/step_contract_enforcement_spec.rb` and `spec/ruby_reactor/dsl/step_input_contract_spec.rb`; fix only if red — there should be nothing to implement (data-model.md: `inherited` deleted, contract ivars are already per-class)

**Checkpoint**: Hierarchies of user steps behave exactly as the input-contracts feature promised.

---

## Phase 7: User Story 5 — Documentation and demo reflect the single authoring style (Priority: P3)

**Goal**: Zero occurrences of the old form anywhere a newcomer reads; all existing demo reactors migrated; changelog records the break with a conversion example and the retryable fix.

**Independent Test**: `grep -rnE "include RubyReactor::Step\b" lib spec demo_app README.md documentation` returns nothing; `docker compose run --rm demo-app bin/rails demo:all` prints the same outcomes recorded in `baseline.md`; `docker compose run --rm demo-app bundle exec rspec spec/reactors` is green.

### Implementation for User Story 5 — demo app migration

- [X] T037 [P] [US5] Migrate `demo_app/app/reactors/validated_user_step.rb` (1 step)
- [X] T038 [P] [US5] Migrate `demo_app/app/reactors/user_etl_reactor.rb` (5 steps, includes compensate/undo bodies)
- [X] T039 [P] [US5] Migrate `demo_app/app/reactors/reserve_inventory.rb` (1 step with undo)
- [X] T040 [P] [US5] Migrate `demo_app/spec/support/payment_workflow.rb` and `demo_app/spec/support/examples/data_pipeline.rb` (demo-side copies of the spec support files)

### Implementation for User Story 5 — documentation (REQUIRED — Constitution Development Workflow)

Convert every `include RubyReactor::Step` + `def self.run(arguments, context)` example to `class X < RubyReactor::Step` + `def run` reading `inputs`/`context`; same for `undo`/`compensate` examples. Do not change surrounding prose beyond what the new form requires.

- [ ] T041 [P] [US5] Update `README.md` (5 occurrences: Quick Start and core-usage examples)
- [X] T042 [P] [US5] Update `documentation/getting_started.md` and `documentation/core_concepts.md` (the primary step-authoring guides — also add a short "Instance readers: `inputs`, `context`, `result`, `reason`" note, the fresh-instance-per-action rule, and a one-line note that validation failures are always non-retryable, to `core_concepts.md`)
- [X] T043 [P] [US5] Update `documentation/composition.md`, `documentation/async_reactors.md`, `documentation/README.md`
- [X] T044 [P] [US5] Update `documentation/examples/order_processing.md`, `documentation/examples/payment_processing.md`, and `demo_app/documentation/core_concepts.md`
- [X] T045 [US5] Add a `### ⚠ BREAKING CHANGES` entry under `## Unreleased` in `CHANGELOG.md`: mixin form removed, `RubyReactor::Step` is now a base class, before/after conversion example (class-level `run` → instance `run` with `inputs`/`context`; `undo`/`compensate` likewise); note that class steps now translate signals correctly on the `async_step`/`background` worker path (D4); note that a step's input-validation failure is now guaranteed non-retryable on every path, including through `compose` (D10, FR-017 — previously only the async worker path was correct); and a one-line known-issue that inline block steps on the worker path still do not catch signals (pre-existing, out of scope)
- [X] T046 [US5] Run the Independent Test commands above; grep empty, demo `all` outcomes match `baseline.md`, demo specs green

**Checkpoint**: A newcomer finds exactly one way to write a step everywhere they look.

---

## Phase 8: Polish & Cross-Cutting Concerns

- [X] T047 Run `bundle exec rspec` and `bundle exec rubocop` one final time; compare with `specs/004-inheritable-step-class/baseline.md` (SC-003); then delete `baseline.md`
- [X] T048 [P] Walk `specs/004-inheritable-step-class/quickstart.md` sections 1, 1b, 3, 4, 5 verbatim and confirm each expected outcome, including the `result.retryable? # => false` check
- [X] T049 [P] Read `lib/ruby_reactor/step.rb` top to bottom and confirm SC-001: the lifecycle (instantiate → validate → run → translate signal) is readable as plain method calls with no `prepend`, `extend`, `define_method`, or `method_missing` anywhere in the file
- [ ] T050 Commit with a `feat!:` subject so release-please bumps 0.7.0 → 0.8.0 (`bump-minor-pre-major: true`); body carries the CHANGELOG conversion example

---

## Dependencies & Execution Order

### Phase Dependencies

- **Phase 1 (Baseline)**: none — start immediately; T001 and T002 in parallel
- **Phase 2 (Foundational)**: after Phase 1; T003 first (red), then T004–T009 as one commit (T005–T008 parallel once T004's class shape is known), then T010 — **BLOCKS all stories**
- **Phase 3 (US1)**: after Phase 2; T011–T020 all parallel (distinct files), T021 gates
- **Phase 4 (US2)**: after Phase 2; T022 and T023 first (red guards, can run in parallel with each other — distinct files), then T024 (the one-line retryable fix), then T025–T029 parallel, then T030 gates. Independent of Phase 3 except that T030's full-suite run needs Phase 3's files migrated too — so in practice finish Phase 3 before T030
- **Phase 5 (US3)**: after Phase 2; T031 and T033 parallel, T032 after T031, T034 gates. Independent of Phases 3–4
- **Phase 6 (US4)**: after Phase 2; T035 then T036. Independent of Phases 3–5
- **Phase 7 (US5)**: after Phase 2 for the demo migrations (T037–T040 parallel); T041–T044 parallel and can start any time after T004 (they only need the final API shape); T045 after T022 and T024 (it documents both fixes); T046 gates and needs Phases 5 and 7 complete (demo `all` includes the new task)
- **Phase 8 (Polish)**: after everything

### User Story Dependencies

- **US1 (P1)**: Foundational only
- **US2 (P1)**: Foundational only; full-suite gate (T030) practically needs US1's migrations
- **US3 (P2)**: Foundational only
- **US4 (P2)**: Foundational only
- **US5 (P3)**: Foundational; final gate (T046) needs US3's demo task registered

### Parallel Opportunities

- T001 ∥ T002
- T005 ∥ T006 ∥ T007 ∥ T008 (after T004)
- T011–T020 all parallel (10 distinct spec files)
- T022 ∥ T023 (distinct new spec files)
- T025–T029 all parallel
- T031 ∥ T033; T035 ∥ everything in Phase 5
- T037–T044 all parallel (12 distinct files across demo + docs)
- T048 ∥ T049

---

## Parallel Example: User Story 1

```bash
# After T010 is green, launch all ten spec-file migrations together:
Task: "Migrate step classes in spec/ruby_reactor/step_signals_spec.rb"
Task: "Migrate step classes in spec/ruby_reactor/step_contract_enforcement_spec.rb"
Task: "Migrate step classes in spec/ruby_reactor/dsl/step_input_contract_spec.rb"
Task: "Migrate step classes in spec/ruby_reactor/dsl/inline_step_contract_spec.rb"
Task: "Migrate step classes in spec/ruby_reactor/dsl/step_contract_conflict_spec.rb"
Task: "Migrate step classes in spec/ruby_reactor/dsl/step_contract_wiring_spec.rb"
Task: "Migrate step classes in spec/ruby_reactor/step_contract_deprecation_spec.rb"
Task: "Migrate step classes in spec/ruby_reactor/halt_helper_spec.rb"
Task: "Migrate step classes in spec/ruby_reactor/falsey_input_resolution_spec.rb"
Task: "Migrate shared step classes in spec/support/reactors/step_contract_reactors.rb"
# Then T021 gate.
```

---

## Implementation Strategy

### MVP First (Foundational + US1)

1. Phase 1: capture baseline (10 min)
2. Phase 2: red lifecycle spec → base class + namespace flip + built-ins in one commit → T010 green
3. Phase 3: migrate the ten step-authoring spec files → T021 green
4. **STOP and VALIDATE**: `spec/ruby_reactor/step_spec.rb` + the US1 suites prove a developer can author, validate, and signal from an inheriting step

### Incremental Delivery

1. + US2 (worker-signal guard, non-retryable-validation guard, remaining spec migrations) → full `bundle exec rspec` green → gem-level feature complete
2. + US3 (demo reactor, rake task, spec) → Principle VI satisfied for the new API
3. + US4 (inheritance spec) → regression guard in place
4. + US5 (demo migration, docs, changelog) → nothing old-form left anywhere
5. Polish → `feat!:` commit

### Single-Developer Reality

This is one person's refactor on one branch. Recommended commit boundaries: (1) baseline, (2) Phase 2 as a whole, (3) Phases 3+4 together (the suite is only green once both land), (4) Phase 5, (5) Phase 6, (6) Phase 7, (7) Polish. Between (2) and (3) the full suite is red by design — do not push that state.

---

## Notes

- Anchor every grep with `\b`; `include RubyReactor::StepSignals` in `step.rb` and `dsl/template_helpers.rb` is correct and stays
- Duck-typed step classes (plain class + `def self.run`, no mixin) in `middleware_spec.rb` and `telemetry_spec.rb` still *work* with the executor but violate SC-002 — migrate them (T026, T027)
- Never add a `catch(StepSignals::TAG)` to `step_worker.rb`; FR-007 puts signal translation in the step class (D4)
- Never re-add `inherited`, `prepend`, or any interception to `step.rb` (FR-011); if a subclass needs different lifecycle behavior, that is a spec change, not a hook
- `MapStep.build_mapped_inputs` / `resolve_element` stay class-level (T007); everything else on the built-ins goes instance-level
- The non-retryable fix (T024) is exactly one method on `Error::InputValidationError` — resist the urge to also pass `retryable: false` at `build_validation_failure` or `ComposeStep#handle_execution_result`; the whole point of D10 is that neither call site needs to know
- Commit after each phase gate; stop at any checkpoint to validate the story independently
