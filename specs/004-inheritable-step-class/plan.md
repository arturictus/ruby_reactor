# Implementation Plan: Inheritable Step Class

**Branch**: `004-inheritable-step-class` | **Date**: 2026-09-11 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/004-inheritable-step-class/spec.md`

**Note**: This template is filled in by the `/speckit-plan` command. See `.specify/templates/plan-template.md` for the execution workflow.

## Summary

Replace the mixin-based step authoring surface (`include RubyReactor::Step` on a plain
class + `def self.run(args, context)`, with input enforcement hacked in via
`singleton_class.prepend`) with a single inheritable base class, `RubyReactor::Step`. A
step author subclasses it, declares `input`/`validate_inputs` on the class exactly as
today, and writes `run`/`undo`/`compensate` as **instance** methods that read validated
inputs and the context through accessors. The base class's class-level `run` (aliased
`call`), `undo`, and `compensate` become the library's one entry point per lifecycle
action: build a fresh instance, enforce the input contract, invoke the instance method,
and translate any `StepSignals` throw into the matching result wrapper — all as ordinary,
readable method calls instead of a prepended module. Owning the signal catch in the base
class also closes a latent bug: `StepWorker` has no catch today, so a `fail!` inside a
class step run by `async_step`/`background` currently surfaces as an `UncaughtThrowError`
(research.md D4). No dual authoring style, no backward-compatibility shim: the mixin form
is deleted, and every internal step (`ComposeStep`, `MapStep`, `AsyncReactorStep`), every
demo step, and every spec step migrates to the new class in this change.

## Technical Context

**Language/Version**: Ruby >= 3.0.0 (gemspec `required_ruby_version`, unchanged)

**Primary Dependencies**: `dry-validation` ~> 1.10 (existing, unchanged — input contract
enforcement already built on it via `RubyReactor::Validation`); no new runtime dependency

**Storage**: N/A for this feature — no schema/persistence format changes. Serialization of
step arguments (`ContextSerializer`) is unaffected because it operates on plain
hashes/context, not on step instances.

**Testing**: RSpec (existing `spec/` suite + `demo_app/spec/reactors/` per Constitution
Principle VI); Redis required and reachable per Constitution Principle III — no test
strategy change, only the step classes under test change shape.

**Target Platform**: Ruby gem, consumed by Rails/plain-Ruby host applications; no
platform-specific change.

**Project Type**: Single library project (gem) — `lib/ruby_reactor/`, `spec/`, plus the
`demo_app/` Rails integration example mandated by Principle VI.

**Performance Goals**: No new performance target. One additional object allocation per
step invocation (the step instance, replacing the singleton-class call) is expected to be
negligible relative to existing Redis I/O per step; this plan carries no dedicated
benchmark task because the spec sets no throughput/latency success criterion.

**Constraints**: Every existing execution path (synchronous, async worker, retry,
compensation/undo, compose, map, RSpec test-subject interception) MUST keep producing
identical outcomes (spec User Story 2); the base class MUST NOT intercept or wrap
author-defined methods (spec FR-011); no compatibility shim (spec FR-012, project
IMPORTANT note — no production usage yet).

**Scale/Scope**: Touches one core file (`lib/ruby_reactor/step.rb`), the three built-in
step implementations, every step-shaped spec support file and example under `spec/` and
`demo_app/`, and the step-authoring sections of `README.md` and `./documentation`. No new
files outside `lib/ruby_reactor/step/` are structurally required; this is a targeted
internal refactor of an existing subsystem, not new surface area.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

- **I. Gem-First Design** — PASS. `RubyReactor::Step` stays a plain Ruby class reachable
  via `require "ruby_reactor"`, no host-application coupling introduced, no new optional
  integration added.
- **II. Saga Pattern Integrity (NON-NEGOTIABLE)** — PASS, with explicit verification
  required. Compensation/undo must keep working identically per-step (spec User Story 2,
  scenarios 3–5); Phase 1 design and the resulting tasks MUST prove undo/compensate run on
  a fresh instance from stored values only (no leftover run-time instance state crossing
  process boundaries in async execution) — this is the highest-risk gate for this feature
  and is called out explicitly in Complexity Tracking below.
- **III. Test-First with Real Infrastructure** — PASS. No test strategy change; the
  existing RSpec + real-Redis suite is the verification mechanism, run before and after
  migration to prove identical behavior (spec SC-003).
- **IV. Observability by Default** — PASS. Failure attribution (step name, redacted
  inputs, failure reason) is unchanged in shape; `InputValidationError#step_name` and
  `#step_arguments` continue to be set at the same point in the enforcement path, just
  from inside the base class's class-level entry point instead of a prepended module.
- **V. Simplicity and Semantic Versioning (YAGNI)** — PASS, and this feature exists
  *because of* this principle: it removes a `singleton_class.prepend` workaround. Per
  spec Assumptions, dual authoring styles are explicitly rejected as unjustified
  complexity. This is a breaking public-API change (mixin form removed with no
  deprecation) — `CHANGELOG.md` MUST record it under a breaking-change heading per
  Development Workflow. The gem is pre-1.0 (0.7.0) and `.release-please-config.json` sets
  `bump-minor-pre-major: true`, so a `feat!:` commit yields **0.8.0**; release-please
  owns the number, `version.rb` is never hand-edited.
- **VI. Demo-App Proof of Feature (NON-NEGOTIABLE)** — PASS, tracked as an explicit task.
  All existing `demo_app/app/reactors/*.rb` steps using the mixin form MUST convert to the
  new base class (7 occurrences in 3 files, plus 6 in 2 `demo_app/spec/` files —
  research.md D8), and a new demo reactor
  demonstrating the inheriting style end-to-end (success + failure/rollback path, plus a
  brownfield service adapter per spec User Story 3) MUST be added with a matching rake
  task and RSpec-matcher-only spec.
- [x] Documentation impact identified: `README.md` step-authoring sections (Quick Start /
      core usage examples) and every file under `./documentation` that shows
      `include RubyReactor::Step` (`getting_started.md`, `core_concepts.md`,
      `composition.md`, `async_reactors.md`, `README.md` inside `documentation/`, and the
      two files under `documentation/examples/`) MUST be updated to the inheriting form,
      carried into `tasks.md` as required documentation tasks (Constitution Development
      Workflow).

No unjustified violations. Proceeding to Phase 0.

## Project Structure

### Documentation (this feature)

```text
specs/004-inheritable-step-class/
├── plan.md              # This file (/speckit-plan command output)
├── research.md          # Phase 0 output (/speckit-plan command)
├── data-model.md        # Phase 1 output (/speckit-plan command)
├── quickstart.md        # Phase 1 output (/speckit-plan command)
├── contracts/           # Phase 1 output (/speckit-plan command)
│   └── step-lifecycle.md
└── tasks.md             # Phase 2 output (/speckit-tasks command - NOT created by /speckit-plan)
```

### Source Code (repository root)

```text
lib/ruby_reactor/
├── step.rb                       # REWRITTEN: `class Step` replaces `module Step` (mixin)
├── step_signals.rb                # comment only: catch-site list now names RubyReactor::Step (D4)
├── step_worker.rb                 # unchanged call site; gains correct signal handling via base class (D4)
├── step/                          # every file here flips `module Step` → `class Step` together (D9)
│   ├── input_contract.rb          # namespace line only; contract logic unchanged
│   ├── compose_step.rb            # MIGRATED: `class ComposeStep < RubyReactor::Step`; dead initialize deleted (D6)
│   ├── map_step.rb                # MIGRATED: `class MapStep < RubyReactor::Step`; build_mapped_inputs/resolve_element stay class-level (D6)
│   └── async_reactor_step.rb      # MIGRATED: `class AsyncReactorStep < RubyReactor::Step`
├── executor/
│   ├── step_executor.rb           # unchanged call sites (`impl.run(args, ctx)`)
│   └── compensation_manager.rb    # unchanged call sites (`impl.compensate` / `impl.undo`)
├── map/helpers.rb                 # unchanged; still calls MapStep.build_mapped_inputs (class-level)
├── rspec/
│   └── test_subject.rb            # unchanged call sites (`step_config.impl.run(args, ctx)`)
└── dsl/
    └── template_helpers.rb        # unchanged (inline block steps keep `include StepSignals`)

spec/
├── ruby_reactor/step_contract_*.rb, step_signals_spec.rb, step/map_step_spec.rb, …  # step classes rewritten to subclass form
├── ruby_reactor/dsl/*step*_spec.rb                                                   # step classes rewritten to subclass form
└── support/reactors/*.rb                                                             # shared example steps rewritten to subclass form

demo_app/
├── app/reactors/*.rb                     # 19 mixin usages migrated to subclass form
├── app/reactors/<new>_reactor.rb          # NEW demo reactor for inheriting style + brownfield adapter
├── lib/tasks/demo_reactors.rake           # NEW `demo:` task entry for the above
└── spec/reactors/<new>_reactor_spec.rb    # NEW spec, shipped matchers only

README.md, documentation/*.md, CHANGELOG.md   # updated per Constitution Development Workflow
```

**Structure Decision**: Single-project Ruby gem layout (existing `lib/`/`spec/` +
`demo_app/` integration example). No new top-level directories. This is a rewrite of one
subsystem (`lib/ruby_reactor/step.rb` and its three built-in consumers) plus a
find-and-migrate pass over every place a step class is authored, not a new component.

## Complexity Tracking

> **Fill ONLY if Constitution Check has violations that must be justified**

No constitution violations. This table instead records the one design risk Phase 0 must
close out before Phase 1 proceeds (Principle II gate above):

| Risk | Why it exists | How Phase 0/1 must resolve it |
|------|----------------|-------------------------------|
| Undo/compensate must not depend on run-time instance state | Async execution runs `run` in one worker process and `undo`/`compensate` in a possibly later, separate invocation; today's design (three independent `self.` methods) cannot leak state between them by construction, but instance methods on one class could tempt an author (or the built-in steps) into memoizing something in `run` and reading it in `undo` | `research.md` decides the instantiation contract (a **fresh instance per lifecycle action**, built only from the stored arguments/result/context — never a shared instance across run and undo); `data-model.md` documents accessors as read-only derived from constructor args, with no cross-action mutable state, and this is stated as a load-bearing rule in the base class's own comments (spec FR-009, FR-011) |
