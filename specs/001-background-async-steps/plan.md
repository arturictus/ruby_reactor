# Implementation Plan: Background Execution & Real Async Steps

**Branch**: `001-background-async-steps` | **Date**: 2026-08-16 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/001-background-async-steps/spec.md`

## Summary

Replace the confusing per-step `async: true` flag (only the first flagged step in a reactor actually takes effect — the rest are silently ignored) with a single, unambiguous reactor-level `background after: :step_name` declaration that hands off all remaining steps to an independent worker job. Add two genuinely new capabilities on top of that: `async_step`, whose unit of work is dispatched to run in its own independent worker while the rest of the reactor keeps executing in the calling process; and `async_reactor`, which dispatches a whole nested reactor to run independently, linked to the parent by execution id but excluded from the parent's compensation graph. Both `async_step` and `async_reactor` results are consumed via the existing `result(:name)` template helper, which gains a blocking-poll wait when the referenced work hasn't finished yet. Per the clarified spec, neither `async_step` nor `async_reactor` failures auto-compensate the parent — compensation only happens if a later step explicitly reads the result and decides to fail. All dispatch continues to go through the existing pluggable `configuration.async_router` (Sidekiq or ActiveJob), unchanged.

## Technical Context

**Language/Version**: Ruby >= 3.0.0 (per constitution's Technical Constraints)

**Primary Dependencies**: `sidekiq` and/or `activejob` (pluggable via `RubyReactor::Configuration#async_router`, already introduced by the ActiveJob Support feature on `main`), `redis` (storage), `dry-validation` (input validation DSL, unaffected by this feature)

**Storage**: Redis via `RubyReactor::Storage::RedisAdapter` (implements `RubyReactor::Storage::Adapter`). This feature adds one new storage primitive pair for per-step async results (see data-model.md) modeled directly on the existing `store_map_result` / `retrieve_map_results` pair used by `map`.

**Testing**: RSpec (mandatory per constitution). New behavior is tested via the existing `RubyReactor::RSpec::TestSubject` DSL (`test_reactor`, `have_run_step`, `drain_async_jobs`/`process_pending_jobs` via `AsyncTestHelpers`), extended only where the current interceptor logic hardcodes the old per-step `async?` flag (`lib/ruby_reactor/rspec/test_subject.rb` `prepare_execution_class`/`apply_mock_interceptor`). No parallel test infrastructure — per explicit instruction, only the gem's built-in spec helpers are used, adding new helper methods to the existing modules where a gap is found rather than inventing new ones.

**Target Platform**: Server-side Ruby (gem consumed by Rails/Sinatra-style host apps); demo validated against `demo_app/` (Rails app already in the repo)

**Project Type**: Library (Ruby gem) with a bundled `demo_app/` integration example — matches the constitution's Gem-First Design principle

**Performance Goals**: Not a throughput-sensitive change — dispatch overhead should stay within the same order of magnitude as the existing `map` per-element dispatch path it reuses patterns from. No new SLO introduced.

**Constraints**: Blocking waits on `result()` (FR-005) must use a bounded poll loop against Redis, never an unbounded `sleep`/`BLPOP`, honoring a single library-wide `Configuration#async_wait_timeout` (new knob, see data-model.md). Must not change behavior of the untouched reactor-level `async` flag (`self.class.async?`, "Full Reactor Async"), of `compose`'s execution/compensation semantics (its `async` flag is removed with the shared `StepConfig` flag, per FR-003 — see contracts/public-dsl.md), or of `map` (including its map-internal `async` element-dispatch option, which is a different mechanism and stays).

**Scale/Scope**: Single-gem change; touches DSL (`dsl/reactor.rb`, `dsl/step_builder.rb`), executor (`executor/step_executor.rb`, `dependency_graph.rb`), a new async-step worker/adapter pair (mirroring `Adapters::{Sidekiq,ActiveJob}::MapElementWorker`), `template/result.rb`, `storage/adapter.rb` + `storage/redis_adapter.rb`, `configuration.rb`, RSpec helpers, the bundled web dashboard (`lib/ruby_reactor/web/api.rb` + `gui/src/components/{DagVisualizer,StepInspector}.tsx`, per FR-014), `demo_app/`, `documentation/`, `README.md`.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

- **I. Gem-First Design**: PASS. New DSL (`background`, `async_step`, `async_reactor`) ships in `lib/ruby_reactor/dsl/`; the new worker class ships in both `lib/ruby_reactor/adapters/sidekiq/` and `lib/ruby_reactor/adapters/active_job/`, mirroring the existing adapter-isolation pattern — no host-application coupling, Sidekiq/ActiveJob stay optional per the existing pluggable-router mechanism.
- **II. Saga Pattern Integrity (NON-NEGOTIABLE)**: PASS, with a deliberate, spec-clarified narrowing. `background after:` hand-off preserves full compensation (it is the same underlying mechanism as today's step-level hand-off, just triggered once and unambiguously). `async_step`/`async_reactor` do NOT auto-compensate on failure — this was explicitly clarified with the user (see spec Clarifications) as an intentional escape hatch mirroring the existing `compose`/whole-reactor-async model, not a silent gap: a later step that reads the result via `result(:name)` can always trigger compensation itself, so no failure is ever unrecoverable, it is opt-in rather than automatic. This mirrors the already-shipped behavior of `async_reactor`-adjacent whole-reactor `async true` composition today, so it is not a new category of principle exception.
- **III. Test-First with Real Infrastructure**: PASS. Tests use RSpec against real Redis (per constitution, no mocked Redis for integration/contract-level specs); `async_step`/`async_reactor` dispatch tests exercise the real `Sidekiq::Testing.fake!` / ActiveJob `:test` adapter drain path already wired into `TestSubject`.
- **IV. Observability by Default**: PASS, and specifically checked against "The web dashboard MUST remain current with the reactor state model": FR-012 requires structured log entries (reactor name, step name, execution id) for hand-off/dispatch/completion, following the existing `middlewares.on(:before_async_enqueue, ...)` pattern; FR-008/FR-014 additionally require the async link to be recorded on the parent's own context (reusing `composed_contexts`, the same field `compose`/`map` already use — research.md decision 8) and rendered/drillable in `Web::API` + the `gui/` dashboard, not just logged. An earlier pass of this plan only logged the link and missed the dashboard requirement; corrected after review.
- **V. Simplicity and Semantic Versioning**: PASS. This is a MAJOR (breaking) change to the public step DSL (removal of per-step `async`), documented per FR-013. The design deliberately reuses three existing mechanisms (step-level hand-off in `StepExecutor#handle_async_step`, `map`'s per-unit dispatch-and-collect pattern, and the existing `AsyncResult`/`result()` template mechanism) rather than inventing a fourth. No speculative per-reactor/per-reference timeout override is introduced (resolved via clarification) — a single global config value only, added when a second real use case exists.

No violations requiring the Complexity Tracking table.

## Project Structure

### Documentation (this feature)

```text
specs/001-background-async-steps/
├── plan.md              # This file (/speckit-plan command output)
├── research.md          # Phase 0 output (/speckit-plan command)
├── data-model.md         # Phase 1 output (/speckit-plan command)
├── quickstart.md        # Phase 1 output (/speckit-plan command)
├── contracts/            # Phase 1 output (/speckit-plan command)
│   └── public-dsl.md
└── tasks.md              # Phase 2 output (/speckit-tasks command - NOT created by /speckit-plan)
```

### Source Code (repository root)

```text
lib/ruby_reactor/
├── dsl/
│   ├── reactor.rb                  # ADD: `background after:`, `async_step`, `async_reactor` class macros
│   │                                #      + definition-time guards (dup background, unknown step,
│   │                                #      background×async-true, returns×async-unit);
│   │                                #      whole-reactor `async` stays
│   ├── step_builder.rb             # REMOVE: `async` step-level flag (raise on use, FR-003)
│   └── compose_builder.rb          # REMOVE: `async` flag too — it sets the same StepConfig flag
│                                    #         (raise on use, FR-003); map_builder.rb untouched
├── executor/
│   └── step_executor.rb            # REPLACE: `handle_async_step` keyed off reactor's single
│                                    #          `background_after` step, not per-step `async?`;
│                                    #          ADD: async_step dispatch (fire-and-continue, marks the
│                                    #          node complete in the DependencyGraph at dispatch time so
│                                    #          siblings aren't blocked) and async_reactor dispatch
├── dependency_graph.rb             # UNCHANGED (no schema change; dispatch-time complete_step is
│                                    # called by the executor, see data-model.md)
├── adapters/
│   ├── sidekiq/step_worker.rb      # NEW: independent one-shot worker for a single async_step
│   └── active_job/step_worker.rb   # NEW: ActiveJob counterpart
├── template/
│   └── result.rb                   # UPDATE: block-poll wait when the referenced step/reactor result
│                                    #         is not yet available (FR-005)
├── storage/
│   ├── adapter.rb                  # ADD: `store_step_result` / `retrieve_step_result` interface methods
│   │                                #      (async_step outcome only — async_reactor reuses the existing
│   │                                #      retrieve_context/find path, no new primitive needed there)
│   └── redis_adapter.rb            # implement them (mirrors store_map_result/retrieve_map_results)
├── configuration.rb                # ADD: `async_wait_timeout` config knob
├── web/
│   └── api.rb                      # UPDATE: `determine_step_type`/`build_structure` (drop removed
│                                    #         `config.async?` field, add async_step/async_reactor
│                                    #         branches) and `hydrate_composed_contexts` (resolve the
│                                    #         two new composed_contexts ref types) — FR-008, FR-014
└── rspec/
    └── test_subject.rb             # UPDATE: `prepare_execution_class`/interceptors to understand
                                     #         `background_after`/`async_step`/`async_reactor` instead
                                     #         of the removed per-step `async?`; ADD `#async_step`/
                                     #         `#async_reactor` traversal helpers mirroring `#composed`/`#map`

gui/src/components/
├── DagVisualizer.tsx               # UPDATE: render 'async_step'/'async_reactor' step types (FR-014)
└── StepInspector.tsx               # UPDATE: same

spec/ruby_reactor/                  # gem's own unit/integration specs (mirrors lib/ layout above)
spec/support/reactors/              # new fixture reactors for background/async_step/async_reactor

demo_app/app/reactors/
├── full_async_reactor.rb           # UNCHANGED (whole-reactor async, out of scope)
├── partial_async_reactor.rb        # REPLACED by a `background_after`-based example (old per-step
│                                    # `async true` syntax is removed, FR-003)
├── async_step_reactor.rb           # NEW: demonstrates async_step + result() wait (send_email example)
└── async_reactor_demo_reactor.rb   # NEW: demonstrates async_reactor fire-and-forget vs. awaited
demo_app/spec/reactors/             # matching specs, using the same built-in TestSubject helpers

documentation/
├── async_reactors.md               # REWRITE the "Step-Level Async" section to `background after:`;
│                                    # ADD sections for `async_step` and `async_reactor`
└── composition.md                  # cross-reference `async_reactor` vs. `compose`
demo_app/documentation/             # kept in sync with the same edits (duplicate copy, see research.md)

README.md                           # rewrite "Step-Level Async" subsection, add async_step/async_reactor
CHANGELOG.md                        # breaking-change entry (FR-013)
```

**Structure Decision**: Single-project Ruby gem layout (existing `lib/ruby_reactor/**`, `spec/**`, plus the bundled `demo_app/` Rails integration example and `documentation/**`). No new top-level directories — every change lands inside the existing module boundaries (`dsl/`, `executor/`, `adapters/`, `template/`, `storage/`, `rspec/`), consistent with Principle I (Gem-First Design).

## Complexity Tracking

*No Constitution Check violations — table not needed.*
