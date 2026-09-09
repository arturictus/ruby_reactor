# Implementation Plan: Reactor Signal Semantics

**Branch**: `reactor_signals` | **Date**: 2026-09-09 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/001-reactor-signal-semantics/spec.md`

## Summary

Split today's overloaded `Skipped` signal into two: **`Halt`** (the existing
clean-stop behaviour, renamed) and a brand-new **`Skipped`** that marks one step
as skipped while the reactor continues, carrying a value exactly like `Success`
so `result(:step)` keeps working downstream. Add throw/catch-based step helpers
`success!` / `fail!` / `skip!` / `halt!` that exit the step body from any depth.
Give `Failure` a `retry:` spelling for its existing retry veto and pin down that
only `Failure` ever enters the retry machinery. Default `compensate`/`undo` to
`Skipped` so traces distinguish "ran" from "never written".

Technical approach: both new signals stay `Success` subclasses, so every
existing `when RubyReactor::Success` fallback keeps working and no dispatch site
can silently fall through to `handle_unknown_result`. The change is therefore a
rename plus two thin subclasses plus one `catch` block per step invocation —
not a rework of the executor.

## Technical Context

**Language/Version**: Ruby >= 3.0.0 (gem `required_ruby_version`)

**Primary Dependencies**: zeitwerk (core); dry-validation, sidekiq, active_job,
opentelemetry all optional and loaded defensively

**Storage**: Redis via `RubyReactor::Storage::RedisAdapter` — persists context
status, intermediate results, execution trace, undo stack

**Testing**: RSpec with a live Redis (enforced in `spec/spec_helper.rb`);
`Sidekiq::Testing` only for unit-level step logic

**Target Platform**: Ruby library (gem), sync and background-job execution

**Project Type**: Single-project Ruby gem

**Performance Goals**: No measurable change. One `catch` frame per step
invocation and per compensate/undo invocation; no added Redis round trips.

**Constraints**:
- Durable state written by older versions must still deserialise: contexts
  stored with `status: "skipped"` (old halt) are in flight during upgrade.
- `Skipped` is *reused* with inverted semantics, so an alias cannot preserve the
  old meaning — the old call shape must fail loudly (FR-006).
- The retry flag name `retryable` is written into serialized failures
  (`context_serializer.rb:45`), so `retry:` is added alongside it, not instead.

**Scale/Scope**: ~14 library files, ~6 documentation files, gem at v0.5.4
(pre-1.0, so a breaking rename ships as MINOR with a migration note).

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-checked after Phase 1 design.*

| Principle | Assessment | Verdict |
|-----------|------------|---------|
| I. Gem-First Design | All changes land in `lib/ruby_reactor/`; no host coupling; optional integrations (OTel, Sidekiq, ActiveJob) untouched except for status strings | PASS |
| II. Saga Pattern Integrity (NON-NEGOTIABLE) | `Halt` preserves the already-sanctioned no-compensation clean stop verbatim. New `Skipped` steps are not enrolled for rollback because they perform no side effect — the same guarantee a `Success` step without an `undo` already gives. Compensation coverage for side-effectful steps is unchanged | PASS (see note below) |
| III. Test-First with Real Infrastructure | Every task is Red-first; async and status-persistence scenarios run against live Redis, not mocks | PASS |
| IV. Observability by Default | Halted runs and skipped steps get distinct execution-trace types, distinct persisted status, distinct dashboard status, and distinct OTel attributes (FR-004, FR-011) | PASS |
| V. Simplicity and SemVer | Two thin `Success` subclasses, one shared helper module, one `catch` per invocation. Breaking rename on a 0.x gem ships MINOR with a CHANGELOG migration note (FR-035) | PASS |

**Principle II note**: the one way this feature could erode saga integrity is an
author using `skip!` for a step that *did* produce a side effect, which would
leave that effect un-rolled-back. This is a documentation boundary, not an
enforceable one (the library cannot detect side effects), and it is identical to
the existing hazard of a `Success` step that declares no `undo`. Documentation
(FR-034) must state the rule: **`Skipped` means nothing happened; if something
happened, return `Success` and declare an `undo`.**

No violations. Complexity Tracking table omitted.

**Post-design re-check (after Phase 1)**: still PASS. The design adds exactly
one file, two thin subclasses, one `catch` per invocation, and no new
dependency. Observability requirements gained concrete shapes (see
[data-model.md](./data-model.md) trace and status tables), and the SemVer
obligation is captured as FR-035. The Principle II note above stands as the one
documentation-enforced boundary.

## Project Structure

### Documentation (this feature)

```text
specs/001-reactor-signal-semantics/
├── plan.md              # This file
├── spec.md              # Feature specification
├── research.md          # Phase 0 output
├── data-model.md        # Phase 1 output
├── quickstart.md        # Phase 1 output
├── contracts/           # Phase 1 output
│   ├── signals.md
│   ├── step-helpers.md
│   └── observability.md
├── checklists/
│   └── requirements.md
└── tasks.md             # Phase 2 output (/speckit-tasks — NOT created here)
```

### Source Code (repository root)

```text
lib/ruby_reactor.rb                              # Success / Halt / Skipped / Failure + module-level builders
lib/ruby_reactor/
├── step.rb                                      # class-step helpers + compensate/undo defaults
├── step_signals.rb                              # NEW: success!/fail!/skip!/halt! + catch tag
├── dsl/
│   └── template_helpers.rb                      # inline-block helpers (same module)
├── executor.rb                                  # period gate, update_context_status, resume dispatch
├── executor/
│   ├── result_handler.rb                        # Halt vs Skipped vs Success routing
│   ├── step_executor.rb                         # step loop early-returns; catch around invocation
│   ├── compensation_manager.rb                  # compensate/undo defaults + catch + trace flags
│   ├── retry_manager.rb                         # only Failure enters retry
│   └── ordered_lock_support.rb                  # internal halts
├── storage/redis_adapter.rb                     # status whitelist (:halted, legacy "skipped")
├── web/api.rb                                   # dashboard status whitelist
├── map/sweeper.rb                               # terminal-status list
├── open_telemetry.rb                            # halted?/skipped? span attributes
├── context_serializer.rb                        # Halt/Skipped value round-trip
└── rspec/
    ├── matchers.rb                              # be_halted (new) + be_skipped (repurposed)
    └── test_subject.rb                          # status → result reconstruction

gui/                                             # React dashboard (source of the shipped bundle)
├── src/components/DagVisualizer.tsx             # per-step node state — the skipped/completed trap
├── src/components/StepInspector.tsx             # rollback list: ran vs never written
├── src/components/StatusBadge.tsx               # run status badge
├── src/components/ReactorDetail.tsx             # run status colour
├── src/components/LiveView.tsx                  # status filter
├── src/components/ReactorClassInstances.tsx     # status filter
├── src/lib/reactors.ts                          # status → success/running/error buckets
└── src/**/__tests__/                            # vitest suites

lib/ruby_reactor/web/public/                     # committed build output of gui/ (rake build:ui)

spec/ruby_reactor/                               # RSpec suites (mirrors lib layout)
documentation/                                   # core_concepts.md, testing.md, middlewares.md, examples/
README.md, llms.txt, llms-full.txt, demo_app/    # public-facing vocabulary
```

**Structure Decision**: Existing single-gem layout, unchanged. Exactly one new
file (`lib/ruby_reactor/step_signals.rb`) holding the four helpers and the catch
tag, mixed into both authoring surfaces so the helper semantics have one
definition rather than two.

## Design Decisions

Full rationale and rejected alternatives in [research.md](./research.md). The
five that shape the work:

1. **Both signals subclass `Success`.** `Halt` is today's `Skipped` renamed;
   `Skipped` is new and value-carrying. Keeping both under `Success` means every
   existing `when RubyReactor::Success` branch stays correct and nothing can
   fall into `handle_unknown_result` (which would wrap a signal as a plain
   value). Dispatch order at every `case` site becomes **Halt → Skipped →
   Success**.
2. **Non-local exit uses `throw`/`catch`**, not exceptions. Verified: `throw`
   passes straight through `rescue Exception` while still running `ensure`
   blocks — exactly FR-021. `rescue StandardError` in
   `safe_execute_step_sync` therefore cannot swallow a helper's exit.
3. **`retry:` rides in via `**opts`** on `Failure#initialize`, with `retryable:`
   still accepted (it is the name already written into serialized failures).
   `retry:` wins when both appear.
4. **The old halt call shape raises.** `Skipped.new` / `RubyReactor.Skipped()`
   now takes a value; a call whose only argument is `reason:` raises
   `ArgumentError` naming `Halt`. This is the whole migration mechanism — no
   deprecation cycle, no compatibility layer.
5. **Run status gains `:halted`**; a run never ends `:skipped` any more. Stored
   contexts still carrying the legacy `"skipped"` status are read as halted, so
   an in-flight upgrade does not strand runs.
6. **The dashboard derives step state from the trace, not from the presence of
   a value.** `DagVisualizer` currently paints any step with a stored result as
   completed — and a skipped step stores a result. Left alone, the new signal
   would be invisible in the DAG. Same class of bug in `StepInspector`, which
   labels every compensation trace entry "executed" and would therefore claim
   never-written compensation ran. Both read the trace instead (R12).

## Risks

| Risk | Mitigation |
|------|------------|
| A `is_a?(RubyReactor::Skipped)` site that means *halt* is missed, silently turning a halt into a continue | The rename makes every such site a compile-visible edit: `Skipped` keeps existing as a class, so grep alone is not enough — remove `skipped?` from the halt class so any missed site fails loudly on `NoMethodError`/false, and cover each of the 25 known sites with a task |
| Legacy `"skipped"` status in Redis during upgrade | Status whitelists accept both, reads translate `"skipped"` → halted |
| `throw` crossing a `Timeout`/`ensure` that re-raises | `ensure` semantics verified; documented in contracts |
| Map/element paths treat `Skipped` elements as failures or drop their values | `result_enumerator` greps `RubyReactor::Success`, so skipped elements already flow; element-level `Halt` needs an explicit branch (task) |
| Skipped steps render as completed in the DAG because they store a value | Derive node state from the execution trace, not value presence (R12); covered by a vitest fixture |
| Shipped dashboard bundle keeps the old vocabulary after release | `rake build:ui` output under `lib/ruby_reactor/web/public/` is committed as part of this change (FR-040) |
