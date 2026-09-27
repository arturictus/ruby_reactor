# Implementation Plan: Reliable Rollback Across Constructs

**Branch**: `execution_flow_analysis` | **Date**: 2026-09-26, revised 2026-09-27 (PR #65 review) | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `specs/008-rollback-reliability/spec.md`

## Summary

This plan closes the four High findings from the 007 analysis, and the smaller findings the same
fixes cover, so that every construct rolls back by one rule:

- **F-01**: map elements that succeeded are never rolled back.
- **F-02**: a retried `compose` resumes a child that was already undone.
- **F-03**: some failures skip rollback entirely.
- **F-04**: an `async_step`'s own `compensate`/`undo` never run.
- **Also fixed**: F-05 (fan-out leftovers depend on scheduling), F-06 (a raising condition
  compensates a step that never ran) and F-13 (failures without a step name).

**Revision 2026-09-27 (PR #65 review)**. The first implementation is on the branch. The review
reverses three of its decisions, and this plan now covers the rework (research R-14–R-18):

- **R-14**: nested reactors are never retried as a whole. `retries` on `compose`/`async_reactor`
  raises at class definition. The fresh-child code (R-05) is deleted. This closes F-02.
- **R-15**: `where`/`guard` are removed. `ConditionError` goes with them. This closes F-06.
- **R-16**: every exception rolls back except interruptions (`SignalException`, `SystemExit`,
  `NoMemoryError`, `Timeout::ExitException`). One matcher module, `Error::Rescuable`, replaces
  `rescue StandardError` at the user-code boundaries. `aborted` is kept for interruptions only, and
  the rollback loop pops each undo entry as it completes.
- **R-17**: `Skipped` is documented as "this run caused no effect". No code change.

Approach of the first implementation ([research.md](research.md)), still valid except where marked:

- **Bounded "step owns its lifecycle" refactor (R-01)**:
  - `StepConfig` becomes the single owner of each step's lifecycle operations: resolve arguments,
    conditions, body, compensate, undo, and whether a success is tracked for undo.
  - Construct classes own what rollback means for them: `MapStep` replays its elements, and
    `ComposeStep` starts a fresh child on retry.
  - The executor keeps only orchestration.
- **Map (R-02–R-04)**:
  - `MapStep#compensate`/`#undo` replay each completed element's own undo stack, found through the
    element index both modes already write.
  - A fan-out map joins the parent's undo stack.
  - A fail-fast fan-out waits until every index has settled before it rolls back.
- **Compose (R-05, superseded by R-14)**: ~~a retry after a failed attempt starts a fresh child~~.
  A compose cannot be retried.
- **Failures (R-06–R-08, revised by R-15/R-16)**:
  - Argument errors become attributed never-started failures (condition errors no longer exist).
  - Every exception except interruptions rolls back.
  - Interruptions mark an inline run `aborted`.
- **async_step (R-09, R-10)**:
  - The unit compensates itself once in its own job after its final failure.
  - An inline `undo` is rejected at definition time; an `undo` inherited from a step class is
    warned.
  - Async units declare themselves as not tracked for undo.

## Technical Context

**Language/Version**: Ruby >= 3.0

**Primary Dependencies**: Sidekiq (async router), Redis (state, locks), dry-validation (contracts),
optional OpenTelemetry middleware. No new dependencies.

**Storage**: Redis via `RubyReactor::Storage::RedisAdapter`. The map element-context index,
map results hash, context rows and step result records already exist. New stored data:
`_skipped` result slots (R-04), `compensation` on the async step record (R-09), status value
`aborted` (R-08, R-16). The `compose_attempt_discarded` trace entry (R-05) is removed by R-14.

**Testing**: RSpec against real Redis (`redis://localhost:6780`). Sidekiq fake mode plus
`drain_async_jobs` for fan-out and async paths. The 007 evidence harness is used as the
regression check (SC-002). The demo app specs use the shipped matchers only.

**Target Platform**: Ruby gem (MRI), Sidekiq workers, Rails demo app in Docker

**Project Type**: Library (gem)

**Performance Goals**:

- Rollback of N succeeded map elements is linear in N and runs serially in the process that
  detected the failure.
- A 10,000-element map fails and rolls back without a storage size error (SC-006).
- Fail-fast fan-out reports failure only after the slowest element in flight settles. This is
  accepted and documented.

**Constraints**:

- Single-writer context rule: an async unit never writes its parent's context. Map rollback writes
  element contexts only after they settle, under each element's liveness lock (R-02 §5).
- No new per-element data in the parent blob (FR-008).
- Park signals (`Error::ExecutionParked`) never turn into failures.

**Scale/Scope**:

- About 14 library files touched (below).
- 6 new spec files, 1 tightened spec, and 1 updated evidence harness.
- 4 demo artifacts per behavior group (reactor, rake task, spec).
- 9 documentation files.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Status | Note |
| --- | --- | --- |
| I. Gem-First Design | PASS | All changes are inside `lib/`, behind the existing public API. No host coupling. The Sidekiq-specific parts stay in the existing workers and adapters. |
| II. Saga Pattern Integrity | PASS (this feature exists for it) | It closes four violations of "partial execution without a recovery path is forbidden". Every exception raised by reactor code now rolls back (R-16). Interruptions get an explicit recovery path (`aborted` plus manual undo, with only the not-yet-undone entries kept) instead of a silent forward resume. |
| III. Test-First with Real Infrastructure | PASS | Every behavior task writes its failing spec first against real Redis. Async paths use fake mode plus drain, never `inline!` (R-11). |
| IV. Observability by Default | PASS | New failures carry reactor name, step name, redacted inputs and reason (FR-017). `aborted` is added to the dashboard state model. Unit compensation is recorded on the unit's record, and compensation middleware events fire. Map rollback failures carry `map_step`/`element_index`. |
| V. Simplicity & SemVer | PASS with notes | The refactor is bounded to removing real duplicates (R-01). Full step self-execution was rejected. The revision deletes code: compose retries, `where`/`guard`, `ConditionError`. Six changes are breaking: element `undo`s run, `async_step` `compensate` runs, an inline `undo` on `async_step` raises, `retries` on `compose`/`async_reactor` raises, `where`/`guard` raise, and non-`StandardError` exceptions roll back instead of propagating. They are marked `!` and carry CHANGELOG migration notes (R-12). |
| VI. Demo-App Proof of Feature | PASS (planned) | Demo reactor, rake task and matcher-based spec for map rollback, a compose whose child step retries itself, failure rollback (argument error and non-`StandardError`), `async_step` compensate and `aborted`. See Project Structure. The tasks are added to `demo:all`. The removed DSL needs no demo: a reactor that uses it cannot load. |

- [x] Documentation impact identified (research R-13):
  - **README.md**: lines 16, 25, 35, 545-550, 1309 and 1398, plus the Compensation section.
  - **documentation/**: `data_pipelines.md`, `composition.md`, `background_and_async.md`,
    `core_concepts.md`, `DAG.md`, `locks_and_semaphores.md`, `interrupts.md`.
  - **007 analysis**: `execution-order.md` and `invariants.md`, refreshed.
  - **CHANGELOG.md**: entries with migration notes.
  - This is carried into tasks.md as a required task per user story.

**Post-design re-check (after Phase 1, revised 2026-09-27)**: PASS. No new abstraction beyond the
`StepConfig` methods that replace existing duplicates, and one matcher module (`Error::Rescuable`)
that replaces a repeated `rescue StandardError` with the review's rule. The only new public error
class is `ArgumentResolutionError`. There are no new DSL keywords, and three are removed.

## Project Structure

### Documentation (this feature)

```text
specs/008-rollback-reliability/
├── plan.md              # This file
├── research.md          # Phase 0: decisions R-01..R-13
├── data-model.md        # Phase 1: records, statuses, entry shapes
├── quickstart.md        # Phase 1: validation guide
├── contracts/
│   ├── rollback-semantics.md   # Per-construct rollback contract + sequences
│   └── api-surface.md          # DSL, errors, Failure/rollback_failures, statuses, events
├── checklists/requirements.md
└── tasks.md             # Phase 2 (/speckit-tasks)
```

### Source Code (repository root)

```text
lib/ruby_reactor/
├── dsl/step_builder.rb              # StepConfig: resolve_arguments, call_compensate, call_undo,
│                                    #   rollback_tracked? (R-01/R-06/R-10); where/guard stubs (R-15)
├── dsl/{compose,async_reactor}_builder.rb  # retries stub, no Retryable (R-14)
├── dsl/{interrupt,map}_builder.rb   # drop conditions/guards (R-15)
├── error/rescuable.rb               # new: rescue matcher, everything but interruptions (R-16)
├── dsl/async_macros.rb              # async_step: reject inline undo, warn on class undo (R-09)
├── error/argument_resolution_error.rb  # new (R-06)
├── executor.rb                      # rescue Rescuable → failure; rescue Exception → :aborted (R-08/R-16)
├── executor/step_executor.rb        # route resolution failures through result handling; use StepConfig ops
├── executor/compensation_manager.rb # NEVER_STARTED += ArgumentResolutionError; compensate under with_step;
│                                    #   public #compensate; dispatch via StepConfig; Rescuable; pop per entry
│                                    #   (R-01/R-02/R-06/R-16)
├── executor/result_handler.rb       # rollback on unknown errors + attribution; rollback_tracked? (R-07/R-10)
├── step/map_step.rb                 # real compensate/undo = element replay (R-02)
├── step/compose_step.rb             # fresh-child code removed (R-14)
├── map/helpers.rb                   # collector success pushes map step on parent undo stack (R-03)
├── map/collector.rb                 # fail-fast resolves only when no index is missing (R-04)
├── map/element_executor.rb          # skipped element stores _skipped slot (R-04)
├── map/dispatcher.rb                # on fail-fast, claim + settle undispatched indices (R-04)
├── map/result_enumerator.rb         # tolerate _skipped slots (R-04)
├── step_worker.rb                   # StepConfig ops; unit-local compensate + record (R-09)
├── storage/redis_reactor_scan.rb    # 'aborted' known status (R-08)
└── web/ (api.rb + UI filters)       # 'aborted' shown (R-08)

spec/ruby_reactor/rollback/
├── map_rollback_spec.rb
├── map_fan_out_settle_spec.rb
├── compose_retry_spec.rb        # rewritten for R-14
├── failure_rollback_spec.rb     # condition examples out, non-StandardError examples in (R-15/R-16)
├── aborted_execution_spec.rb    # Interrupt, mid-rollback interruption, enclosing Timeout (R-16)
├── removed_dsl_spec.rb          # new: where/guard rejected (R-15)
└── async_step_compensate_spec.rb
spec/ruby_reactor/dsl/async_step_spec.rb   # tightened (line ~111)

specs/007-execution-flow-analysis/evidence/probes/*.rb  # expected sequences updated for in-scope scenarios

demo_app/
├── app/reactors/{map_refund,compose_retry,argument_failure,async_step_compensate}_demo_reactor.rb
├── lib/tasks/demo_reactors.rake            # demo:map_rollback, :compose_retry, :failure_rollback,
│                                           #   :async_step_compensate, aggregate :rollback_reliability (in demo:all)
└── spec/reactors/<same names>_demo_reactor_spec.rb

README.md, documentation/*.md, CHANGELOG.md  # per R-13 / R-12
```

**Structure Decision**: single gem project. Changes stay within the existing `lib/ruby_reactor`
module layout. There are no new directories under `lib/`. The new specs are grouped under
`spec/ruby_reactor/rollback/` so the feature's coverage reads as one unit.

## Delivery Order

The user stories are independent. This order minimizes rework:

1. **Foundation (R-01)**:
   - `StepConfig` lifecycle methods: `resolve_arguments`, wrapping `should_run?` (removed by R-15), `call_compensate`,
     `call_undo`, `rollback_tracked?`.
   - `CompensationManager` dispatches through them and runs compensate under `with_step`.
   - This is a refactor with no behavior change. The existing suite stays green.
2. **US3 (P1) Failures**: R-06, R-07, R-08. These are the smallest changes, and they give every
   later failure its attribution.
3. **US2 (P1) Compose retry**: R-05.
4. **US1 (P1) Map**: R-02, then R-03 (fan-out undo stack), then R-04 (settle). This is the largest
   change.
5. **US4 (P2) async_step**: R-09.
6. **US5 (P3) One rule**: R-10, the refreshed F-10 table, the 007 docs refresh and the harness
   re-run (SC-002).
7. **Per story**: README and documentation edits, the demo artifacts and CHANGELOG. Each story ships
   its own docs and demo, not in a final batch (Constitution Development Workflow).
8. **Revision 2026-09-27** (steps 1-7 are done on the branch): R-14 (US2 rework), R-15 (US6), R-16
   (US3 rework), R-17 (docs), each with its specs, demo, docs and CHANGELOG, then the harness re-run
   and the full suite. R-18 lists the files.

## Risks

| Risk | Mitigation |
| --- | --- |
| Existing specs pin the old failure shapes ("Execution failed: …", "Execution error: …", no `step_name`) | Update them in the story that changes the shape, and note it in the CHANGELOG |
| Sweeper re-enqueues **in-progress** inline runs (running, no `async:` lock). This is pre-existing, and unchanged except that aborted runs are now excluded | Out of scope. Record it in `specs/future_improvements.md` |
| Element contexts that expire before a late rollback | Reported as `context_unavailable` in `rollback_failures`, never silent. `context_ttl` is documented as the rollback horizon |
| Flaky specs when suites share the test Redis | Run the new specs alone before debugging. Don't run the demo and gem suites concurrently |
| R-16 turns test assertion/mock errors raised inside step bodies into step failures, so an existing spec that relied on them propagating now sees a `Failure` | Run the full suite after the swap. A spec asserting on the result still fails loudly. Fix any spec that asserted inside a body by asserting on the result instead, and note the change in CHANGELOG |
| Removing compose `retries` and `where`/`guard` makes 007 probe files fail at load | Move those reactor definitions inside their scenario blocks so the rejection is the observed outcome |
| Demo Docker stack collides with other worktrees | Use an isolated compose project (`-p rr_<worktree>`) and an override file (quickstart) |

## Complexity Tracking

No Constitution violations to justify. The `StepConfig` lifecycle methods replace two duplicate
implementations (`resolve_arguments` in the executor and the worker, and compensate dispatch in
`CompensationManager` plus the new `StepWorker` need). They are not a new layer.
