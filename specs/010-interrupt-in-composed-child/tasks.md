---
description: "Task list for 010 Interrupt Inside a Composed Child"
---

# Tasks: Interrupt Inside a Composed Child

**Input**: Design documents from `specs/010-interrupt-in-composed-child/`

**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/api-surface.md,
quickstart.md

**Tests**: Required. Constitution III makes tests test-first on real Redis. Each story's tests are
written and seen failing before its implementation tasks.

**Organization**: Grouped by user story (spec.md). R-xx refers to research.md, FR-xxx to spec.md.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: can run in parallel (different files, no dependency on an incomplete task)
- **[Story]**: US1–US4 from spec.md

---

## Phase 1: Setup (Shared Fixtures)

**Purpose**: The reactors every story's specs use.

- [X] T001 Create `spec/ruby_reactor/interrupt_in_compose_spec.rb`, with its fixtures in `spec/support/interrupt_in_compose_fixtures.rb` (`module InterruptInComposeFixtures`, shared with the helpers spec in T033). The fixtures are built on `RollbackRecorder::Reactor` (`spec/support/rollback_recorder.rb`).
  - `Child` (tag `"child"`): `input :seed, optional: true`; `recording_step :c1`; `interrupt :approve` (`wait_for :c1`, `correlation_id { |ctx| "approve-#{ctx.inputs[:seed]}" }`); `recording_step :c2, after: :approve`. `c2` records the approve payload: `argument :decision, result(:approve)` through the `&extra` block.
  - `Root`: `recording_step :r1`; `compose :fulfil, Child` (`argument :seed, result(:r1)`); `recording_step :r2, after: :fulfil`.
  - `Middle`: like `Root`, composing `Child` at `:fulfil`. `Top`: composes `Middle` at `:order`, then `recording_step :t2`.
  - `TwoInterruptsChild`: `c1`, `interrupt :approve`, `interrupt :sign` (`wait_for :approve`), `c2`; and `TwoInterruptsRoot` composing it.
  - `RootWithOwnInterrupt`: `r1`, `interrupt :audit` (`wait_for :r1`) and `compose :fulfil, Child` both ready after `r1`, then `r2` after both.
  - `BackgroundChild`: `Child` with `interrupt :approve, resume: :background`; `BackgroundRoot` composing it.
  - `ValidatedChild`: `interrupt :approve` with `validate_payload { required(:ok).filled(:bool) }` and `max_attempts: 1`; `ValidatedRetryChild` the same with `max_attempts: 3`; a root composing each.
  - `before { RollbackRecorder.reset! }`, and a `drain` helper as in `spec/map/map_compose_fan_out_spec.rb`.
- [X] T002 [P] Add to `MapComposeFanOutSpec` in `spec/map/map_compose_fan_out_spec.rb`: a child fixture `InterruptChild` (same as `Child`, plus `interrupt :approve` after `:m`, with `c2` waiting for `:approve`) and `root :InterruptRoot, InterruptChild`.

---

## Phase 2: Foundational

None. US1's pass-through is the base the other stories build on, and it is small enough to live in
US1.

---

## Phase 3: User Story 1 - Pause the root at an interrupt inside a composed child (Priority: P1) 🎯 MVP

**Goal**: A root whose composed child reaches an `interrupt` is stored `paused` and returns an
`InterruptResult` naming the root (FR-001–FR-004).

**Independent Test**: `InterruptInComposeSpec::Root.run({})`:

- the result is `paused?`, with `execution_id` equal to the root's id;
- `Root.find(id).context.status == "paused"`;
- the log is exactly `["run:r1", "run:child.c1"]`, with no undo events.

### Tests for User Story 1 (write first, confirm failing)

- [X] T003 [US1] In `spec/ruby_reactor/interrupt_in_compose_spec.rb`, describe "pausing" (US1-AS1). Running `Root`:
  - returns an `InterruptResult`, with `paused?` true and `execution_id == Root.find(result.execution_id).context.context_id`;
  - leaves the stored status `"paused"`, with `current_step` `:fulfil`;
  - leaves the log at `%w[run:r1 run:child.c1]`.
- [X] T004 [US1] In the same file, assert that the paused result's `correlation_id` is `"approve-r1-value"` (the seed is `r1`'s value), and that `Root.find_by_correlation_id("approve-r1-value").context.context_id` is the root's id (US1-AS2, FR-004).
- [X] T005 [US1] In the same file, assert that running `Top` stores `Top` as `"paused"`, returns `Top`'s id, and that the log stops after `run:child.c1` (US1-AS4, FR-002).
- [X] T006 [P] [US1] In `spec/map/map_compose_fan_out_spec.rb`, replace the `pending` example "resumes the root once the child's interrupt after the map is continued" with a real one. Under `for_each_async_backend`:
  - `run(MapComposeFanOutSpec::InterruptRoot)` leaves the root `"paused"`;
  - the root's `composed_contexts[:c][:context].current_step` is `:approve`;
  - no `run:child.c2` was logged.

  The resume half is added in T024 (US1-AS3, FR-015).

### Implementation for User Story 1

- [X] T007 [P] [US1] In `lib/ruby_reactor/step/compose_step.rb`, `handle_execution_result` returns `RubyReactor::InterruptResult.new(execution_id: context.context_id, correlation_id: result.correlation_id, intermediate_results: context.intermediate_results)` when `result.is_a?(RubyReactor::InterruptResult)`. Put it before the `success?` line, with a comment: each compose level re-stamps its own id, so the top-level result names the root (R-02).
- [X] T008 [P] [US1] In `lib/ruby_reactor/executor/retry_manager.rb`, `handle_retry_result` passes `RubyReactor::InterruptResult` through unchanged. Add it to the `when RetryQueuedResult, RubyReactor::DispatchResult` arm (R-01).
- [X] T009 [P] [US1] In `lib/ruby_reactor/executor/result_handler.rb`, give `handle_step_result` a `when RubyReactor::InterruptResult` arm, before `else`, calling a new private `handle_interrupted(step_config)`. That method sets `@context.current_step = step_config.name`. Comment: `with_step` cleared it, and it is the root's resume cursor (R-03). Nothing is recorded as a result and the graph node stays incomplete.
- [X] T010 [US1] Run `bundle exec rspec spec/ruby_reactor/interrupt_in_compose_spec.rb spec/map/map_compose_fan_out_spec.rb spec/compose_spec.rb spec/ruby_reactor/interrupt_spec.rb`. T003–T006 must pass and nothing else may regress.

**Checkpoint**: Roots pause at any depth, sync and after a fan-out map.

---

## Phase 4: User Story 2 - Resume the root by naming the nested interrupt (Priority: P1)

**Goal**: `continue` and `continue_by_correlation_id` on the root accept an Array path and finish
the run. Wrong names and direct child resumes are refused (FR-005–FR-011).

**Independent Test**: Pause `Root`, then `Root.continue(id:, payload: { ok: true }, step_name:
[:fulfil, :approve])`. Expect:

- status `"completed"`;
- log `%w[run:r1 run:child.c1 run:child.c2 run:r2]`;
- `c2` received the payload.

### Tests for User Story 2 (write first, confirm failing)

- [X] T011 [US2] In `spec/ruby_reactor/interrupt_in_compose_spec.rb`, describe "resuming" (US2-AS1, FR-008/FR-009):
  - continuing with `[:fulfil, :approve]` completes the root;
  - each step logs `run:` exactly once across pause and resume;
  - `c2`'s stored result reflects the payload;
  - string paths (`["fulfil", "approve"]`) work the same.
- [X] T012 [US2] In the same file, assert that `Root.continue_by_correlation_id(correlation_id: "approve-r1-value", payload:, step_name: [:fulfil, :approve])` completes the root (US2-AS2).
- [X] T013 [US2] In the same file, assert each of these raises `RubyReactor::Error::ValidationError` whose message includes `[:fulfil, :approve]`, leaving the status `"paused"` and the log unchanged (US2-AS4, FR-007, FR-011):
  - `step_name: :approve`;
  - `step_name: [:fulfil, :nope]`;
  - `step_name: [:r2, :approve]`;
  - `step_name: :r2`.
- [X] T014 [US2] In the same file, assert that a direct child resume raises `ValidationError` matching `/composed child/` and runs nothing (FR-005). Cover both:
  - `Child.continue(id: <root>.context.composed_contexts[:fulfil][:context].context_id, …)`;
  - `Child.continue_by_correlation_id(correlation_id: "approve-r1-value", …)`.
- [X] T015 [US2] In the same file, under `for_each_async_backend`, assert that continuing `BackgroundRoot` (US2-AS3, FR-010):
  - returns a `DispatchResult`;
  - completes after `drain`;
  - calls the async router's `perform_async` with the root's id, and never with the child's id (pattern as in `spec/map/map_compose_fan_out_spec.rb` "signals the root's Worker").
- [X] T016 [US2] In the same file, assert that continuing the `ValidatedRetryChild` root with `{ ok: "x" }` (FR-010):
  - raises `InputValidationError` from the class method;
  - keeps the run `"paused"`;
  - stores `private_data[:interrupt_attempts]["fulfil.approve"] == 1`;
  - lets a valid payload then complete it.
- [X] T017 [US2] In the same file, cover multi-interrupt flows:
  - `TwoInterruptsRoot`: continue `[:fulfil, :approve]`, which re-pauses with `ready_interrupt_steps == [[:fulfil, :sign]]`; continue `[:fulfil, :sign]`, which completes (US2-AS6).
  - `RootWithOwnInterrupt`: `ready_interrupt_steps` contains both `:audit` and `[:fulfil, :approve]`; continuing each in turn completes the run (edge case).
- [X] T018 [US2] In the same file, assert that `Top`'s `ready_interrupt_steps == [[:order, :fulfil, :approve]]`, and that continuing with that path completes `Top` with `run:t2` logged once (FR-006).
- [X] T019 [US2] In the same file, assert that a `continue` while the resume is executing is refused with the existing "not paused" message (edge case, 008 FR-032). Stub `c2`'s run, via an `&extra` hook, to call `Root.continue` again with the same path, and expect `ValidationError` matching `/running, not paused/`.

### Implementation for User Story 2

- [X] T020 [P] [US2] In `lib/ruby_reactor/step/compose_step.rb`, `prepare_child_context` sets `child_context.private_data[:composed] = true` when it builds a new child context (R-07).
- [X] T021 [US2] In `lib/ruby_reactor/reactor.rb`, add public `ready_interrupt_steps` (R-05):
  - Return `[]` unless `@context.status.to_s == "paused"`.
  - Otherwise return `pending_interrupts(self.class, @context, [])`, a private recursive helper. It builds a `GraphManager` (as `validate_continue_step!` does), takes the ready steps and collects:
    - for each `interrupt?` step, `prefix.empty? ? name : prefix + [name]`;
    - for each ready step whose `composed_contexts[name]` is `type: :composed` with a `paused` `:context`, the recursion into `(child.reactor_class, child, prefix + [name])`.
  - Read hash keys indifferently (symbol or string), since stored `composed_contexts` round-trip through the serializer.
- [X] T022 [US2] In `lib/ruby_reactor/reactor.rb`, `#continue` (R-06, R-07):
  - **Child guard**: right after the `current_step` guard, raise `Error::ValidationError, "Cannot resume: #{self.class.name} is a composed child; continue its root run"` when `@context.private_data[:composed] || @context.private_data["composed"]`.
  - **Path normalization**: `path = Array(step_name).map(&:to_sym)`. A one-element path is a bare name.
  - **Bare names** keep today's `validate_continue_step!`.
  - **Paths**:
    - raise `Error::ValidationError, "Cannot resume: #{path.inspect} is not a pending interrupt; pending: #{ready_interrupt_steps.inspect}"` unless `ready_interrupt_steps.include?(path)`;
    - then walk `composed_contexts[...][:context]` down `path[0..-2]` to get `target_context`, and take `step_config = target_context.reactor_class.steps[path.last]`.
  - **Callers to update**:
    - `validate_continue_payload` takes `step_config` and an attempts key: `path.join(".")` for a path, the Symbol for a bare name;
    - `set_result` goes to `target_context` with `path.last`;
    - `background_resume?` reads `step_config`.
  - Root status, save and `resume_execution` stay as they are.
- [X] T023 [US2] Run `bundle exec rspec spec/ruby_reactor/interrupt_in_compose_spec.rb spec/ruby_reactor/interrupt_spec.rb spec/ruby_reactor/multiple_interrupts_spec.rb spec/ruby_reactor/interrupt_background_resume_spec.rb spec/integration/interrupt_validation_spec.rb spec/integration/interrupt_max_attempts_spec.rb`. T011–T019 must pass with no regression.
- [X] T024 [US2] In `spec/map/map_compose_fan_out_spec.rb`, extend the T006 example: `InterruptRoot.continue(id:, payload: {}, step_name: [:c, :approve])`, `drain`, then expect `"completed"` and `r2` == `"r2-value"` (FR-015).

**Checkpoint**: The MVP (US1 + US2) is usable: pause and resume through a compose.

---

## Phase 5: User Story 3 - Undo or cancel a run paused inside a child (Priority: P2)

**Goal**: Undo reaches the child's completed steps, cancel blocks resumes, and `max_attempts`
exhaustion rolls back from the root (FR-012, FR-013, US2-AS5).

**Independent Test**: Pause `Root`, then `Root.undo(id)`. The log tail is `%w[undo:child.c1
undo:r1]`, each once, and the status is `"cancelled"`.

### Tests for User Story 3 (write first, confirm failing)

- [X] T025 [US3] In `spec/ruby_reactor/interrupt_in_compose_spec.rb`, describe "undo and cancel":
  - Undoing a paused `Root` logs `undo:child.c1` before `undo:r1`, each exactly once, and ends `"cancelled"` (US3-AS1).
  - Undoing a paused `Top` reaches `undo:child.c1` too.
- [X] T026 [US3] In the same file, assert that a `Root` paused, resumed to completion, then undone logs each of `undo:child.c2`, `undo:child.c1`, `undo:r2` and `undo:r1` exactly once. This proves the partial-run entry was replaced, not duplicated (R-04).
- [X] T027 [US3] In the same file, assert that `Root.cancel(id:, reason: "no")` on a paused root makes a later `continue` with `[:fulfil, :approve]` raise `ValidationError` matching `/cancelled/`, with no `run:` logged (US3-AS3, FR-013).
- [X] T028 [US3] In the same file, assert that continuing the `ValidatedChild` root (`max_attempts: 1`) with `{ ok: "x" }` (US2-AS5, FR-010):
  - returns a `Failure`;
  - logs `undo:child.c1` before `undo:r1`;
  - leaves the stored status `"failed"`.
- [X] T029 [P] [US3] In `spec/map/map_compose_fan_out_spec.rb`, under "rollback through the root", add an example (US3-AS2). Pause `InterruptRoot`, `RollbackRecorder.reset!`, `InterruptRoot.undo(id)`, `drain`, then expect:
  - `"cancelled"`;
  - `element_undos.size == 8`, each once;
  - `undo:child.c1` then `undo:r1` last.

### Implementation for User Story 3

- [X] T030 [US3] In `lib/ruby_reactor/executor/result_handler.rb`, `handle_interrupted` also pushes `{ step: step_config, arguments: step_config.rollback_arguments(resolved_arguments), result: RubyReactor.Success(nil) }` with `@compensation_manager.add_to_undo_stack` when `step_config.undoes_partial_run?`. This is the same entry as `StepExecutor#track_interrupted_construct`. Pass `resolved_arguments` through from `handle_step_result` (R-04).
- [X] T031 [US3] In `lib/ruby_reactor/executor/compensation_manager.rb`, `add_to_undo_stack` pops the top entry first when it belongs to the same step (`undo_stack.last && undo_stack.last[:step].name == step_info[:step].name`). Add a `ponytail:` comment naming the assumption: a step's entry is on top when it re-runs, because a run stops at a pause (R-04).
- [X] T032 [US3] Run `bundle exec rspec spec/ruby_reactor/interrupt_in_compose_spec.rb spec/map/map_compose_fan_out_spec.rb spec/ruby_reactor/interrupt_undo_spec.rb spec/ruby_reactor/rollback`. T025–T029 must pass with no regression.

**Checkpoint**: Saga integrity holds for nested pauses.

---

## Phase 6: User Story 4 - Test a nested pause with the RSpec helpers (Priority: P3)

**Goal**: `be_paused_at`, `have_ready_interrupts`, `ready_interrupt_steps` and `resume(step:)`
accept paths (FR-014).

**Independent Test**: `test_reactor(InterruptInComposeSpec::Root)`. Expect:

- `be_paused_at([:fulfil, :approve])` passes;
- `be_paused_at(:approve)` fails, with a message containing `[:fulfil, :approve]`;
- `resume(payload: { ok: true })` reaches `be_success`.

### Tests for User Story 4 (write first, confirm failing)

- [X] T033 [US4] In `spec/ruby_reactor/rspec/helpers_spec.rb`, add a "nested interrupts" context using `InterruptInComposeSpec::Root` (US4-AS1–AS3):
  - `subject.ready_interrupt_steps == [[:fulfil, :approve]]`;
  - `be_paused_at([:fulfil, :approve])` passes, and `have_ready_interrupts([:fulfil, :approve])` passes;
  - `expect { expect(subject).to be_paused_at(:approve) }.to fail_with(/\[:fulfil, :approve\]/)`;
  - `resume(payload: { ok: true })` with no step, and `resume(step: [:fulfil, :approve], …)`, both end `be_success`.

  Require the fixture file, or move the `InterruptInComposeSpec` module to `spec/support/interrupt_in_compose_fixtures.rb` if it is needed from two files.

### Implementation for User Story 4

- [X] T034 [P] [US4] In `lib/ruby_reactor/rspec/test_subject.rb`:
  - `ready_interrupt_steps` delegates to `@reactor_instance.ready_interrupt_steps`, and the duplicated graph code goes;
  - `determine_resume_step` normalizes `step` (`step.is_a?(Array) ? step.map(&:to_sym) : step.to_sym`) before the `include?` check, and prints `step.inspect` in its error.
- [X] T035 [P] [US4] In `lib/ruby_reactor/rspec/matchers.rb`:
  - `be_paused_at` and `have_ready_interrupts` normalize each expected name the same way;
  - sorting in `have_ready_interrupts` uses `sort_by(&:inspect)`, because Symbols and Arrays do not compare;
  - failure messages print names with `inspect` instead of `":#{s}"`.
- [X] T036 [US4] Run `bundle exec rspec spec/ruby_reactor/rspec` and the demo interrupt specs (`demo_app/spec/reactors/form_interrupt_reactor_spec.rb`, `webhook_interrupt_reactor_spec.rb`) per quickstart.md §2. T033 must pass with no regression.

**Checkpoint**: All four stories work independently.

---

## Phase 7: Polish & Cross-Cutting Concerns

### Map element guard (FR-017, R-08)

- [X] T037 Add specs that an interrupt inside a map element fails that element with a message matching `/not supported inside a map element/`, never `NoMethodError`:
  - in `spec/map/map_compose_fan_out_spec.rb`, an element reactor that composes a child with an `interrupt`, run fan-out under `for_each_async_backend`, with the root ending `"failed"`;
  - in `spec/ruby_reactor/interrupt_in_compose_spec.rb`, the same element run as an inline map.
- [X] T038 In `lib/ruby_reactor/executor/step_executor.rb`, `handle_interrupt_step` returns `RubyReactor::Failure("interrupt :#{step_config.name} is not supported inside a map element", step_name: step_config.name, reactor_name: @reactor_class.name, retryable: false)` when `@context` or any `parent_context` up the chain has `map_metadata`. Use a small private `inside_map_element?` loop. T037 must pass.

### Demo app (Constitution VI)

- [X] T039 [P] Create `demo_app/app/reactors/manager_approval_reactor.rb`: `ManagerApprovalReactor`, with class-based steps.
  - `input :order_id`;
  - `step :reserve_stock`, with an `undo` that prints/records the release;
  - `interrupt :wait_for_manager` (`wait_for :reserve_stock`, `correlation_id { |ctx| "approval-#{ctx.inputs[:order_id]}" }`, `validate_payload { required(:approved).filled(:bool) }`);
  - `step :confirm_reservation`, which fails when `approved` is false.
- [X] T040 [P] Create `demo_app/app/reactors/composed_approval_reactor.rb`: `ComposedApprovalReactor`, with class-based steps.
  - `input :order_id`;
  - `step :charge_card`, with an `undo` refund;
  - `compose :approval, ManagerApprovalReactor` (`argument :order_id, input(:order_id)`);
  - `step :ship`, after `:approval`.
- [X] T041 Add `demo:composed_interrupt` to `demo_app/lib/tasks/demo_reactors.rake`, with `desc` and `[:environment, :flush_redis]`. It prints:
  - the run's status, root id and `ready_interrupt_steps`;
  - an approved `continue` by correlation id with `step_name: [:approval, :wait_for_manager]`, and its final status;
  - a second run undone while paused, its status, and that `reserve_stock` and `charge_card` were undone.
- [X] T042 Create `demo_app/spec/reactors/composed_approval_reactor_spec.rb` (`type: :reactor`), using only the shipped surface:
  - `test_reactor`, `be_paused_at([:approval, :wait_for_manager])`, `have_ready_interrupts`;
  - `resume(step: [:approval, :wait_for_manager], payload: { approved: true })` then `be_success` and `have_run_step(:ship).after(:approval)`;
  - a rejected resume ending `be_failure`.

  Run it locally per quickstart.md §2.
- [X] T043 Run the Docker acceptance `docker compose … run --rm --no-deps demo-app bash -c "bin/rails db:prepare && bin/rails demo:composed_interrupt"` with an isolated compose project (quickstart.md §2). Record the output in the PR description.

### Documentation (Constitution Development Workflow)

- [X] T044 [P] Update `documentation/composition.md` rule 6: replace "An `interrupt` inside a composed child is not supported yet, with or without a map." with the nested pause behavior, linking to interrupts.md: the root pauses, is resumed by path, and undo reaches the child.
- [X] T045 [P] Add "Interrupts inside composed reactors" to `documentation/interrupts.md`, after "Resuming Execution". Use class-based examples. Cover:
  - the path form, why it is an Array, and `ready_interrupt_steps`;
  - correlation id on the root class;
  - background resume running in the root's worker;
  - undo and cancel;
  - the composed-child guard;
  - interrupts inside map elements being unsupported.
- [X] T046 [P] Add one line in `README.md` § *Interrupts (Pause & Resume)* noting that interrupts work inside `compose`d children, resumed by path, with a link to the new interrupts.md section.
- [X] T047 [P] Add a *Features* entry under *Unreleased* in `CHANGELOG.md`: interrupts inside composed children; Array `step_name` paths; `Reactor#ready_interrupt_steps`; matcher path support; and the map-element interrupt now failing clearly.
- [X] T048 [P] Remove the "Interrupt inside a composed child" section from `specs/future_improvements.md`.

### Gate

- [X] T049 Run `bundle exec rspec` and `bundle exec rubocop` at the repo root, and the full `demo_app` spec suite per quickstart.md §2. All must be green. If an async example flakes, rerun it alone first (shared test Redis).

---

## Dependencies & Execution Order

- **Setup (T001–T002)** comes first.
- **US1 (T003–T010)** depends on Setup, and blocks US2, US3 and US4: nothing can be resumed, undone or matched until the root pauses.
- **US2 (T011–T024)** depends on US1.
- **US3 (T025–T032)** depends on US1. T028 (`max_attempts` exhaustion) also needs US2's T022 to resolve the nested step config, so implement it after T022.
- **US4 (T033–T036)** depends on US2's T021 (`Reactor#ready_interrupt_steps`).
- **Polish**:
  - the map guard (T037–T038) depends on US1 only;
  - the demo (T039–T043) depends on US1–US4;
  - the docs (T044–T048) can be drafted after US2 and finalized last;
  - T049 runs last.

Within each story, the tests are written and seen failing before the implementation tasks.

## Parallel Opportunities

- T002 can run alongside T001.
- In US1, T007, T008 and T009 touch three different files.
- In US2, T020 can run alongside T021/T022 (different file). T021 and T022 share `reactor.rb`, so they run one after the other.
- In US3, T029 is in a different spec file from T025–T028.
- In US4, T034 and T035 touch different files.
- In Polish, T039 and T040 run in parallel, as do T044–T048.

```text
# US1 implementation, after T003–T006 fail:
T007 compose_step.rb  |  T008 retry_manager.rb  |  T009 result_handler.rb
```

## Implementation Strategy

1. **MVP = US1 + US2** (both P1). Pausing alone is a dead end: ship them together. Stop after T024
   and validate with quickstart.md §1, rows 1–6.
2. **US3** next. Undo while paused is a saga guarantee (Constitution II), so it must land before
   release, not as a follow-up.
3. **US4** after that: test-surface convenience.
4. **Polish**: map guard, demo with the Docker run, docs, then the full gate.
