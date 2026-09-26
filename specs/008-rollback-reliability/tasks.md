---

description: "Task list for 008 Reliable Rollback Across Constructs"
---

# Tasks: Reliable Rollback Across Constructs

**Input**: Design documents from `specs/008-rollback-reliability/`

**Prerequisites**: [plan.md](plan.md), [spec.md](spec.md), [research.md](research.md),
[data-model.md](data-model.md), [contracts/](contracts/), [quickstart.md](quickstart.md)

**Tests**: REQUIRED. Constitution III (test-first, real Redis) and spec FR-027. In every story,
write the spec tasks first and confirm they FAIL on the current code before implementing.

**Organization**: tasks are grouped by user story (spec.md US1–US5). Research decisions are cited
as `R-nn`, data-model sections as `DM §n`, contracts as `RS §n` (rollback-semantics.md) and
`API §n` (api-surface.md).

## Format: `[ID] [P?] [Story] Description`

- **[P]**: can run in parallel (different files, no dependency on an incomplete task)
- **[Story]**: US1–US5 from spec.md

## Path Conventions

Single gem project: `lib/ruby_reactor/`, `spec/`, `demo_app/`, `gui/`, `documentation/`.

**Test rules**:

- Run specs against the test Redis at `redis://localhost:6780`.
- Async paths use `for_each_async_backend` from `spec/support/async_backends.rb` plus
  `drain_async_jobs`. Never use `Sidekiq::Testing.inline!` (Constitution III).
- Don't run the gem suite and the demo suite at the same time: they flush the same Redis.

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: test scaffolding shared by every story's specs.

- [X] T001 Create `spec/support/rollback_recorder.rb`:
  - Module `RollbackRecorder` with `.log` (Array of strings), `.reset!` and `.record(event)`.
  - An `RSpec.configure` hook that calls `RollbackRecorder.reset!` before each example under
    `spec/ruby_reactor/rollback/`.
  - A reactor base class `RollbackRecorder::Reactor < RubyReactor::Reactor` with a class macro
    `recording_step(name, after: nil, fail: nil, idx: false, undo_fails: false, compensate_raises: false)`.
    Port it from the `pstep` macro in `specs/007-execution-flow-analysis/evidence/harness.rb`.
    Each recording step logs `run:<tag>.<name>[<i>]`, `compensate:…` and `undo:…` exactly like the
    007 probes, so assertions can compare whole sequences such as
    `%w[run:a run:e.e1[0] … undo:a]`.
- [X] T002 [P] Add `config.filter_run_excluding :slow` to `spec/spec_helper.rb`, so `:slow` examples
  run only with `--tag slow`.
- [X] T003 [P] Baseline check, with no file changes:
  - Run `bundle exec ruby specs/007-execution-flow-analysis/evidence/run.rb`.
  - Confirm the tail line reads `63 scenarios, 63 match, 0 mismatch`, and that
    `git diff specs/007-execution-flow-analysis/evidence/output.txt` is empty after re-teeing.

---

## Phase 2: Foundational (Blocking Prerequisites), R-01 bounded refactor

**Purpose**: `StepConfig` becomes the single owner of per-step lifecycle operations. This is a
**pure refactor with no behavior change**. Every story builds on it.

**⚠️ CRITICAL**: no user story work can start until T009 is green.

- [X] T004 Add `StepConfig#resolve_arguments(context)` in `lib/ruby_reactor/dsl/step_builder.rb`.
  The body is exactly `StepExecutor#resolve_arguments` today: for each
  `arguments[name] = { source:, transform: }`, `value = source.resolve(context)`, then apply
  `transform.call(value)` if a transform is present. It returns a Hash. Nothing is wrapped yet
  (US3 adds that). `InterruptStepConfig` inherits it.
- [X] T005 In `lib/ruby_reactor/executor/step_executor.rb`, replace every call to the private
  `resolve_arguments(step_config)` with `step_config.resolve_arguments(@context)`, and delete the
  private method. Run `grep -rn "resolve_arguments(" lib/` and switch any other caller that
  resolves a step config's arguments (e.g. in `executor/async_step_dispatch.rb`).
- [X] T006 [P] In `lib/ruby_reactor/step_worker.rb`, replace `resolve_arguments(step_config, context)`
  with `step_config.resolve_arguments(context)` and delete the private method (~line 359).
- [X] T007 Add `StepConfig#call_compensate(error, arguments, context)` and
  `StepConfig#call_undo(result_value, arguments, context)` in `lib/ruby_reactor/dsl/step_builder.rb`,
  each wrapped in `catch(StepSignals::TAG)`. Dispatch order is identical to
  `CompensationManager#compensate_step`/`#undo_step` today:
  - inline block: `compensate_block.call(error, wrap_inputs(arguments), context)` /
    `undo_block.call(result_value, wrap_inputs(arguments), context)`
  - else `impl.compensate(error, arguments, context)` / `impl.undo(result_value, arguments, context)`
    when `has_impl?`
  - else `RubyReactor.Skipped()`
- [X] T008 Update `lib/ruby_reactor/executor/compensation_manager.rb`:
  - `compensate_step` and `undo_step` call `step_config.call_compensate` / `call_undo` inside the
    existing `coordinated_rollback` block. Trace, middleware and `record_rollback_failure` are
    unchanged.
  - Wrap `compensate_step`'s body in `@context.with_step(step_config.name) { … }`, as
    `rollback_completed_steps` already does for undo, so constructs can read `context.current_step`
    during compensate (R-02).
  - Add public `def compensate(step_config, error, arguments) = compensate_step(step_config, error, arguments)`.
    `StepWorker` uses it in US4.
- [X] T009 Run `bundle exec rspec` and `bundle exec rubocop`. Both must be green with **no spec
  edits**: the refactor changes no behavior.

**Checkpoint**: the foundation is ready and the user stories can proceed (in parallel if staffed).

---

## Phase 3: User Story 1 — Succeeded map elements are rolled back (Priority: P1) 🎯 MVP

**Goal**: a map rolls back every completed element, both when the map fails (compensate) and when
a later step fails or the run is undone manually (undo). This holds in inline and fan-out modes,
and a fail-fast fan-out settles before it rolls back (R-02, R-03, R-04; F-01, F-05).

**Independent Test**: `bundle exec rspec spec/ruby_reactor/rollback/map_rollback_spec.rb spec/ruby_reactor/rollback/map_fan_out_settle_spec.rb`.
The sequences must match RS §3 rows S-map-01/03/04/04b/06/07/08.

### Tests for User Story 1 ⚠️ write first, confirm they FAIL

- [X] T010 [P] [US1] Create `spec/ruby_reactor/rollback/map_rollback_spec.rb` (inline mode, using
  `RollbackRecorder`). Examples:
  - (a) S-map-01: fail-fast with element 2 failing gives exactly the RS §3 sequence, ending
    `undo:e.e2[1] undo:e.e1[1] undo:e.e2[0] undo:e.e1[0] undo:a`, and `failure.step_name == :m`.
  - (b) S-map-03: all elements ok and `b` fails. Every element is undone, highest index first,
    before `undo:a`.
  - (c) `fail_fast false`, element 2 fails, then `b` fails. Elements 0, 1 and 3 are undone.
    Element 2's steps appear exactly once in the undo sequence (its own self-rollback).
  - (d) A `collect` block that raises after all elements succeeded. Every element is undone
    (FR-007).
  - (e) S-map-07: map inside a compose.
  - (f) S-map-08: a compose inside the element. Nested steps unwind innermost-first.
  - (g) `Reactor.undo(result.execution_id)` after a completed map undoes every element. A second
    `Reactor.undo` records no new undo events (idempotent).
  - (h) An element step whose `undo` returns `Failure` for element 1 only. The final failure's
    `rollback_failures` contains an entry with `map_step: :m, element_index: 1`, and elements 0, 2
    and 3 are still undone (FR-005).
  - (i) Delete element 1's context row from storage between the map's success and `b`'s failure.
    An entry with `map_step: :m, reason: :context_unavailable` appears (its `element_index` is
    `nil`, since the index lives in the deleted row), and elements 0, 2 and 3 are still undone.
  - (j) An empty source succeeds, and a later failure raises no error from the map's undo.
  - (k) US1-8: an existing element reactor whose steps declare `undo` needs no map-level
    declaration for those undos to run.
- [X] T011 [P] [US1] Create `spec/ruby_reactor/rollback/map_fan_out_settle_spec.rb`
  (`for_each_async_backend`, `fan_out(true)`, drain). Examples:
  - (a) S-map-04: jobs drained in index order give the RS §3 sequence, and element 3 is skipped.
  - (b) S-map-04b: jobs performed in order 3, 2, 1, 0. Reorder the fake queue the same way
    `specs/007-execution-flow-analysis/evidence/harness.rb` does. Element 3 is undone and elements
    1 and 0 never run.
  - (c) S-map-06: all elements ok and `b` fails in the collector-resumed parent. Every element is
    undone, then `a` (R-03).
  - (d) SC-003: 100 iterations with `Random.new(seed)`-shuffled element job order. After each run,
    every element context with status `completed` has an empty `undo_stack`, and `RollbackRecorder`
    shows an `undo:` for every `run:` of a completed element.
  - (e) `batch_size 2` over 6 elements, element 1 fails. Indices 2–5 hold `{"_skipped"=>true}`
    slots, the map counter is `0`, and the collector resolves the failure exactly once.
  - (f) After (e), `RubyReactor::Map::Sweeper.run_once` returns `redispatched: 0`.
  - (g) Hold `RubyReactor::Lock.new("map_element:<map_id>:0", owner: "x", ttl: 30, wait: 0)`
    while the map rollback runs. The result has `reason: :element_in_flight, element_index: 0`, and
    the other elements are undone.
- [X] T012 [P] [US1] Create `spec/ruby_reactor/rollback/map_scale_spec.rb`, tagged `:slow`
  (SC-006). An inline map over 10,000 trivial elements whose `collect` raises: all 10,000 elements
  are undone, there is no `ContextTooLargeError`, and the parent's serialized context size is
  within 2× of the same reactor with 10 elements.

### Implementation for User Story 1

- [X] T013 [US1] Implement map rollback in `lib/ruby_reactor/step/map_step.rb` (R-02, DM §5–§6):
  - Replace the stub with `def compensate` and add `alias undo compensate`.
  - `step_name = context.current_step`; `map_id = "#{context.context_id}:#{step_name}"`.
  - Element class: `context.reactor_class.steps[step_name].arguments[:mapped_reactor_class][:source].value`.
  - Ids: `storage.retrieve_map_element_context_ids(map_id, context.reactor_class.name).uniq`.
  - For each id, load `storage.retrieve_context(id, RubyReactor.reactor_storage_name(element_class))`:
    - missing → a
      `{ step: step_name, kind: :undo, reason: :context_unavailable, map_step: step_name, element_index: nil, message: "element context #{id} expired" }`
      entry. The index is stored only in the row itself.
    - otherwise `Context.deserialize_from_retry`, and keep it only when `status.to_s == "completed"`.
  - Sort the kept elements by `map_metadata[:index]` (string or symbol key) descending.
  - Per element:
    - Acquire `RubyReactor::Lock.new("map_element:#{map_id}:#{index}", owner: SecureRandom.uuid, ttl: RubyReactor.configuration.context_lock_ttl, wait: 0)`.
      Skip the lock when `Map::ElementExecutor.inline_testing_mode?`. On
      `Lock::AcquisitionError`, record `reason: :element_in_flight`.
    - Otherwise run `ex = Executor.new(element_class, {}, element_ctx); ex.undo_all; ex.save_context`,
      then tag each of `ex.compensation_manager.rollback_failures` with `map_step: step_name, element_index: index`.
    - Release the lock in `ensure`.
  - Return `RubyReactor.Success()` when no entries were collected, else
    `RubyReactor.Failure("map :#{step_name} rollback incomplete", rollback_failures: entries)`, the
    same shape as `ComposeStep#compensate`.
  - Mark the serial loop with a `# ponytail:` comment naming its ceiling (linear in the number of
    elements) and the upgrade path (rollback fan-out).
- [X] T014 [US1] In `lib/ruby_reactor/map/helpers.rb` `resume_parent_execution`, success branch:
  before `resume_parked_aware`, push
  `{ step: parent_context.reactor_class.steps[step_name_sym], arguments: {}, result: RubyReactor.Success(nil) }`
  onto `parent_context.undo_stack` (R-03, DM §4). Add a comment on why the record is empty:
  `MapStep#undo` reads the element index, and the record stays constant-size.
- [X] T015 [P] [US1] Add `decrement_map_counter_by(map_id, amount, reactor_class_name)` to
  `lib/ruby_reactor/storage/redis_adapter.rb`: `DECRBY` on `map_counter_key`, refresh
  `durability_ttl`, return the new value.
- [X] T016 [US1] In `lib/ruby_reactor/map/element_executor.rb` `check_fail_fast?`, before
  `finalize_execution`, write `storage.store_map_result(map_id, arguments[:index], { "_skipped" => true }, parent_reactor_class_name, strict_ordering: arguments[:strict_ordering])`
  (R-04 §1).
- [X] T017 [US1] In `lib/ruby_reactor/map/dispatcher.rb` `dispatch_batch`, fail-fast branch
  (~line 69). When the failed-context marker is set, do not simply `return`:
  - Read the total from `storage.retrieve_map_metadata(map_id, reactor_class_name)["count"]`.
  - Claim the rest with `new_offset = storage.increment_map_offset(map_id, total, reactor_class_name)`,
    so `claimed = (new_offset - total)...[new_offset, total].min` is empty for a later dispatcher.
  - Write a `_skipped` slot for each claimed index.
  - `left = storage.decrement_map_counter_by(map_id, claimed.size, reactor_class_name)` if any were
    claimed.
  - If `left <= 0`, enqueue `perform_map_collection_async` with the same arguments
    `ElementExecutor.finalize_execution` uses.
  - Depends on T015.
- [X] T018 [US1] In `lib/ruby_reactor/map/collector.rb` `perform_collection`, compute
  `results_count` before the fail-fast branch and change it to
  `if (failed_context_id = …) then return if results_count < total_count; handle_failure(…); return; end`
  (R-04 §2). Comment: the failure is applied only once every index has settled, so the map's
  compensate sees every completed element.
- [X] T019 [P] [US1] In `lib/ruby_reactor/map/result_enumerator.rb`, make `each` (and therefore
  `successes`/`failures`/`count` if derived from it) skip slots that are
  `Hash` with key `"_skipped"`, and make `[](index)` return `nil` for one. Add examples to the
  existing enumerator spec (`grep -rln ResultEnumerator spec/`).
- [X] T020 [US1] Run the new specs plus `spec/map/`, `spec/ruby_reactor/map/`,
  `spec/single_worker_map_spec.rb` and `spec/compose_spec.rb`. Fix only expectations that asserted
  element effects stay in place, and add a comment on each changed expectation citing F-01.

### Documentation & demo for User Story 1

- [X] T021 [P] [US1] Update `documentation/data_pipelines.md` (~line 167 and the fail-fast section):
  - Completed elements are rolled back when the map fails and when a later step fails, by replaying
    each element's own step `undo`s, highest index first.
  - Fail-fast fan-out waits for elements in flight before it reports failure.
  - `context_ttl` is the rollback horizon (`context_unavailable`).
  - Element `undo`s should be idempotent.
  - `fail_fast false`: failed elements roll back individually, successes are undone on a later
    failure.
- [X] T022 [US1] Update `README.md`:
  - Map and Compensation sections, lines ~1309 and ~1398: add maps to "undoes completed steps", and
    list the new `rollback_failures` keys `map_step`/`element_index` and the reasons
    `context_unavailable`/`element_in_flight`.
  - Map example text: no map-level rollback DSL is needed.
- [X] T023 [P] [US1] Add to `CHANGELOG.md` under Unreleased → Features (BREAKING): "map rolls back
  completed elements". Include a migration note: element-step `undo` blocks now run on map failure
  and on later failures, so make them idempotent.
- [X] T024 [P] [US1] Create `demo_app/app/reactors/map_refund_demo_reactor.rb`. It contains:
  - `MapRefundChargeStep < RubyReactor::Step`, whose `run` charges and whose `undo` refunds. Both
    append to a class-level `charges`/`refunds` Array with `reset!`. It fails for a configured
    `fail_order_id`.
  - An element reactor (`MapRefundElementReactor`).
  - `MapRefundDemoReactor`, with inputs `orders` and an optional `fail_after_map` flag that makes a
    final `notify` step fail.
- [X] T025 [US1] Add `demo:map_rollback` to `demo_app/lib/tasks/demo_reactors.rake` (`desc` plus
  `[:environment, :flush_redis]`). It runs both scenarios (an element fails; the step after the map
  fails) and prints charges and refunds.
- [X] T026 [P] [US1] Create `demo_app/spec/reactors/map_refund_demo_reactor_spec.rb`
  (`type: :reactor`, `test_reactor`, `be_failure`, `have_rollback_failure`). It asserts the refunds
  match the charges in both scenarios. Use only `lib/ruby_reactor/rspec.rb` helpers.

**Checkpoint**: US1 is complete and independently testable. This is the MVP.

---

## Phase 4: User Story 2 — A retried composed reactor re-runs rolled-back work (Priority: P1)

**Goal**: a compose retry after a failed attempt starts a fresh child, while a park/resume still
resumes (R-05, F-02, DM §7).

**Independent Test**: `bundle exec rspec spec/ruby_reactor/rollback/compose_retry_spec.rb`, matching
RS §3 rows S-compose-05 and 05b.

### Tests for User Story 2 ⚠️ write first, confirm they FAIL

- [X] T027 [P] [US2] Create `spec/ruby_reactor/rollback/compose_retry_spec.rb`. Examples:
  - (a) S-compose-05: `compose :child` with `retries max_attempts: 2`, where child `c2` fails on the
    first attempt only, gives `… retry … run:child.c1 run:child.c2`. The result value is from
    attempt 2.
  - (b) S-compose-05b: the same, plus a parent step `b` that fails, gives
    `… run:b compensate:b undo:child.c2 undo:child.c1`.
  - (c) The child's inner step `c2` declares `retries max_attempts: 2` and fails twice per compose
    attempt. It is attempted twice in **each** compose attempt (the retry budget resets with the
    fresh child).
  - (d) The parent `execution_trace` has one `type: :compose_attempt_discarded` entry with
    `step: :child` and the old `child_context_id`. When attempt 1's `c1` undo returns `Failure`,
    that entry's `rollback_failures` lists it (DM §7).
  - (e) Worker path: `background all: true`, drain. The retry requeue still re-runs `c1`.
  - (f) Park is not retry: model on `spec/ruby_reactor/step_coordination/park_spec.rb` ("a parent
    lock across a composed park (R4)"). A child that parks on contention after `c1` completed
    resumes without logging a second `run:child.c1`.

### Implementation for User Story 2

- [X] T028 [US2] In `lib/ruby_reactor/step/compose_step.rb` `run`, right after reading
  `composed_data`:
  - If `composed_data&.dig(:context)&.status.to_s == "failed"`, append
    `{ type: :compose_attempt_discarded, step: step_name, child_context_id: old.context_id, rollback_failures: (old.failure_reason.respond_to?(:rollback_failures) ? old.failure_reason.rollback_failures : []), timestamp: Time.now }`
    to `context.execution_trace`, and set `composed_data = nil`. `prepare_child_context` then builds
    a fresh child, and `execute_child_reactor` calls `execute`, not resume.
  - Add a comment explaining why a failed child is a previous attempt (it already rolled itself
    back), while any other status is a park/resume (FR-011).
- [X] T029 [US2] Run `spec/compose_spec.rb`, `spec/nested_reactor_inline_execution_spec.rb`,
  `spec/ruby_reactor/step_coordination/park_spec.rb` and
  `spec/ruby_reactor/step_coordination/rollback_under_contention_spec.rb`. All must be green.

### Documentation & demo for User Story 2

- [X] T030 [P] [US2] Update `documentation/composition.md` (~line 184 and the Compensation table
  ~195): `retries` on a compose retry the **whole** child from a fresh start, child steps without
  `undo` run again, and the discarded attempt stays visible in the trace.
- [X] T031 [P] [US2] Add to `CHANGELOG.md` under Bug Fixes: "compose retries re-run the whole child
  instead of resuming a rolled-back one". Note that child steps without `undo` now run again on
  retry.
- [X] T032 [P] [US2] Create `demo_app/app/reactors/compose_retry_demo_reactor.rb`. A child reactor
  runs `reserve` (with `undo`) and then `confirm`, which fails on the first call only (a class-level
  counter with `reset!`). The parent composes it with `retries max_attempts: 2`.
- [X] T033 [US2] Add `demo:compose_retry` to `demo_app/lib/tasks/demo_reactors.rake`. It prints that
  `reserve` ran twice and the final result.
- [X] T034 [P] [US2] Create `demo_app/spec/reactors/compose_retry_demo_reactor_spec.rb`
  (`test_reactor`, `be_success`, `have_run_step`/`have_retried_step`). It asserts `reserve` ran on
  both attempts.

**Checkpoint**: US2 works independently of US1.

---

## Phase 5: User Story 3 — Every failure after completed work rolls back (Priority: P1)

**Goal**:

- Argument-resolution and condition errors become attributed never-started failures.
- Unknown standard errors roll back.
- Failures from a compensation that failed carry the step name.
- Process-level exceptions mark an inline run `aborted`.

(R-06, R-07, R-08; F-03, F-06, F-13; DM §2, §3, §9; API §2–§4)

**Independent Test**: `bundle exec rspec spec/ruby_reactor/rollback/failure_rollback_spec.rb spec/ruby_reactor/rollback/aborted_execution_spec.rb`,
matching RS §3 rows S-plain-07, S-edge-03 and S-edge-04.

### Tests for User Story 3 ⚠️ write first, confirm they FAIL

- [X] T035 [P] [US3] Create `spec/ruby_reactor/rollback/failure_rollback_spec.rb`. Examples:
  - (a) S-plain-07: `b`'s argument `transform:` raises `ArgumentError`. The sequence is
    `run:a undo:a`, with `failure.step_name == :b`, `failure.reactor_name` set,
    `failure.exception_class == "ArgumentError"`, and no `compensate:b`.
  - (b) The same when `b`'s argument source is `result(:a, path)` and the path raises.
  - (c) S-edge-04: `where` raises. The sequence is `run:a undo:a`, with no `compensate:b`.
  - (d) The same for `guard`.
  - (e) `b` has `retries max_attempts: 3` and its `where` raises. It is attempted once (not
    retried).
  - (f) A middleware whose `complete_step` hook raises `RuntimeError` for step `a` (a StandardError
    outside any body). Completed steps are undone and the failure has `reactor_name` (FR-016).
  - (g) `b` fails and its `compensate` raises. `failure.step_name == :b` (CompensationError
    attribution, FR-017).
  - (h) Worker path: `background before: :b`, where `b`'s transform raises, then drain. `undo:a`
    is logged and the failure is attributed to `b`.
  - (i) An `async_step :u` whose argument transform raises, then drain. The unit record's
    failure has `step_name: :u` and `retryable: false`, and its `compensate` block was not called.
- [X] T036 [P] [US3] Create `spec/ruby_reactor/rollback/aborted_execution_spec.rb` with
  `class AbortCrash < Exception; end`. Examples:
  - (a) S-edge-03: `a → b` where `b` raises `AbortCrash`. `Reactor.run` re-raises the **same**
    object (`raise_error(AbortCrash) { |e| expect(e).to equal(crash) }`), and no `undo:a` is logged.
  - (b) The stored context (`storage.retrieve_context`) has status `"aborted"` and a non-empty
    `undo_stack`.
  - (c) `RubyReactor::Sweeper.run_once` enqueues nothing for it.
  - (d) `RubyReactor::Reactor.undo(id)` (via the reactor class) logs `undo:a` and the status
    becomes `"cancelled"`.
  - (e) A composed child raising `AbortCrash` marks both the child and the root `aborted`.
  - (f) An executor whose context has `inline_async_execution = true` leaves the status `running`
    (the worker path is unchanged).
  - (g) `RubyReactor::Worker` given an aborted context id does not resume it.

### Implementation for User Story 3

- [X] T037 [P] [US3] Create `lib/ruby_reactor/error/argument_resolution_error.rb`: `class ArgumentResolutionError < Base`
  with `attr_reader :exception_class`,
  `initialize(message, step:, original_error:, context: nil)` setting
  `@exception_class = original_error.class.name`, and `def retryable? = false` (DM §2).
- [X] T038 [P] [US3] Create `lib/ruby_reactor/error/condition_error.rb`: `class ConditionError < Base`,
  with the same shape as T037.
- [X] T039 [US3] In `lib/ruby_reactor/dsl/step_builder.rb`:
  - `resolve_arguments` rescues `Error::ExecutionParked` (re-raise unchanged). Any other
    `StandardError => e` raises
    `Error::ArgumentResolutionError.new("Step '#{name}' could not resolve its arguments: #{e.message}", step: name, original_error: e)`,
    with `set_backtrace(e.backtrace)`.
  - `should_run?` wraps a raising condition or guard the same way into `Error::ConditionError`.
- [X] T040 [US3] In `lib/ruby_reactor/executor/compensation_manager.rb`, add
  `RubyReactor::Error::ArgumentResolutionError` and `RubyReactor::Error::ConditionError` to
  `NEVER_STARTED_ERROR_CLASSES`, and update the constant's comment.
- [X] T041 [US3] In `lib/ruby_reactor/executor/step_executor.rb`:
  - `execute_step`: move argument resolution inside the existing `begin` so `:start_step`
    (with `{}`) and `:failed_step` fire. On `Error::ArgumentResolutionError => e`, return
    `@result_handler.handle_step_result(step_config, RubyReactor::Failure(e, step_name: step_config.name, reactor_name: @reactor_class.name, inputs: @context.inputs, redact_inputs: <same as safe_execute_step_sync>, step_arguments: {}, retryable: false, exception_class: e.exception_class), {})`.
  - `safe_execute_step_sync`: add
    `rescue Error::ArgumentResolutionError, Error::ConditionError => e` **before**
    `rescue StandardError`, building the same `Failure(…, retryable: false, exception_class: e.exception_class)`.
    `RetryManager` then does not retry it, and `handle_step_failure` sees a never-started error.
- [X] T042 [US3] In `lib/ruby_reactor/executor/result_handler.rb` `build_execution_failure`:
  - The `Error::Base` branch adds `step_name: error.step` and
    `reactor_name: @context.reactor_class&.name`.
  - The `else` branch calls `@compensation_manager.rollback_completed_steps`, returns
    `RubyReactor.Failure("Execution failed: #{error.message}", exception_class: error.class.name, step_name: @context.current_step, reactor_name: @context.reactor_class&.name)`,
    and replaces the "don't rollback" comment with the R-07 rationale.
  - `CompensationError` gets `step_name` through the `Error::Base` branch.
- [X] T043 [US3] In `lib/ruby_reactor/step_worker.rb` `perform_unit`: add
  `rescue Error::ArgumentResolutionError, Error::ConditionError => e` before `rescue StandardError`.
  Log `failed`, then `complete(RubyReactor.Failure(e, step_name: @step_name, reactor_name: @reactor_class_name, retryable: false, exception_class: e.exception_class), context)`.
- [X] T044 [US3] In `lib/ruby_reactor/executor.rb`, in both `execute` and `resume_execution`, add
  after `rescue StandardError`:
  `rescue Exception # rubocop:disable Lint/RescueException` →
  `@context.status = :aborted unless @context.inline_async_execution; raise`.
  Comment it with R-08: no rollback code runs on process-level exceptions, the caller-process run
  is recorded as aborted for a manual undo, and a worker run is redelivered. The existing `ensure`
  persists it.
- [X] T045 [P] [US3] Add `"aborted"` to `TERMINAL_STATUSES` in `lib/ruby_reactor/worker.rb`, so a
  worker never resumes an aborted run forward.
- [X] T046 [P] [US3] Add `aborted` to the known-status lists in
  `lib/ruby_reactor/storage/redis_reactor_scan.rb` (`determine_status`, ~line 70) and
  `lib/ruby_reactor/web/api.rb` (~line 176).
- [X] T047 [P] [US3] Dashboard, in `gui/src/lib/reactors.ts`:
  - Add `'aborted'` to the `errors` status group.
  - `gui/src/components/StatusBadge.tsx`: add an `aborted` style and icon, distinct from `failed`.
  - `gui/src/components/ReactorClassInstances.tsx`: add `<option value="aborted">Aborted</option>`.
  - Add a case to `gui/src/lib/__tests__/reactors.test.ts`.
  - Run `npm --prefix gui test`, then `bundle exec rake build:ui` to refresh
    `lib/ruby_reactor/web/public/`.
- [X] T048 [US3] Run the US3 specs, then `spec/ruby_reactor/error_handling_spec.rb`,
  `failure_reporting_spec.rb`, `compensation_failure_spec.rb`, `validations_spec.rb`,
  `sweeper_spec.rb` and `undo_spec.rb`. Update only expectations that pinned the old unattributed
  or no-rollback shapes, with a comment citing F-03/F-13.

### Documentation & demo for User Story 3

- [X] T049 [P] [US3] Update `documentation/locks_and_semaphores.md` (~777-778) so the never-started
  list includes argument-resolution and condition errors. Update `documentation/interrupts.md`
  (~155-157) to describe the `aborted` status and that `Reactor.undo(id)` rolls an aborted run back.
- [X] T050 [US3] Update `README.md` lines ~16 and ~25 (the compensation promise): every standard
  error after completed work rolls back, and a process-level exception marks the run `aborted` for
  a manual undo. Document the `ArgumentResolutionError`/`ConditionError` classes in the errors
  section.
- [X] T051 [P] [US3] Add to `CHANGELOG.md`:
  - Bug Fixes: argument, condition and unknown errors roll back and carry `step_name`; a
    compensation failure carries `step_name`.
  - Features: the `aborted` status.
- [X] T052 [P] [US3] Create `demo_app/app/reactors/argument_failure_demo_reactor.rb`: `reserve`
  (with `undo`) then `charge`, whose argument `transform:` raises for a configured input.
- [X] T053 [US3] Add `demo:failure_rollback` to `demo_app/lib/tasks/demo_reactors.rake`. It prints
  the undo and the failure's `step_name`.
- [X] T054 [P] [US3] Create `demo_app/spec/reactors/argument_failure_demo_reactor_spec.rb`
  (`test_reactor`, `be_failure`). It asserts that `reserve` was undone and that the failure names
  `charge`.

**Checkpoint**: US3 works independently.

---

## Phase 6: User Story 4 — An async step's rollback hooks run as declared (Priority: P2)

**Goal**:

- A unit compensates itself once, in its own job, after its final attempt fails.
- An inline `undo` on `async_step` is rejected.
- A class `undo` is warned about.

(R-09; F-04; DM §8; API §1, §5, §6)

**Independent Test**: `bundle exec rspec spec/ruby_reactor/rollback/async_step_compensate_spec.rb spec/ruby_reactor/dsl/async_step_spec.rb`,
matching RS §3 rows S-async-02 and S-async-07.

### Tests for User Story 4 ⚠️ write first, confirm they FAIL

- [X] T055 [P] [US4] Create `spec/ruby_reactor/rollback/async_step_compensate_spec.rb`
  (`for_each_async_backend`, drain). Examples:
  - (a) S-async-07: `async_step :u` with `retries max_attempts: 3`, always failing, no reader.
    The sequence is `run:u ×3 compensate:u`, `compensate:u` is logged exactly once, and the unit
    record has `compensation.status == "completed"`.
  - (b) Fails once then succeeds: no `compensate:u` and no `compensation` key.
  - (c) S-async-02: reader `r` returns `Failure`. The sequence contains `compensate:u` once,
    `compensate:r` and `undo:a`.
  - (d) Invalid arguments (`validate_args`) or a raising transform: no `compensate:u`.
  - (e) The body returns `Halt`: no compensate.
  - (f) `compensate` raises. The record has `compensation.status == "failed"` with one
    `rollback_failures` entry, and the unit record's `result` is still the body failure.
  - (g) The step class declares `with_lock`. The compensate re-takes the unit's lock (assert via a
    `lock_acquired` middleware event during compensation).
  - (h) The parent context is not written by the unit job. Mirror the assertion style in
    `spec/ruby_reactor/async_step_single_writer_spec.rb`.
  - (i) Middleware `start_compensation`/`complete_compensation` fire with step name `:u`.
  - (j) Definition time:
    - `Class.new(RubyReactor::Reactor) { async_step(:u) { run { … }; undo { … } } }` raises
      `RubyReactor::Error::ValidationError`, with a message matching `/async_step :u/` and
      `/compensate/`.
    - A step class overriding `undo` used as `async_step :u, ThatClass` warns once to stderr
      (`expect { … }.to output(/undo.*will not run/).to_stderr`) and does not raise.
- [X] T056 [US4] Tighten `spec/ruby_reactor/dsl/async_step_spec.rb` (~line 111, "compensates when a
  reader inspects the failure"). Add a `compensate` to the fixture's async step that records into
  the fixture log, and assert it ran exactly once.

### Implementation for User Story 4

- [X] T057 [US4] In `lib/ruby_reactor/step_worker.rb` `run_step`, after the retry loop:
  - When `result.is_a?(RubyReactor::Failure)` and the error is neither an
    `Error::InputValidationError` nor in
    `Executor::CompensationManager::NEVER_STARTED_ERROR_CLASSES`, compensate the unit:
    ```ruby
    manager = Executor::CompensationManager.new(context)
    outcome = context.with_step(@step_name) { manager.compensate(step_config, result.error, arguments) }
    ```
  - Set
    `@compensation = { "status" => (outcome.is_a?(RubyReactor::Failure) ? "failed" : (outcome.respond_to?(:skipped?) && outcome.skipped? ? "skipped" : "completed")), "rollback_failures" => ContextSerializer.serialize_value(manager.rollback_failures), "completed_at" => Time.now.iso8601 }`.
  - Merge `"compensation" => @compensation` into the record in `complete` when it is set (via
    `run_fields` or next to it).
  - Never call `save_context`/`store_context` for the parent. Comment it with the single-writer
    rule.
- [X] T058 [US4] In `lib/ruby_reactor/dsl/step_builder.rb`, extract the dedupe/print part of
  `warn_deprecation` into `warn_definition(site, message)`. It prints
  `"[RubyReactor] #{location} #{reactor_label} #{message}"` once per location, using
  `StepBuilder.deprecation_sites`. `warn_deprecation` keeps its exact current output by calling it
  with its DEPRECATION prefix and suffix.
- [X] T059 [US4] In `lib/ruby_reactor/dsl/async_macros.rb` `async_step`, after `builder.build`:
  - If `config.undo_block`, raise `RubyReactor::Error::ValidationError` with: "`undo` on async_step
    :#{name} would never run: the parent never undoes an independent async unit. Put
    failure cleanup in the reading step's `compensate`, or use a `step`/`compose`/`map` (tracked
    for undo) or an `async_reactor` child whose steps declare `undo`." Use the wording from API §1.
  - Elsif `impl.is_a?(Class) && impl < RubyReactor::Step && impl.instance_method(:undo).owner != RubyReactor::Step`,
    call `builder.send(:warn_definition, caller_locations(1, 1).first, "async_step :#{name} uses #{impl}; its `undo` will not run for this async use (async units are never undone).")`.
- [X] T060 [US4] Grep `spec/` and `demo_app/` for `async_step` blocks that declare `undo`
  (`grep -rn -A15 "async_step" spec demo_app/app | grep -n "undo"`). Remove or move them so the
  suite loads. Then run `spec/ruby_reactor/dsl/async_step_spec.rb`,
  `spec/ruby_reactor/async_step_single_writer_spec.rb`, `spec/ruby_reactor/step_contract_async_spec.rb`,
  `spec/async_retry_dsl_spec.rb` and `spec/async_retry_integration_spec.rb`. All must be green.

### Documentation & demo for User Story 4

- [X] T061 [P] [US4] Update `documentation/background_and_async.md` (~279-292):
  - The unit's `compensate` runs once in its own job after its final attempt, whether or not it is
    read.
  - `undo` is rejected (inline) or warned (class).
  - A reader surfacing the failure compensates itself and undoes the parent, and never compensates
    the unit twice.
- [X] T062 [US4] Update `README.md` ~545-550 (the async_step compensation paragraph) to match T061.
- [X] T063 [P] [US4] Add to `CHANGELOG.md` two BREAKING entries with migration notes (R-12 rows 2–3):
  "`async_step` `compensate` runs in the unit's job on final failure", and "inline `undo` in
  `async_step` raises at definition time".
- [X] T064 [P] [US4] Create `demo_app/app/reactors/async_step_compensate_demo_reactor.rb`: an
  `async_step :notify` whose body always fails, with `retries max_attempts: 2` and a `compensate`
  that records to a class-level log. Remove any inline `undo` from
  `demo_app/app/reactors/async_step_demo_reactor.rb` if T060 found one.
- [X] T065 [US4] Add `demo:async_step_compensate` to `demo_app/lib/tasks/demo_reactors.rake`. It
  drains or waits for the unit, then prints the unit record's `compensation`.
- [X] T066 [P] [US4] Create `demo_app/spec/reactors/async_step_compensate_demo_reactor_spec.rb`.
  If no shipped matcher can assert the unit's compensation:
  - Add `have_compensated_async_step(step_name)` to `lib/ruby_reactor/rspec/matchers.rb`. It reads
    `retrieve_step_result(...)["compensation"]["status"] == "completed"`, with a
    `.because_failed` chain for `"failed"`.
  - Add an example for the matcher in `spec/ruby_reactor/rspec/`.
  - Never hand-roll storage reads in the demo spec (Constitution VI).

**Checkpoint**: US4 works independently.

---

## Phase 7: User Story 5 — One rollback rule for every construct (Priority: P3)

**Goal**:

- The coordinator asks the step whether a success is tracked for undo.
- The F-10 table, the 007 analysis and the core docs describe one rule plus a per-construct table.
- The 007 harness confirms that only the intended sequences changed.

(R-10; FR-022, FR-023; SC-002, SC-007, SC-008)

**Independent Test**: `bundle exec rspec spec/ruby_reactor/rollback/rollback_rule_spec.rb`, plus the
007 harness printing `63 scenarios, 63 match, 0 mismatch`.

### Tests for User Story 5 ⚠️ write first, confirm they FAIL

- [X] T067 [P] [US5] Create `spec/ruby_reactor/rollback/rollback_rule_spec.rb`:
  - `rollback_tracked?` is `true` for `step`, `compose`, `map` and `interrupt` configs, and
    `false` for `async_step` and `async_reactor` configs. This fails until T068.
  - A reactor `a → async_reactor child → b(fails)` still never undoes the child (INV-25 unchanged).

### Implementation for User Story 5

- [X] T068 [US5] Add `def rollback_tracked? = !async_dispatch?` to `StepConfig` in
  `lib/ruby_reactor/dsl/step_builder.rb`. In `lib/ruby_reactor/executor/result_handler.rb`
  `handle_success`, push only `if step_config.rollback_tracked?`. Delete `async_unit?` and move its
  comment onto `rollback_tracked?`. Confirm `RubyReactor::Dsl::AsyncReactorBuilder#build` produces a
  `StepConfig` with `async_dispatch` set.
- [X] T069 [US5] Update the `expected:` sequences of exactly the 14 scenarios in RS §3 in
  `specs/007-execution-flow-analysis/evidence/probes/`: `01_plain.rb` (S-plain-07), `02_compose.rb`
  (S-compose-05, 05b), `03_map.rb` (S-map-01, 03, 04, 04b, 06, 07, 08), `04_async.rb`
  (S-async-02, 07) and `07_interrupts_manual.rb` (S-edge-03, 04).
  - For S-edge-03, add a `note:` printing the stored status (`aborted`).
  - Re-run
    `bundle exec ruby specs/007-execution-flow-analysis/evidence/run.rb | tee specs/007-execution-flow-analysis/evidence/output.txt`
    and require `63 scenarios, 63 match, 0 mismatch`.
  - Depends on US1–US4.
- [X] T070 [US5] Update `specs/007-execution-flow-analysis/analysis/execution-order.md`:
  - §1 failure-kinds table rows (argument, condition and unknown errors; non-`StandardError` →
    `aborted`).
  - Rule R7 text.
  - §2 construct lifecycles for map (compensate and undo replay, settle), compose (fresh child on
    retry) and async_step (unit-local compensate).
  - Add the R-05 resume-entry-point audit table.
  - Mark changed rows "changed in 008".
- [X] T071 [P] [US5] Update `specs/007-execution-flow-analysis/analysis/invariants.md` and
  `specs/007-execution-flow-analysis/analysis/findings-and-options.md`:
  - `invariants.md`: INV-06, 07, 13, 19, 20, 22 and 24 become HOLDS with 008 spec coverage cited.
    INV-22 is restated per R-04 (left-in-place set).
  - `findings-and-options.md`: add a "Resolved by 008" line to F-01..F-06 and F-13, and rebuild
    the F-10 table from RS §2.
- [X] T072 [US5] Update `documentation/core_concepts.md` (~321-331):
  - Add "The rollback rule" (RS §1) and the per-construct table (RS §2).
  - `README.md` line ~35: change "Auto compensation/undo" to cover all constructs, with async units
    independent by design.
  - `documentation/DAG.md` (~228-240): cascading compensation now includes maps.

**Checkpoint**: all stories are complete, and the docs describe one rule.

---

## Phase 8: Polish & Cross-Cutting Concerns

- [X] T073 Add an aggregate `demo:rollback_reliability` task to
  `demo_app/lib/tasks/demo_reactors.rake`. It depends on `:map_rollback`, `:compose_retry`,
  `:failure_rollback` and `:async_step_compensate`. Add `:rollback_reliability` to the `demo:all`
  prerequisite list.
- [X] T074 [P] Add a note to `specs/future_improvements.md`: the reactor `Sweeper` re-enqueues
  **in-progress** inline runs (status `running`, no `async:` lock). This is pre-existing, and 008
  only excludes `aborted` runs. Also note a possible later map-level `undo_all` override and a
  rollback fan-out for very large maps (R-02 alternatives).
- [X] T075 Documentation consistency pass (REQUIRED, Constitution Development Workflow). Check every
  row of the 007 documentation audit (`findings-and-options.md` §2) tied to F-01..F-06 or F-13
  against the new behavior:
  - README.md 16, 25, 35, 545-550, 1309, 1398
  - data_pipelines.md 167
  - composition.md 184, 195
  - background_and_async.md 279-292
  - core_concepts.md 321-331
  - DAG.md 228-240
  - locks_and_semaphores.md 777-778
  - interrupts.md 155-157

  Each must now read CONFIRMED (SC-007). Fix any stragglers.
- [X] T076 Consolidate the CHANGELOG. `CHANGELOG.md` Unreleased has one "Migration notes" block
  listing every R-12 breaking row, with a before/after snippet for each.
- [X] T077 Run `bundle exec rubocop` and `bundle exec rspec` (full suite, alone), then
  `bundle exec rspec spec/ruby_reactor/rollback --tag slow` (SC-006, SC-009).
- [X] T078 Docker demo acceptance per [quickstart.md](quickstart.md) §5, using an isolated compose
  project (`-p rr_rollback` plus an override with unique `container_name`s and
  `ports: !reset []`). Run `bin/rails demo:rollback_reliability` and
  `bundle exec rspec spec/reactors/map_refund_demo_reactor_spec.rb spec/reactors/compose_retry_demo_reactor_spec.rb spec/reactors/argument_failure_demo_reactor_spec.rb spec/reactors/async_step_compensate_demo_reactor_spec.rb`,
  then the whole demo spec suite (existing map and async demos may change behavior).
- [X] T079 Run [quickstart.md](quickstart.md) §1–§6 end to end and record the results
  (SC-001..SC-009) in the PR description.

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (T001–T003)**: none.
- **Foundational (T004–T009)**: after Setup. **Blocks every story.**
- **US1, US2, US3, US4**: each depends only on Foundational, so they can run in parallel.
- **US5**: T067/T068 depend only on Foundational. T069–T072 depend on US1–US4 (the harness and
  docs describe their final behavior).
- **Polish (T073–T079)**: after all stories.

### Shared-file ordering (tasks without [P] across stories)

These files are edited by more than one story. Serialize the edits in story order, or rebase before
editing:

- `README.md`: T022, T050, T062, T072, T075
- `CHANGELOG.md`: T023, T031, T051, T063, T076
- `demo_app/lib/tasks/demo_reactors.rake`: T025, T033, T053, T065, T073
- `lib/ruby_reactor/dsl/step_builder.rb`: T004, T007, T039, T058, T068
- `lib/ruby_reactor/step_worker.rb`: T006, T043, T057
- `lib/ruby_reactor/executor/compensation_manager.rb`: T008, T040
- `lib/ruby_reactor/executor/result_handler.rb`: T042, T068

### Within each story

The spec tasks (FAIL first) come before the implementation, then a green run of the story's specs,
then docs, demo and CHANGELOG. The story is not done until its docs and demo land (Constitution
Development Workflow and VI).

### Story independence

- **US1**: needs only T008 (compensate runs under `with_step`).
- **US2**: needs no other story.
- **US3**: US4's T057 treats a never-started error as not compensated. Without US3's classes, a
  worker-side resolution error still never reaches the compensate call, because it raises before
  the body.
- **US4**: independent of US3.
- **US5**: T068 is independent. Its doc and harness tasks come last.

---

## Parallel Examples

```text
# After Phase 2, write the failing specs of all P1 stories together:
T010 map_rollback_spec.rb   T011 map_fan_out_settle_spec.rb   T012 map_scale_spec.rb
T027 compose_retry_spec.rb  T035 failure_rollback_spec.rb     T036 aborted_execution_spec.rb

# US1 implementation: independent files in parallel
T015 redis_adapter.rb   T019 result_enumerator.rb   (then T013/T014/T016/T017/T018)

# US3 implementation: new files and status lists in parallel
T037 argument_resolution_error.rb   T038 condition_error.rb   T045 worker.rb   T046 scan/api   T047 gui

# Demo artifacts per story ([P]): reactor + spec in parallel, rake task after
T024 + T026 → T025
```

---

## Implementation Strategy

### MVP (US1 only)

1. Phase 1 → Phase 2 (T009 green, no behavior change).
2. Phase 3 (US1): map rollback in both modes, plus its docs and demo.
3. **Stop and validate**: quickstart §1 for the map specs, plus demo `demo:map_rollback`. This
   closes the widest gap (F-01, F-05).

### Incremental delivery

After the MVP, in order. Each step is one PR-sized increment with its own docs, demo and CHANGELOG:

1. US3 (failures): the smallest change. It gives every later failure its attribution.
2. US2 (compose retry).
3. US4 (async_step).
4. US5 (one rule, harness and 007 docs refresh).
5. Polish.

### Commits

- Breaking items use `feat!`/`fix!` with a `BREAKING CHANGE:` footer (R-12): T013/T014 (map), T057
  (async compensate) and T059 (inline `undo` rejected).
- Everything else uses `feat:`/`fix:`/`docs:`/`test:`/`refactor:` (Phase 2 is `refactor:`).
