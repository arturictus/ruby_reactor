---

description: "Task list for Background Execution & Real Async Steps"
---

# Tasks: Background Execution & Real Async Steps

**Input**: Design documents from `/specs/001-background-async-steps/`

**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/public-dsl.md, quickstart.md

**Tests**: Test tasks ARE included and are written first. Two reasons: the project constitution makes RSpec Red-Green-Refactor non-negotiable (Principle III, against real Redis — no mocked Redis/Sidekiq for integration paths), and the feature request explicitly asked for tests plus `demo_app` examples driven only by the gem's built-in spec helpers.

**Organization**: Tasks are grouped by user story so each can be implemented, tested, and shipped independently.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies on incomplete tasks)
- **[Story]**: US1 / US2 / US3 (maps to spec.md user stories)
- Exact file paths included in every task

## Path Conventions

Single-project Ruby gem: `lib/ruby_reactor/**` (implementation), `spec/**` (gem specs), plus the bundled `demo_app/` Rails example, `documentation/`, and `gui/` (dashboard frontend).

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Small additions every later phase leans on. No behavior change yet.

- [X] T001 [P] Add `RubyReactor::Error::AsyncWaitTimeoutError` in `lib/ruby_reactor/error/async_wait_timeout_error.rb` and require it from `lib/ruby_reactor.rb` (raised when an FR-005 wait exceeds its bound)
- [X] T002 [P] Add `RubyReactor::Error::DeprecatedDslError` in `lib/ruby_reactor/error/deprecated_dsl_error.rb` (subclass of `Error::ValidationError` so existing rescues still catch it) and require it from `lib/ruby_reactor.rb`
- [X] T003 [P] Add `Configuration#async_wait_timeout` (memoized reader + `attr_writer`, matching the `context_ttl`/`context_lock_ttl` idiom) with a documented default in `lib/ruby_reactor/configuration.rb`
- [X] T004 [P] Add a shared RSpec context that runs an example group against both backends (Sidekiq fake mode and ActiveJob `:test` adapter) in `spec/support/async_backends.rb`, so every new async spec asserts backend-agnosticism per spec.md Assumptions

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Remove the old per-step `async` flag and repair everything that reads it, plus build the notified-wait core shared by US2 and US3.

**⚠️ CRITICAL**: Removing `StepConfig#async?` breaks `Web::API`, `TestSubject`, and existing fixtures at once. This phase must land as one coherent unit before any user story work begins.

### Tests (write first, confirm failing)

- [X] T005 [P] Spec: `async true` inside a `step` block raises `DeprecatedDslError` at class-definition time (not run time), with a message naming `background after:`/`before:`, `async_step`, `async_reactor` — `spec/ruby_reactor/dsl/deprecated_async_flag_spec.rb`
- [X] T006 [P] Spec: `async true` inside a `compose` block raises the same definition-time error, and the `map`-internal `async` option still works untouched — `spec/ruby_reactor/dsl/deprecated_async_flag_spec.rb`
- [X] T007 [P] Spec: `AsyncWaiter` returns immediately when the durable target is already terminal, wakes on a published signal, still resolves when no signal is ever published (fallback re-check), and raises `AsyncWaitTimeoutError` at the bound — `spec/ruby_reactor/async_waiter_spec.rb`

### Implementation

- [X] T008 Remove the `async` DSL method and `@async`/`async?` from `StepBuilder` and `StepConfig`, raising `DeprecatedDslError` from a retained `async` method stub, in `lib/ruby_reactor/dsl/step_builder.rb` (FR-003)
- [X] T009 Remove the `async` DSL method from `ComposeBuilder` (raise `DeprecatedDslError`) and drop the `async:` key from its built step config in `lib/ruby_reactor/dsl/compose_builder.rb` (FR-003; it set the same `StepConfig` flag — see research.md decision 1)
- [X] T010 Add `:async_step_ref` / `:async_reactor_ref` to the documented `composed_contexts` `type:` union (alongside `:composed` and `:map_ref`) in `lib/ruby_reactor/context.rb` — comment-level convention plus any shared constants; no serialization change
- [X] T011 Implement `RubyReactor::AsyncWaiter` in `lib/ruby_reactor/async_waiter.rb`: subscribe-first, then check the durable target, then block on the signal with a coarse fallback re-check, bounded by `Configuration#async_wait_timeout`; takes a channel and a terminal-check callable so US2 and US3 share one core (research.md decision 4)
- [X] T012 Add dedicated-connection subscribe support to `lib/ruby_reactor/storage/redis_adapter.rb` so `subscribe` never blocks the shared client (`SUBSCRIBE` puts a connection into subscriber mode); keep the existing `Storage::Adapter#subscribe`/`#publish` interface signatures intact
- [X] T013 Update `Web::API.determine_step_type` (drop the `config.async?` branch) and `build_structure` (drop the per-step `async:` field) in `lib/ruby_reactor/web/api.rb` so the dashboard survives the flag removal
- [X] T014 Update `TestSubject#prepare_execution_class` (`force_sync` branch) and `#apply_mock_interceptor` to stop mutating the removed `@async` step flag in `lib/ruby_reactor/rspec/test_subject.rb` (research.md decision 6)
- [X] T015 Migrate every existing gem fixture and spec that uses the removed per-step flag to the new DSL across `spec/support/**` and `spec/ruby_reactor/**`, and run `bundle exec rspec` to confirm no other call sites remain

**Checkpoint**: Old flag is gone, suite is green, notified-wait core exists. User stories can begin.

---

## Phase 3: User Story 1 - Unambiguous background hand-off (Priority: P1) 🎯 MVP

**Goal**: Replace the silently-ambiguous per-step `async` flag with a single reactor-level `background` declaration that hands off all remaining steps to a worker, with the cut point nameable from either side (`after:` = named step is last in-process; `before:` = named step is first in the worker).

**Independent Test**: Define a reactor with `step :first`, `step :second`, `background after: :second`, `step :third`; confirm `:first`/`:second` run in the calling process, `.run` returns an `DispatchResult`, and `:third` runs in the dispatched job. Redeclare the same reactor as `background before: :third` and confirm identical behavior in this linear case. Confirm the deprecated flag raises at definition time.

### Tests for User Story 1 (write first, confirm failing)

- [X] T016 [P] [US1] Fixture reactors for background hand-off in `spec/support/reactors/background_reactors.rb`: linear `after:` and `before:` pairs, a **branching** reactor where the two forms pin different steps, plus the invalid variants (duplicate declaration, unknown step, both keys, neither key, whole-reactor-async conflict, `returns` conflict)
- [X] T017 [P] [US1] Spec: `after:` hand-off boundary — steps up to and including the named step run in the calling process, `.run` returns an `DispatchResult`, remaining steps run in the drained job, and compensation for a worker-side failure behaves exactly as for a same-process failure (US1 scenario 1, SC-001) — `spec/ruby_reactor/dsl/reactor_background_spec.rb`
- [X] T018 [P] [US1] Spec: `before:` hand-off boundary — the named step never executes in the calling process and runs in the worker; the linear `after:`/`before:` pair from T016 produces identical outcomes; the branching fixture shows each form pinning its own named step (US1 scenario 2) — `spec/ruby_reactor/dsl/reactor_background_spec.rb`
- [X] T019 [P] [US1] Spec: definition-time guards — duplicate `background`, an unknown step name via either key, both `after:` and `before:` supplied, neither supplied, and `background` combined with whole-reactor `async true` each raise (US1 scenarios 4-5, FR-002, SC-004) — `spec/ruby_reactor/dsl/reactor_background_spec.rb`
- [X] T020 [P] [US1] Spec: trigger edge behavior — hand-off is keyed to *reaching* the named step, not to lexical position (declaration may sit anywhere in the class body); in a DAG with a parallel branch, steps already ready-and-executed before the trigger ran in the calling process; a named step skipped by a `where`/guard never triggers hand-off and the run completes in-process; and the hand-off never re-triggers inside the worker — `spec/ruby_reactor/dsl/reactor_background_spec.rb`

### Implementation for User Story 1

- [X] T021 [US1] Add the `background(after: nil, before: nil)` class macro in `lib/ruby_reactor/dsl/reactor.rb`, storing a normalized `{ mode: :after|:before, step: }` hand-off point behind one reader, plus its definition-time guards (single declaration, known step, exactly one of the two keys, no whole-reactor-`async` combination) (FR-001, FR-002)
- [X] T022 [US1] Re-key the hand-off trigger in `lib/ruby_reactor/executor/step_executor.rb` from the removed per-step `async?` to the reactor's hand-off point — a **post-execution** check when `mode == :after` (fire once the named step's result is recorded) and a **pre-execution** check when `mode == :before` (fire instead of running the named step, leaving its graph node incomplete for the worker) — reusing the existing `handle_async_step` body (checkpoint-before-enqueue → `async_router.perform_async` → `DispatchResult`) unchanged for both, inside the existing `inline_async_execution` guard (FR-001, research.md decision 1)
- [X] T023 [US1] Expose the hand-off point once per reactor as the normalized `{ mode:, step: }` pair in `Web::API.build_structure` in `lib/ruby_reactor/web/api.rb`, replacing the per-step `async:` field dropped in T013
- [X] T024 [US1] Redefine `TestSubject`'s `async: false` / `run_async(false)` to suppress the `background` hand-off (running the reactor fully in-process) in `lib/ruby_reactor/rspec/test_subject.rb`, preserving the option's existing purpose under the new DSL

**Checkpoint**: `background after:` and `background before:` both fully work and are independently testable. This is a shippable MVP — the rename/bugfix half of the feature.

---

## Phase 4: User Story 2 - Async steps that truly run independently (Priority: P2)

**Goal**: `async_step` dispatches one step's work to its own worker job while the calling process keeps running other ready steps; dependent steps consume the result through `result(:name)`.

**Independent Test**: Reactor with `async_step :send_email`, then an unrelated `step :do_something_same_thread`, then `step :check_email` reading `result(:send_email)`. Confirm the unrelated step is not blocked and the reader receives the correct deserialized value.

### Tests for User Story 2 (write first, confirm failing)

- [X] T025 [P] [US2] Fixture reactors for async_step (independent sibling, awaited reader, failing async step with and without a reader, never-completing step for the timeout case) in `spec/support/reactors/async_step_reactors.rb`
- [X] T026 [P] [US2] Spec: `store_step_result`/`retrieve_step_result` round-trip against real Redis, including the `dispatched` → `completed` status transition and `context_ttl` expiry — `spec/ruby_reactor/storage/step_result_spec.rb`
- [X] T027 [P] [US2] Spec: dispatch does not block — a sibling step with no dependency on the async step completes while the async job is still queued (US2 scenario 1, SC-002) — `spec/ruby_reactor/dsl/async_step_spec.rb`
- [X] T028 [P] [US2] Spec: read semantics — on `Success` the reader receives the raw deserialized value (same shape a same-process step yields); on `Failure` the reader receives the `Failure` object itself for inspection (US2 scenario 2, FR-006) — `spec/ruby_reactor/dsl/async_step_spec.rb`
- [X] T029 [P] [US2] Spec: compensation is opt-in — a failing async step with no reader leaves the parent uncompensated, while a reader that inspects the failure and returns `Failure` does trigger compensation (US2 scenario 3, FR-011, SC-003) — `spec/ruby_reactor/dsl/async_step_spec.rb`
- [X] T030 [P] [US2] Spec: wait bound and race-freedom — a never-completing async step fails the reader with a timeout rather than hanging (SC-005); a step that completes *before* the reader subscribes is still resolved; a completion with no signal published is still caught by the fallback re-check — `spec/ruby_reactor/dsl/async_step_wait_spec.rb`
- [X] T031 [P] [US2] Spec: an `async_step` declared after a `background` hand-off point still dispatches to its own job rather than degrading to inline execution inside the worker — `spec/ruby_reactor/dsl/async_step_spec.rb`
- [X] T032 [P] [US2] Spec: `returns :async_step_name` raises at class-definition time — `spec/ruby_reactor/dsl/async_step_spec.rb`

### Implementation for User Story 2

- [X] T033 [P] [US2] Add `store_step_result` / `retrieve_step_result` to the `Storage::Adapter` interface in `lib/ruby_reactor/storage/adapter.rb` and implement them in `lib/ruby_reactor/storage/redis_adapter.rb`, modeled on the existing `store_map_result`/`retrieve_map_results` pair and stamping `context_ttl` (FR-006, data-model.md "Step Result Record")
- [X] T034 [P] [US2] Add the `async_step(name, impl = nil, &block)` class macro in `lib/ruby_reactor/dsl/reactor.rb`, building a normal `StepConfig` plus a dispatch-mode marker argument key so every existing step option (`argument`, `run`, `compensate`, `undo`, `retries`, validators) keeps working (FR-004)
- [X] T035 [P] [US2] Implement the framework-agnostic single-step worker body in `lib/ruby_reactor/step_worker.rb`: load the parent context by id, resolve just that step's arguments, run it, write the Step Result Record, then publish the completion signal (write-before-publish ordering)
- [X] T036 [P] [US2] Add the Sidekiq worker binding in `lib/ruby_reactor/adapters/sidekiq/step_worker.rb`, mirroring `adapters/sidekiq/map_element_worker.rb`
- [X] T037 [P] [US2] Add the ActiveJob worker binding in `lib/ruby_reactor/adapters/active_job/step_worker.rb`, mirroring `adapters/active_job/map_element_worker.rb`
- [X] T038 [US2] Add a `perform_step_async` dispatch entry point to both routers (`lib/ruby_reactor/adapters/sidekiq/router.rb`, `lib/ruby_reactor/adapters/active_job/router.rb`) so async-step dispatch stays backend-agnostic
- [X] T039 [US2] Implement async-step dispatch in `lib/ruby_reactor/executor/step_executor.rb` in strict order: write the Step Result Record (`dispatched`) and the `composed_contexts[:name] = { type: :async_step_ref, ... }` reference, then enqueue, then `dependency_graph.complete_step` so unrelated siblings proceed — and deliberately do *not* gate dispatch on `inline_async_execution` (FR-004, FR-008, research.md decision 2)
- [X] T040 [US2] Add the `:async_step_ref` branch to `Template::Result#resolve` in `lib/ruby_reactor/template/result.rb`: when the step has no in-context result but carries an async-step ref, delegate to `AsyncWaiter` against the Step Result Record, injecting the raw value on Success and the `Failure` object on failure (FR-005, FR-010)
- [X] T041 [US2] Add the `returns` × `async_step` definition-time guard in `lib/ruby_reactor/dsl/reactor.rb` (spec Edge Cases)
- [X] T042 [US2] Add the `async_step` step type to `Web::API.determine_step_type` and an `:async_step_ref` resolution branch to `hydrate_composed_contexts` (mirroring `hydrate_map_ref`) in `lib/ruby_reactor/web/api.rb` (FR-014)
- [X] T043 [US2] Add an `#async_step` traversal helper to `lib/ruby_reactor/rspec/test_subject.rb` mirroring `#composed`/`#map`, and make `async: false` run async steps inline

**Checkpoint**: US1 and US2 both work independently.

---

## Phase 5: User Story 3 - Fire-and-forget async reactors (Priority: P3)

**Goal**: `async_reactor` dispatches a whole nested reactor to run independently — linked to the parent for traceability, excluded from its compensation graph, readable on demand via `result(:name)`.

**Independent Test**: `async_reactor :create_profile` with no reader — forcing the child to fail leaves the parent uncompensated. Separately, `async_reactor :create_account` plus a `step :verify_all` reading `result(:create_account)` — the block sees the child's real outcome and can return `Success` or `Failure`.

### Tests for User Story 3 (write first, confirm failing)

- [X] T044 [P] [US3] Fixture parent/child reactors for async_reactor (fire-and-forget, awaited, same-lock-key collision, invalid-child-inputs, interrupt-paused child) in `spec/support/reactors/async_reactor_reactors.rb`
- [X] T045 [P] [US3] Spec: fire-and-forget isolation — a child failure with no downstream reader never compensates the parent (US3 scenario 1, FR-009, SC-003) — `spec/ruby_reactor/dsl/async_reactor_spec.rb`
- [X] T046 [P] [US3] Spec: awaited outcome — the reader blocks until the child is terminal, receives the child's real `Success`/`Failure` (not the enqueue-time `DispatchResult`), and its explicit `Failure` triggers parent compensation (US3 scenarios 2-3, FR-010) — `spec/ruby_reactor/dsl/async_reactor_spec.rb`
- [X] T047 [P] [US3] Spec: FR-015 deadlock guard — a child declaring the parent's currently-held lock key fails at dispatch with an error naming the key, both reactors, and the three remediations; a single-slot semaphore collides the same way; a *different* key dispatches normally — `spec/ruby_reactor/dsl/async_reactor_locks_spec.rb`
- [X] T048 [P] [US3] Spec: FR-016 pre-enqueue safeguards — invalid child inputs fail the dispatching step in the parent (normal saga handling), and a child declaring `with_ordered_lock` receives its nonce at enqueue — `spec/ruby_reactor/dsl/async_reactor_dispatch_spec.rb`
- [X] T049 [P] [US3] Spec: a child paused at an interrupt is not terminal — the reader waits and times out per FR-005, then resolves after the child is resumed — `spec/ruby_reactor/dsl/async_reactor_spec.rb`
- [X] T050 [P] [US3] Spec: the parent's context carries an `:async_reactor_ref` with the child's `execution_id`, and `returns :async_reactor_name` raises at definition time (FR-008) — `spec/ruby_reactor/dsl/async_reactor_spec.rb`

### Implementation for User Story 3

- [X] T051 [P] [US3] Add the `async_reactor(name, child_reactor_class, &block)` class macro (with `compose`-shaped `argument` mappings) in `lib/ruby_reactor/dsl/reactor.rb`, plus its `returns` guard (FR-007)
- [X] T052 [US3] Implement the dispatch step in `lib/ruby_reactor/step/async_reactor_step.rb`, reusing the full pre-enqueue sequence extracted from `Reactor#run` — child input validation → ordered-lock nonce assignment → persist child context → enqueue — never raw `perform_async`, and registering no `compensate`/`undo` block (FR-007, FR-009, FR-016, research.md decision 3)
- [X] T053 [US3] Implement the FR-015 deadlock guard in the dispatch path: resolve the child's `lock_config[:key_proc]` (and single-slot `semaphore_config`) against the mapped child inputs and fail the dispatch step immediately on collision with a lock the dispatching execution holds, with an error enumerating the three ranked remediations (research.md decision 9)
- [X] T054 [US3] Write the `composed_contexts[:name] = { type: :async_reactor_ref, execution_id:, reactor_class_name:, dispatched_at: }` reference synchronously in the dispatching step (FR-008, data-model.md)
- [X] T055 [US3] Publish the completion signal after the terminal context save in `lib/ruby_reactor/executor.rb`, so an awaited child wakes its parent's waiter (research.md decision 4, data-model.md "Completion Signal")
- [X] T056 [US3] Add the `:async_reactor_ref` branch to `Template::Result#resolve` in `lib/ruby_reactor/template/result.rb`: wait via `AsyncWaiter` against the linked execution's own context row, treating `paused` as non-terminal, and inject the child's result object (FR-005, FR-010)
- [X] T057 [US3] Add the `async_reactor` step type to `Web::API.determine_step_type`, an `:async_reactor_ref` resolution branch to `hydrate_composed_contexts`, and child-graph recursion via `extract_inner_class`/`nested_structure` as `compose`/`map` already do, in `lib/ruby_reactor/web/api.rb` (FR-014)
- [X] T058 [US3] Add an `#async_reactor` traversal helper to `lib/ruby_reactor/rspec/test_subject.rb` mirroring `#composed`, and make `async: false` run async reactors inline

**Checkpoint**: All three user stories are independently functional.

---

## Phase 6: Polish & Cross-Cutting Concerns

**Purpose**: Observability, the dashboard frontend, the demo app, documentation, and release hygiene.

- [X] T059 Emit structured log entries (reactor name, step name, execution id) for background hand-off, `async_step` dispatch/completion, and `async_reactor` dispatch/completion, following the existing middleware event pattern, across `lib/ruby_reactor/executor/step_executor.rb` and `lib/ruby_reactor/step_worker.rb` (FR-012)
- [X] T060 [P] Render the `async_step` and `async_reactor` step types (icon, color, and for async_reactor a drill-down link to the linked execution) in `gui/src/components/DagVisualizer.tsx` (FR-014)
- [X] T061 [P] Render the new step types and their status/result panels in `gui/src/components/StepInspector.tsx` (FR-014)
- [X] T062 [P] Spec: `Web::API` returns the new step types and hydrates both new ref types, including the async_reactor child's nested structure — `spec/ruby_reactor/web/api_spec.rb`
- [X] T063 Replace `demo_app/app/reactors/partial_async_reactor.rb` with a `background after:`-based example (the old per-step `async true` syntax no longer parses) and rename it to `demo_app/app/reactors/background_demo_reactor.rb`
- [X] T064 [P] Add `demo_app/app/reactors/async_step_demo_reactor.rb` demonstrating `async_step` plus a `result()` reader (the `send_email` example from the spec)
- [X] T065 [P] Add `demo_app/app/reactors/async_reactor_demo_reactor.rb` demonstrating fire-and-forget alongside an awaited child whose outcome the parent inspects
- [X] T066 [P] Add `demo_app/spec/reactors/background_demo_reactor_spec.rb` using only the built-in `test_reactor` helper and matchers
- [X] T067 [P] Add `demo_app/spec/reactors/async_step_demo_reactor_spec.rb` using only the built-in spec helpers
- [X] T068 [P] Add `demo_app/spec/reactors/async_reactor_demo_reactor_spec.rb` using only the built-in spec helpers
- [X] T069 Rewrite the "Step-Level Async" section as `background after:`/`before:` (documenting which step each form pins, and the DAG caveat) and add new `async_step` / `async_reactor` sections (covering the notified wait, the opt-in compensation model, and the FR-015 lock guidance) in `documentation/async_reactors.md`
- [X] T070 [P] Add the `async_reactor` vs `compose` cross-reference (fire-and-forget/uncompensated vs synchronous/compensation-linked, and when a lock collision means you wanted `compose`) in `documentation/composition.md`
- [X] T071 Mirror the T069/T070 edits into the duplicate copies under `demo_app/documentation/` so the two trees do not drift (research.md decision 7)
- [X] T072 Rewrite the "Step-Level Async" subsection and add `async_step`/`async_reactor` coverage in `README.md`
- [X] T073 Add the breaking-change entry with a migration note (per-step and compose `async` → `background after:` / `async_step` / `async_reactor`) under the correct semantic heading in `CHANGELOG.md` (FR-013)
- [X] T074 Run `bundle exec rubocop` (no `--disable-pending-cops`) and fix all offenses across the changed files
- [X] T075 Execute the full `quickstart.md` validation: both backends green, `demo_app` specs green, and the dashboard verified in a browser (do not close FR-014 on passing specs alone)

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies — start immediately
- **Foundational (Phase 2)**: Needs T001-T004 — **BLOCKS all user stories**
- **User Story 1 (Phase 3)**: Needs Phase 2
- **User Story 2 (Phase 4)**: Needs Phase 2 (specifically `AsyncWaiter` from T011)
- **User Story 3 (Phase 5)**: Needs Phase 2 (specifically `AsyncWaiter` from T011)
- **Polish (Phase 6)**: Needs the user stories whose surface it documents/renders

### User Story Dependencies

- **US1 (P1)**: Independent after Phase 2. Ships alone as the MVP.
- **US2 (P2)**: Independent after Phase 2 — does not require US1. (T031 asserts the US1 interaction only if US1 is present.)
- **US3 (P3)**: Independent after Phase 2 — does not require US1 or US2. Shares only the `AsyncWaiter` core built in Phase 2.

### Within Each User Story

- Tests first, confirmed failing (constitution Principle III)
- Fixtures → storage/adapters → DSL macro → executor dispatch → `Template::Result` wait branch → dashboard/test-helper surface
- Story complete and independently green before moving to the next priority

### Parallel Opportunities

- All of Phase 1 (T001-T004) runs in parallel
- Phase 2 tests T005-T007 run in parallel; then T008/T009 and T010-T012 are separate files
- Every story's test tasks are `[P]` — write the whole story's spec set at once
- In US2: T033 (storage), T034 (DSL), T035-T037 (workers) are independent files
- In US3: T051 (DSL) is independent of the dispatch-step work
- Across teams: after Phase 2, US1, US2, and US3 can be developed simultaneously
- Polish: T060/T061 (GUI), T064/T065 (demo reactors), T066-T068 (demo specs), T070 (docs) all parallelize

---

## Parallel Example: User Story 2

```bash
# Write the whole US2 spec set together (all fail initially):
Task: "Fixture reactors for async_step in spec/support/reactors/async_step_reactors.rb"
Task: "Storage round-trip spec in spec/ruby_reactor/storage/step_result_spec.rb"
Task: "Non-blocking dispatch spec in spec/ruby_reactor/dsl/async_step_spec.rb"
Task: "Wait bound and race-freedom spec in spec/ruby_reactor/dsl/async_step_wait_spec.rb"

# Then build the independent implementation pieces together:
Task: "Storage primitives in lib/ruby_reactor/storage/adapter.rb + redis_adapter.rb"
Task: "async_step macro in lib/ruby_reactor/dsl/reactor.rb"
Task: "Worker body in lib/ruby_reactor/step_worker.rb"
Task: "Sidekiq binding in lib/ruby_reactor/adapters/sidekiq/step_worker.rb"
Task: "ActiveJob binding in lib/ruby_reactor/adapters/active_job/step_worker.rb"
```

---

## Implementation Strategy

### MVP First (User Story 1 only)

1. Phase 1: Setup (T001-T004)
2. Phase 2: Foundational (T005-T015) — the breaking removal plus the shared waiter
3. Phase 3: User Story 1 (T016-T024)
4. **STOP and VALIDATE**: `background after:` works end to end; deprecated syntax fails loudly at definition time
5. This alone is a shippable MAJOR release — it fixes the reported footgun without adding new surface

### Incremental Delivery

1. Setup + Foundational → old flag gone, suite green, waiter available
2. + US1 → hand-off is unambiguous → ship (MVP)
3. + US2 → real per-step async work → ship
4. + US3 → independent nested reactors → ship
5. + Polish → dashboard, demo app, docs, CHANGELOG → release

### Parallel Team Strategy

With three developers, after Phase 2 lands as one unit:

- Developer A: US1 (T016-T024), then T063/T066 and the README/docs hand-off sections
- Developer B: US2 (T025-T043), then T064/T067
- Developer C: US3 (T044-T058), then T065/T068
- Whoever finishes first picks up the GUI pair (T060/T061)

---

## Notes

- **Phase 2 is a single atomic landing.** Removing `StepConfig#async?` breaks `Web::API`, `TestSubject`, and existing fixtures simultaneously — T008 through T015 should merge together, not incrementally.
- **Real Redis, always.** Constitution Principle III forbids mocked Redis/Sidekiq state for integration and contract tests; `Sidekiq::Testing.inline!` is unit-level only.
- **Both backends, every async spec.** Use the shared context from T004 rather than asserting against Sidekiq alone.
- **Two documentation trees.** `documentation/` and `demo_app/documentation/` are duplicates — T071 exists specifically to prevent drift.
- **The dispatch-time ordering in T039 is load-bearing**: durable record and context ref *before* enqueue (the F2 rule), or a crash between the two leaves a job with no record.
- `[P]` tasks touch different files with no incomplete dependencies; commit after each task or logical group.
