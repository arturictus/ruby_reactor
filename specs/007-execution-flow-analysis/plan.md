# Implementation Plan: Execution Flow & Compensation Analysis

**Branch**: `execution_flow_analysis` | **Date**: 2026-09-26 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `specs/007-execution-flow-analysis/spec.md`

## Summary

A documentation-only research project. It maps how RubyReactor orders forward execution and
rollback (compensate + undo) across plain steps, `compose`, `map` (inline and fan-out), `async_step`,
`async_reactor`, `background` reactors and interrupts, under locks, retries and every failure kind.
It answers the user's three open questions (map element rollback, rollback of earlier composed
reactors, map-level `compensate_all`/`compensate_each`).

Approach: read the executor source and cite it by `file:line`. Confirm each headline claim with a
small **probe**, a throwaway reactor run against the real test Redis through the real worker code
paths (Sidekiq fake mode + drain). Each probe prints its observed event sequence next to the
sequence the report claims. Deliverables are Markdown under this feature directory. Library code,
the test suite and the demo app are not touched.

## Technical Context

**Language/Version**: Markdown + Mermaid (report); Ruby >= 3.0 (probe scripts only, run against
`lib/` of this checkout)

**Primary Dependencies**: `ruby_reactor` (this checkout), `sidekiq/testing` fake mode, the
`RubyReactor::RSpec::SidekiqHelpers.drain_async_jobs` helper (plain-Ruby callable), `redis` gem

**Storage**: Test Redis at `redis://localhost:6780` (`RUBY_REACTOR_TEST_REDIS_URL` overrides), the
same instance `spec/spec_helper.rb` uses

**Testing**: Probes check themselves. Each scenario declares the expected event sequence and prints
`MATCH` / `MISMATCH` with both sequences. No RSpec files are added (FR-011).

**Target Platform**: Developer machine / CI shell with Redis reachable

**Project Type**: Library research (no runtime change)

**Performance Goals**: N/A. Full probe run should finish in under 1 minute, so it can be re-run
as behavior changes.

**Constraints**: Zero diff under `lib/`, `spec/`, `demo_app/`, `README.md`, `documentation/`
(SC-005). Probes must not sleep on real backoff (use `base_delay: 0`/tiny delays).

**Scale/Scope**: 6 constructs (step, compose, map, async_step, async_reactor, background reactor)
+ interrupts × failure positions (before / inside / after, nested) × modes (inline / worker) ×
cross-cutting conditions (reactor lock, step lock/semaphore, ordered lock, retries, failure
kinds). Roughly 40–60 matrix cells, 25–40 invariants.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Status | Note |
|---|---|---|
| I. Gem-First Design | PASS (N/A) | No `lib/` change. |
| II. Saga Pattern Integrity | PASS | The research exists to check this principle; findings feed later remedies. |
| III. Test-First with Real Infrastructure | PASS | No product code, so no Red-Green cycle. Probes use real Redis and real worker bodies, no mocks, matching the principle's intent. |
| IV. Observability by Default | PASS (N/A) | No runtime change. Probes observe through the shipped middleware hooks. |
| V. Simplicity & SemVer | PASS | No version bump, no API change. |
| VI. Demo-App Proof of Feature | N/A (justified) | Not a user-facing feature or public API change. No demo reactor/rake/spec. Any remedy chosen later carries its own demo. |
| Dev Workflow: docs task | PASS with deviation (see Complexity Tracking) | The documentation task here is an **audit**. Every README/documentation claim contradicted or left unstated by the findings is listed with `file:line` in the findings report. Editing those files is deferred to the remedy features, because behavior does not change here. |

- [x] Documentation impact identified: README.md sections "Error Handling and Compensation",
      "async_step" / "Compensation is opt-in", "async_reactor"; `documentation/composition.md`
      (`async_reactor` vs `compose` table); `documentation/background_and_async.md` ("Compensation
      is opt-in", "Error Handling and Compensation"); `documentation/data_pipelines.md` (fail_fast);
      `documentation/core_concepts.md` ("Compensation Order"); `documentation/DAG.md`. All are
      **audited**, not edited (tasks.md carries the audit task).

**Post-design re-check (after Phase 1)**: unchanged. All gates PASS. The one deviation is tracked below.

## Project Structure

### Documentation (this feature)

```text
specs/007-execution-flow-analysis/
├── spec.md
├── plan.md                    # this file
├── research.md                # Phase 0: method decisions + preliminary hypotheses
├── data-model.md              # Phase 1: scenario / event / invariant / finding / option shapes
├── quickstart.md              # Phase 1: how to run probes and validate the report
├── contracts/
│   └── report-structure.md    # Phase 1: required sections + ID/label conventions
├── checklists/
│   └── requirements.md
├── tasks.md                   # Phase 2 (/speckit-tasks)
├── analysis/                  # Deliverable (/speckit-implement)
│   ├── README.md              # index, reading guide, answers to the 3 questions (US2)
│   ├── execution-order.md     # construct lifecycles (FR-001) + order matrix (FR-002/003/012)
│   ├── invariants.md          # invariants w/ status, evidence, test coverage (FR-006/008)
│   └── findings-and-options.md# findings + doc audit (FR-009) and options (FR-010)
└── evidence/                  # Reproducible observations (FR-007, SC-003)
    ├── harness.rb             # recorder middleware, scenario DSL, Redis/Sidekiq setup
    ├── probes/*.rb            # one file per area: plain, compose, map, async, coordination, edge
    ├── run.rb                 # loads harness + probes, prints results
    └── output.txt             # captured run transcript cited by the report
```

### Source Code (repository root)

No source changes. Read-only inputs:

```text
lib/ruby_reactor/executor.rb                  # execute / resume_execution / lock lifetime
lib/ruby_reactor/executor/*.rb                # step loop, retries, result handling, rollback, coordination
lib/ruby_reactor/step/{compose,map,async_reactor}_step.rb
lib/ruby_reactor/map/*.rb                     # dispatcher, element executor, collector, helpers
lib/ruby_reactor/step_worker.rb, worker.rb    # async_step unit, reactor worker
lib/ruby_reactor/reactor.rb                   # run / continue / undo / cancel
lib/ruby_reactor/template/result.rb           # async result read semantics
spec/**                                       # mapped for invariant coverage (FR-008)
README.md, documentation/*.md                 # audited for claims (FR-009)
```

**Structure Decision**: Everything lives under `specs/007-execution-flow-analysis/`. The report
is split into four files by question type (what order? what always holds? what is wrong and what
could we do?), plus an index. Probes are grouped by area into a handful of files so each report
claim can cite `probe-id` and the transcript line.

## Complexity Tracking

| Violation | Why Needed | Simpler Alternative Rejected Because |
|-----------|------------|-------------------------------------|
| Docs task is an audit, not README/documentation edits | This feature changes no behavior. The research shows some current behavior may be unintended (e.g. map rollback is a `TODO`). | Writing current behavior into README/documentation now would present possibly buggy semantics as contract before the follow-up decision. Each remedy feature updates the docs itself. |
| Probe scripts (Ruby) inside a documentation-only feature | SC-003 requires reproducible observations, not only source reading. | Reading alone can't settle ordering in multi-process paths (collector, step worker). Adding RSpec files would change the test suite (FR-011). |
