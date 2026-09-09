---

description: "Task list for Reactor Signal Semantics"
---

# Tasks: Reactor Signal Semantics

**Input**: Design documents from `/specs/001-reactor-signal-semantics/`

**Prerequisites**: [plan.md](./plan.md), [spec.md](./spec.md), [research.md](./research.md), [data-model.md](./data-model.md), [contracts/](./contracts/)

**Tests**: REQUIRED. Constitution Principle III mandates RSpec test-first
(Red-Green-Refactor) with a live Redis — mocking Redis is forbidden for
integration paths. Every phase below writes its tests before its implementation.

**Organization**: Grouped by user story (US1–US4) plus two cross-cutting phases
(retry interaction, dashboard) whose requirements span several stories.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: US1–US4 for user-story phases; omitted for setup, foundational,
  cross-cutting, and polish phases

## Path Conventions

Ruby gem: library code in `lib/ruby_reactor/`, specs in `spec/`, dashboard
source in `gui/src/`, committed dashboard build output in
`lib/ruby_reactor/web/public/`.

---

## Phase 1: Setup

**Purpose**: Establish a green baseline and a complete migration inventory.

- [ ] T001 Confirm the baseline is green before touching anything: `docker compose up -d redis && bundle exec rspec && bundle exec rubocop` from the repo root; record the passing spec count in the PR description
- [ ] T002 [P] Write the migration inventory to `specs/001-reactor-signal-semantics/migration-sites.md` by running `grep -rn "Skipped\|skipped" lib spec documentation README.md llms.txt llms-full.txt demo_app gui/src --include "*.rb" --include "*.md" --include "*.ts" --include "*.tsx" | grep -v web/public/assets` and classifying every hit as HALT (means clean stop today) or SKIP (already means per-step) — this list is the completion check for T084
- [ ] T003 [P] Install dashboard dependencies so the vitest suites can run: `cd gui && npm install`

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Define the four signal objects. Both P1 and P2 depend on these, and
splitting them leaves `Skipped` undefined mid-flight.

**⚠️ CRITICAL**: No user story work can begin until this phase is complete.

- [ ] T004 Write failing unit specs for the signal objects in `spec/ruby_reactor/signals_spec.rb`: `Halt` carries `reason`/`period_key`/`step_name` and answers `halted?`; `Halt` does NOT respond to `skipped?`; `Skipped` wraps a value and answers `skipped?`; `Success`/`Failure` answer `halted?` and `skipped?` with false; `RubyReactor.Skipped(reason: "x")` raises `ArgumentError` naming `Halt`
- [ ] T005 Rename the `Skipped` class to `Halt` in `lib/ruby_reactor.rb` (currently line 81) keeping it a `Success` subclass and its `reason`/`period_key`/`step_name` readers; replace its `skipped?` predicate with `halted?` and update the class comment to describe a clean halt
- [ ] T006 Add the new value-carrying `Skipped < Success` class in `lib/ruby_reactor.rb` with `value`, optional `reason`, `step_name`, and `skipped? => true`; include the migration guard that raises `ArgumentError` ("RubyReactor::Skipped now marks a single step as skipped and continues. The clean halt you want is RubyReactor.Halt(reason: ...) / halt!(reason: ...)") when the sole argument is a `reason:` keyword
- [ ] T007 Add `halted? => false` to `Success` and `Failure` in `lib/ruby_reactor.rb` (both already answer `skipped? => false`)
- [ ] T008 Replace the module builder `RubyReactor.Skipped(reason:)` at `lib/ruby_reactor.rb:329` with `RubyReactor.Halt(reason: nil, **kwargs)` and a new `RubyReactor.Skipped(value = nil)` carrying the same guard as T006
- [ ] T009 [P] Add `Halt()` and update `Skipped()` in the DSL builder module `lib/ruby_reactor/dsl/template_helpers.rb` (currently line 36)
- [ ] T010 [P] Add `Halt()` and update `Skipped()` in `lib/ruby_reactor/step.rb` `ClassMethods` (currently line 19)
- [ ] T011 Add `"Halt"` and `"Skipped"` arms **before** the `Success` arm in `ContextSerializer.serialize_value` and the matching branches in `deserialize_value` in `lib/ruby_reactor/context_serializer.rb` (serializer starts line 38) so signal identity survives the undo stack and map element round trips
- [ ] T012 Run `bundle exec rspec spec/ruby_reactor/signals_spec.rb` and confirm green

**Checkpoint**: Signal objects exist and are serializable. Story work can begin.

---

## Phase 3: User Story 1 - Clean halt has an honest name (Priority: P1) 🎯 MVP

**Goal**: Every clean-stop behaviour that exists today works identically under
the name `Halt`, with a `halted` run status and a `be_halted` matcher.

**Independent Test**: Re-express every existing clean-halt scenario (explicit
halt, period gate, three ordered-lock short-circuits) with `Halt` and confirm
identical observable results — no further steps, no rollback, reason and
halting step reported.

### Tests for User Story 1

> Write these first; they must FAIL before the implementation tasks below.

- [ ] T013 [P] [US1] Rename `spec/ruby_reactor/skipped_helper_spec.rb` to `spec/ruby_reactor/halt_helper_spec.rb` and migrate it to `Halt` / `be_halted`, asserting the run stops, no compensation runs (undo trace empty), and reason plus halting step reach the caller
- [ ] T014 [P] [US1] Rename `spec/ruby_reactor/rspec/test_subject_skipped_spec.rb` to `..._halted_spec.rb` and migrate it, covering both a sync run (result object surfaced directly) and an async run (rebuilt from the trace)
- [ ] T015 [P] [US1] Migrate the ordered-lock and period halt expectations in `spec/ruby_reactor/integration/ordered_lock_spec.rb`, `spec/ruby_reactor/integration/locking_spec.rb`, `spec/ruby_reactor/storage/redis_ordered_locking_spec.rb`, and `spec/examples/locking_reactors.rb` to `Halt` / `be_halted`, keeping the three ordered-lock reasons asserted by name
- [ ] T016 [P] [US1] Migrate halt expectations in `spec/ruby_reactor/sweeper_spec.rb`, `spec/integration/interrupt_validation_spec.rb`, `spec/map/fail_fast_spec.rb`, and `spec/map/map_fail_fast_spec.rb`
- [ ] T017 [US1] Add a failing spec in `spec/ruby_reactor/halt_status_spec.rb` asserting a halted run persists status `halted`, that a context stored with the legacy `"skipped"` status is read back as halted, and that a halted run leaves completed steps' effects in place

### Implementation for User Story 1

- [ ] T018 [US1] Rename `handle_skipped` to `handle_halt` in `lib/ruby_reactor/executor/result_handler.rb` (line 81), emit trace `{ type: :halt, step:, reason: }`, keep the no-undo-stack behaviour, and move the `when RubyReactor::Halt` arm to the top of `handle_step_result` (line 17)
- [ ] T019 [US1] Update the early return in `lib/ruby_reactor/executor/step_executor.rb:41` to `result.is_a?(RubyReactor::Halt)` and refresh the surrounding comments (lines 38–49) to name Halt
- [ ] T020 [US1] Update `lib/ruby_reactor/executor.rb`: rename `finalize_skipped` to `finalize_halt` (line 351), return `Halt` from `check_period_gate` (line 371), guard `mark_period_on_success` against `Halt` instead of `Skipped` (line 374), and add `when RubyReactor::Halt` → `@context.status = :halted` at the top of `update_context_status` (line 505)
- [ ] T021 [US1] Replace `RubyReactor::Skipped` with `RubyReactor::Halt` in the terminal-result `when` list of `execute_current_step_and_continue` in `lib/ruby_reactor/executor.rb:545` and update the ordering comment
- [ ] T022 [P] [US1] Switch the three short-circuit results and the detection predicate in `lib/ruby_reactor/executor/ordered_lock_support.rb` (lines 120–127, 172) to `Halt`, preserving the `:ordered_lock_stale_batch` / `:ordered_lock_drained_replay` / `:ordered_lock_chain_failed` reasons
- [ ] T023 [P] [US1] Add `halted` to the accepted status list in `lib/ruby_reactor/storage/redis_adapter.rb:235`, keep accepting legacy `"skipped"`, and translate it to halted on read
- [ ] T024 [P] [US1] Do the same in `lib/ruby_reactor/web/api.rb:150` (`reactor_status`) so the dashboard API never emits the legacy name
- [ ] T025 [P] [US1] Add `halted` to the terminal-status list in `lib/ruby_reactor/map/sweeper.rb:95`
- [ ] T026 [US1] Add the `be_halted` matcher (with `.because` and `.at_step` chains) to `lib/ruby_reactor/rspec/matchers.rb` by migrating the existing `be_skipped` matcher (lines 267–307) to read `halted?`
- [ ] T027 [US1] Rename `skipped_result` to `halted_result` in `lib/ruby_reactor/rspec/test_subject.rb` (lines 253, 282–287), keying on status `"halted"` plus legacy `"skipped"` and searching the trace for `type: :halt`
- [ ] T028 [P] [US1] Switch the reactor-span and step-span halt branches in `lib/ruby_reactor/open_telemetry.rb` (lines 505–507, 581–583) from `skipped?` to `halted?`, emitting status `"halted"` and `*_halt_reason`
- [ ] T029 [US1] Add an explicit `Halt` branch to the map element result path so an element-level halt propagates as a run halt instead of being collected as a value: `lib/ruby_reactor/map/collector.rb` (around line 116) and `lib/ruby_reactor/step/map_step.rb` (around line 130)
- [ ] T030 [P] [US1] Update the halt references in the doc comments of `lib/ruby_reactor/ordered_lock.rb` (lines 65, 69, 114) and `lib/ruby_reactor/dsl/lockable.rb` (lines 56, 96)
- [ ] T031 [US1] Run `bundle exec rspec` and confirm every migrated halt spec passes with no behaviour change other than the names (SC-001)

**Checkpoint**: US1 complete — clean halt fully works under its new name.

---

## Phase 4: User Story 2 - A step can be skipped while the reactor continues (Priority: P2)

**Goal**: `Skipped(value)` marks one step as skipped, the reactor continues, and
dependants read the value exactly as they would a success value.

**Independent Test**: Three-step reactor where step two is skipped with a value
and step three reads `result(:step_two)` — step three runs and sees the value.

### Tests for User Story 2

- [ ] T032 [P] [US2] Write failing specs in `spec/ruby_reactor/skipped_step_spec.rb`: a dependant reads the skipped step's value; a skipped step with no value yields an empty value without erroring; a reactor whose `return_step` is skipped returns that value; a reactor where every step is skipped completes; the run status is `completed`, not `halted`
- [ ] T033 [P] [US2] Write a failing spec in `spec/ruby_reactor/skipped_rollback_spec.rb`: with steps one (success) → two (skipped) → three (failure), rollback undoes step one and never touches step two
- [ ] T034 [P] [US2] Write a failing spec in `spec/ruby_reactor/skipped_trace_spec.rb`: the execution trace holds `{ type: :skipped, step: }` for the skipped step, and the trace survives an async round trip (real Redis, worker path)
- [ ] T035 [P] [US2] Write a failing spec asserting a skipped step's value is subject to the step's declared output validation, in `spec/ruby_reactor/skipped_step_spec.rb`
- [ ] T036 [P] [US2] Write a failing spec for a skipped element inside a mapped step (remaining elements continue, values collected) in `spec/map/skipped_element_spec.rb`

### Implementation for User Story 2

- [ ] T037 [US2] Add `handle_skipped` to `lib/ruby_reactor/executor/result_handler.rb`, dispatched from a `when RubyReactor::Skipped` arm placed after `Halt` and before `Success`: validate the output, record the result, `@context.set_result`, `@dependency_graph.complete_step`, append the `{ type: :skipped }` trace entry, and deliberately NOT push to the undo stack
- [ ] T038 [US2] Let the step loop continue past a skipped step in `lib/ruby_reactor/executor/step_executor.rb` (`execute_all_steps`, lines 30–58) and fire the `@on_step_complete` durable checkpoint for it, as happens for a plain success
- [ ] T039 [US2] Ensure `execute_current_step_and_continue` in `lib/ruby_reactor/executor.rb:545` treats `Skipped` as continue (it must NOT appear in the terminal `when` list alongside Halt)
- [ ] T040 [P] [US2] Emit `step.status = "skipped"` with `step.skipped_reason` for a skipped step in `lib/ruby_reactor/open_telemetry.rb` (step-span branch, around line 581)
- [ ] T041 [US2] Add the `be_skipped` matcher's new meaning in `lib/ruby_reactor/rspec/matchers.rb` — asserts a step was skipped (result or trace), chainable with `.at_step`; a halted run must NOT satisfy it
- [ ] T042 [US2] Run `bundle exec rspec spec/ruby_reactor/skipped_*_spec.rb spec/map/skipped_element_spec.rb` and confirm green

**Checkpoint**: US1 and US2 both work independently.

---

## Phase 5: User Story 3 - One-line outcome helpers (Priority: P3)

**Goal**: `success!`, `fail!`, `skip!`, `halt!` end the step immediately with the
matching signal, from any call depth, in both authoring styles.

**Independent Test**: One inline-block step and one class step, each calling each
helper, with an unreachable line after the call that raises if executed.

### Tests for User Story 3

- [ ] T043 [P] [US3] Write failing specs in `spec/ruby_reactor/step_signals_spec.rb` for all four helpers × both authoring styles, each followed by a line that raises if reached
- [ ] T044 [P] [US3] Add failing specs in the same file for: a helper called from a nested method; a helper called inside `begin … rescue Exception … end` (the signal must still win — FR-021); an `ensure` block that must still run; a helper used inside a `compensate` and an `undo` body
- [ ] T045 [P] [US3] Add a failing spec asserting `skip!(reason: "x")` hits the migration guard and that `skip!({ reason: "x" })` passes the hash through as a value

### Implementation for User Story 3

- [ ] T046 [US3] Create `lib/ruby_reactor/step_signals.rb` defining `RubyReactor::StepSignals` with a module-private catch tag and `success!(value = nil)`, `skip!(value = nil)`, `fail!(error, **opts)`, `halt!(reason: nil)` — each building its signal and `throw`ing it
- [ ] T047 [P] [US3] Mix `StepSignals` into `RubyReactor::Step::ClassMethods` in `lib/ruby_reactor/step.rb` so class steps get the helpers
- [ ] T048 [P] [US3] Mix `StepSignals` into `RubyReactor::Dsl::TemplateHelpers` in `lib/ruby_reactor/dsl/template_helpers.rb` so inline blocks get the helpers
- [ ] T049 [US3] Wrap the step body invocation in `catch(StepSignals::TAG)` in `run_step_implementation` in `lib/ruby_reactor/executor/step_executor.rb` (lines 292–303), covering both the `run_block.call` and `impl.run` branches
- [ ] T050 [US3] Wrap the compensation and undo invocations in `catch(StepSignals::TAG)` in `lib/ruby_reactor/executor/compensation_manager.rb` (`compensate_step` lines 60–66, `undo_step` lines 100–108)
- [ ] T051 [US3] Run `bundle exec rspec spec/ruby_reactor/step_signals_spec.rb` and confirm green

**Checkpoint**: All three authoring improvements usable together.

---

## Phase 6: User Story 4 - Rollback traces distinguish "ran" from "never written" (Priority: P4)

**Goal**: Compensation and undo that were never implemented report `Skipped`;
rollback behaviour is otherwise unchanged.

**Independent Test**: Roll back a reactor mixing steps that define
compensation/undo with steps that do not, and read the two apart in the trace.

### Tests for User Story 4

- [ ] T052 [P] [US4] Write failing specs in `spec/ruby_reactor/compensation_defaults_spec.rb`: an undefined compensation reports skipped and rollback still proceeds; an undefined undo reports skipped; a defined compensation that succeeds is distinguishable from the skipped case; a compensation that fails still raises `CompensationError` (never confused with skipped)

### Implementation for User Story 4

- [ ] T053 [P] [US4] Change the class-step defaults in `lib/ruby_reactor/step.rb:29` (`compensate`) and `:33` (`undo`) to return `RubyReactor.Skipped()`
- [ ] T054 [P] [US4] Change the inline defaults in `lib/ruby_reactor/executor/compensation_manager.rb:66` and `:108` to `RubyReactor.Skipped()`
- [ ] T055 [US4] Add a `skipped:` flag to the `:compensate` and `:undo` execution-trace entries in `lib/ruby_reactor/executor/compensation_manager.rb` (trace appends around lines 74 and 116), sourced from the result's `skipped?`
- [ ] T056 [US4] Run `bundle exec rspec spec/ruby_reactor/compensation_defaults_spec.rb` and confirm rollback semantics are unchanged (`when RubyReactor::Success` at line 25 still matches, since `Skipped < Success`)

**Checkpoint**: All four user stories independently functional.

---

## Phase 7: Retry Interaction (cross-cutting, FR-025–FR-033)

**Purpose**: Pin down which signals enter the retry machinery, and give `Failure`
the `retry:` spelling.

- [ ] T057 Write the failing retry matrix specs in `spec/ruby_reactor/retry_signals_spec.rb`, counting invocations in the step body: `fail!(e)` on a 3-attempt step → 3 attempts then rollback; `fail!(e, retry: false)` → 1 attempt, no backoff sleep, straight to rollback; `skip!` after 2 failed attempts → run completes, no exhaustion failure; `halt!` after 2 failed attempts → run halts, no rollback; `fail!(e, retry: true)` on a step with no retry config → 1 attempt (the flag cannot grant retries)
- [ ] T058 [P] Add an async variant to the same file asserting a `retry: false` failure inside a background-executed step re-enqueues no job (live Redis, real worker path)
- [ ] T059 Accept `retry:` in `Failure#initialize` in `lib/ruby_reactor.rb:101` by adding `**opts` and taking `opts[:retry]` in preference to `retryable:`, leaving `retryable:` working for existing callers and for `context_serializer.rb:45`
- [ ] T060 [P] Forward both spellings from `fail!` in `lib/ruby_reactor/step_signals.rb`
- [ ] T061 [P] Add explicit `when RubyReactor::Halt` / `when RubyReactor::Skipped` arms before the `Success` arm in `handle_retry_result` in `lib/ruby_reactor/executor/retry_manager.rb:97` — behaviour is already correct via inheritance, so this is readability plus a guard against a future hierarchy change
- [ ] T062 Run `bundle exec rspec spec/ruby_reactor/retry_signals_spec.rb` and confirm the full matrix passes

---

## Phase 8: Dashboard (cross-cutting, FR-036–FR-040)

**Purpose**: Make the two new states visible where operators look. Note the
trap: a skipped step stores a result value, so value-presence must no longer
imply "completed".

- [ ] T063 [P] Write failing vitest cases in `gui/src/components/__tests__/DagVisualizer.test.tsx`: a context whose `intermediate_results` contain the skipped step AND whose trace holds `{ type: 'skipped', step }` renders that node as skipped, not completed; a trace ending in `{ type: 'halt', step }` marks the halting node halted and leaves unreached nodes pending (not cancelled)
- [ ] T064 [P] Write failing vitest cases in `gui/src/components/__tests__/StepInspector.test.tsx`: a `:compensate` entry with `skipped: true` renders as never-implemented, one with `skipped: false` renders as executed
- [ ] T065 [P] Write failing vitest cases in `gui/src/lib/__tests__/reactors.test.ts` asserting `aggregateByClass` counts `halted` runs in the clean-outcome bucket, and still does so for a legacy `skipped` row
- [ ] T066 Derive node state from the trace in `gui/src/components/DagVisualizer.tsx` (`resolveStatus`, lines 305–332): add `halted` and `skipped` checks AFTER the `intermediate_results` check so they override `completed`; leave unreached steps `pending` on a halted run
- [ ] T067 [P] Add `skipped` and `halted` entries to `statusColors` / `StatusIcon` in `StepNode` and to `statusBorderColors` in `GroupNode` in `gui/src/components/DagVisualizer.tsx` (lines 34–48, 80–86), visually distinct from `completed` and `cancelled`
- [ ] T068 Add the third rollback state in `gui/src/components/StepInspector.tsx` (lines 180–192): read the entry's `skipped` flag and render "not implemented" instead of "executed"
- [ ] T069 [P] Add a `halted` badge (style + icon) in `gui/src/components/StatusBadge.tsx` (lines 8, 17), keeping a `skipped` entry for per-step display
- [ ] T070 [P] Key the run-status colour on `halted` in `gui/src/components/ReactorDetail.tsx:80`
- [ ] T071 [P] Change the status filter option to `halted` / "Halted" in `gui/src/components/LiveView.tsx:62` and `gui/src/components/ReactorClassInstances.tsx:69`
- [ ] T072 [P] Count `halted` (and legacy `skipped`) in the success bucket in `gui/src/lib/reactors.ts:32`
- [ ] T073 Run `cd gui && npm test && npm run lint` and confirm green
- [ ] T074 Rebuild and commit the shipped bundle: `rake build:ui`, then verify `lib/ruby_reactor/web/public/` shows regenerated assets in `git status` (FR-040)
- [ ] T075 Smoke-test manually with `rake server:start`: run one reactor that skips a step and one that halts, then confirm the list filter, badge, DAG, and step inspector all read correctly

---

## Phase 9: Polish & Cross-Cutting Concerns

- [ ] T076 [P] Update the signal section of `README.md` (lines 219–222) to document `Success` / `Failure` / `Halt` / `Skipped` plus the four helpers
- [ ] T077 [P] Rewrite the "Skipping a reactor cleanly" section of `documentation/core_concepts.md` as clean halt, and add a per-step skip section showing a value flowing to a dependant
- [ ] T078 [P] Update `documentation/testing.md` for `be_halted` / `be_skipped`, `documentation/middlewares.md` and `documentation/locks_and_semaphores.md` for the halt vocabulary, and `documentation/examples/payment_processing.md` for whichever signal its example means
- [ ] T079 [P] Document the retry flag (`retry:` on `Failure` and `fail!`, veto-only) in `documentation/retry_configuration.md`
- [ ] T080 [P] Regenerate or hand-update `llms.txt` and `llms-full.txt` with the new vocabulary
- [ ] T081 [P] Update `demo_app/` to use the new vocabulary, and add one step demonstrating `skip!` with a value consumed downstream (Constitution: demo_app is the living integration example)
- [ ] T082 Add the migration note to `CHANGELOG.md` under `Features`: the `Skipped` → `Halt` rename, the new per-step `Skipped`, the helpers, the `retry:` spelling, and the compensate/undo default change (FR-035)
- [ ] T083 State the boundary explicitly in `documentation/core_concepts.md`: **`Skipped` means nothing happened — if a side effect happened, return `Success` and declare an `undo`** (the Principle II documentation boundary from plan.md)
- [ ] T084 Confirm the T002 inventory is fully consumed — every HALT-classified site migrated, every SKIP-classified site intentionally left — and delete `specs/001-reactor-signal-semantics/migration-sites.md`
- [ ] T085 Run the full gate: `bundle exec rspec && bundle exec rubocop` (SC-007), plus `cd gui && npm test`
- [ ] T086 Walk `specs/001-reactor-signal-semantics/quickstart.md` scenarios 1–8 end to end and confirm each expected outcome

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: no dependencies
- **Foundational (Phase 2)**: depends on Setup — BLOCKS every story
- **US1 (Phase 3)**: depends on Phase 2
- **US2 (Phase 4)**: depends on Phase 2. Independent of US1 in principle, but
  both touch `result_handler.rb` and `step_executor.rb`, so run US1 first unless
  two people coordinate those two files
- **US3 (Phase 5)**: depends on Phase 2 for the signal classes; `halt!`/`skip!`
  are only observable once US1/US2 wire their behaviour
- **US4 (Phase 6)**: depends on Phase 2 only — fully parallel with US1–US3
- **Retry (Phase 7)**: T059/T061 depend on Phase 2; T057's `skip!`/`halt!` cases
  depend on US2 and US3
- **Dashboard (Phase 8)**: depends on US1 and US2 for the trace entries and
  status it renders, and on US4 for the `skipped:` rollback flag
- **Polish (Phase 9)**: depends on everything

### Within Each Phase

- Tests first, confirmed failing, before implementation (Constitution III)
- Signal classes before dispatch changes
- Dispatch changes before matcher and dashboard changes
- `Halt` arm before `Skipped` arm before `Success` arm at every `case` site

### Parallel Opportunities

- T002, T003 in Setup
- T009, T010 in Foundational
- All US1 test migrations (T013–T016) — different spec files
- T022–T025, T028, T030 in US1 — different library files
- All US2 test files (T032–T036)
- US4 (Phase 6) can run start to finish alongside US1–US3
- T063–T065 dashboard tests; T067, T069–T072 dashboard implementation
- Nearly all of Phase 9 documentation (T076–T081)

---

## Parallel Example: User Story 1 test migration

```bash
# Four spec files, no shared state — migrate together:
Task: "Migrate spec/ruby_reactor/skipped_helper_spec.rb → halt_helper_spec.rb"
Task: "Migrate spec/ruby_reactor/rspec/test_subject_skipped_spec.rb → ..._halted_spec.rb"
Task: "Migrate the ordered-lock and locking specs to Halt / be_halted"
Task: "Migrate sweeper, interrupt-validation, and map fail-fast specs"
```

---

## Implementation Strategy

### MVP (US1 only)

1. Phase 1 Setup → Phase 2 Foundational → Phase 3 US1
2. **STOP and VALIDATE**: full suite green, every clean-halt behaviour identical
   under the new name (SC-001)
3. This alone is shippable: an honest vocabulary with zero behaviour change

### Incremental Delivery

1. Setup + Foundational → signal objects exist
2. + US1 → halt renamed, dashboard/status/matchers coherent (MVP)
3. + US2 → the new per-step skip, the capability that did not exist
4. + US3 → helper ergonomics
5. + US4 → honest rollback traces
6. + Phase 7 → retry semantics pinned and tested
7. + Phase 8 → operators can see all of it
8. + Phase 9 → docs, demo, changelog, full gate

### Suggested Commit Boundaries

One commit per phase, or per checkpoint within a phase. Phase 2 must land as a
single commit — a tree with `Skipped` renamed but the new class undefined does
not load.

---

## Notes

- `Halt` and `Skipped` are both `Success` subclasses, so **`when` ordering is
  load-bearing at every dispatch site**: Halt → Skipped → Success. A misordered
  `case` silently takes the wrong branch
- `Halt` deliberately has no `skipped?` method — a missed migration site raises
  `NoMethodError` rather than reading a plausible `false`. Do not add it back
- The dashboard bundle in `lib/ruby_reactor/web/public/` is build output; edit
  `gui/src/` and rebuild, never edit the bundle
- Redis must be running for the suite; mocking it is forbidden by Principle III
- Commit after each task or logical group; stop at any checkpoint to validate
