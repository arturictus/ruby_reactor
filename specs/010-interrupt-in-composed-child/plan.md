# Implementation Plan: Interrupt Inside a Composed Child

**Branch**: `interrupt_inside_composed_child` | **Date**: 2026-10-08 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `specs/010-interrupt-in-composed-child/spec.md`

## Summary

A composed child already pauses itself correctly. Its parent then crashes on the
`InterruptResult`. The fix is mostly letting that result through, plus three gaps it exposes:

1. **Pass the pause up (US1)**: `InterruptResult` arms in `ComposeStep#handle_execution_result`,
   `RetryManager#handle_retry_result` and `ResultHandler#handle_step_result` (R-01).
   - The compose re-stamps the result with its own context id, so the top level reports the
     root's id (R-02).
   - The result-handler arm sets the root's `current_step` to the compose step, which is the
     resume cursor that `with_step` would otherwise clear (R-03).
2. **Name and resume (US2)**: a nested interrupt is an Array path. `Reactor#ready_interrupt_steps`
   (new, public) derives the pending paths from stored state (R-05).
   - `Reactor#continue` resolves `(target context, step config, leaf)` once and uses them for
     validation, attempts, background resume and `set_result` (R-06).
   - The resume itself is unchanged: the root re-runs the compose step, and `ComposeStep#run`
     re-enters the admitted child.
3. **Undo while paused (US3)**: the pausing compose joins the undo stack as a partial-run entry,
   the same entry an aborted compose gets. `add_to_undo_stack` replaces it when the compose later
   completes (R-04).
4. **Test surface (US4)**: `TestSubject#ready_interrupt_steps` delegates to the reactor, and
   `be_paused_at`/`have_ready_interrupts`/`resume` accept paths.
5. **Guards**:
   - a composed child refuses a direct `continue` (`private_data[:composed]`, R-07);
   - an interrupt inside a map element fails cleanly instead of `NoMethodError` (R-08).

## Technical Context

**Language/Version**: Ruby >= 3.0

**Primary Dependencies**: Sidekiq and ActiveJob adapters, Redis, dry-validation. No new
dependencies.

**Storage**: Redis through `Storage::RedisAdapter`. No new keys. One new `private_data[:composed]`
flag on composed child contexts (see [data-model.md](data-model.md)).

**Testing**: RSpec against real Redis (`redis://localhost:6780`), `for_each_async_backend` and
`drain_async_jobs` for the worker paths. Demo specs use the shipped matchers only.

**Target Platform**: Any Ruby process with Redis; workers via Sidekiq or ActiveJob.

**Project Type**: Library (gem), with `demo_app/` as the integration example.

**Performance Goals**: None new. `ready_interrupt_steps` builds one dependency graph per paused
level, and only on `continue` or in tests.

**Constraints**: Single-writer context rule: only the root run is stored and resumed as the
owner, and a pause is written to the embedded child, never to its observability row.

**Scale/Scope**: About 8 lib files touched, each change a few lines, except the `Reactor#continue`
target resolution. 1 new gem spec file, 1 un-pended example, 2 demo reactors, 1 rake task, 1 demo
spec, 4 doc files.

## Constitution Check

*Gate re-checked after Phase 1. No violations.*

| Principle | Status | Notes |
| --- | --- | --- |
| I. Gem-First | PASS | All in `lib/`; no host coupling. |
| II. Saga Integrity | PASS | Closes a gap: the "interrupts first-class" clause now holds inside a compose, and undo reaches a paused child's completed steps (R-04). |
| III. Test-First, Real Infra | PASS | Specs written failing first, on real Redis, across async backends. No `inline!` for orchestration. |
| IV. Observability | PASS | Paused root status and the embedded child are visible in the dashboard as today. A refused `continue` names the pending path. |
| V. Simplicity & SemVer | PASS | Pass-through arms; the path is derived, not stored; one public method added. MINOR (R-10), with a CHANGELOG entry. |
| VI. Demo-App Proof | PASS (planned) | `ManagerApprovalReactor` (child) and `ComposedApprovalReactor` (root) in `demo_app/app/reactors/`; `demo:composed_interrupt`; `demo_app/spec/reactors/composed_approval_reactor_spec.rb` using `be_paused_at([...])`, `resume(step: [...])`, `be_success`, `have_run_step`. Docker acceptance run. |

- [x] Documentation impact identified (carried into tasks.md as a required task):
  - **`documentation/composition.md`**: replace "An `interrupt` inside a composed child is not
    supported yet…" (rule 6) with the nested-pause behavior and a pointer to interrupts.md.
  - **`documentation/interrupts.md`**: new section "Interrupts inside composed reactors" covering
    the path form, correlation id on the root class, undo/cancel, a child that refuses a direct
    `continue`, and map elements unsupported.
  - **`README.md`**: one line in the *Interrupts (Pause & Resume)* section linking to it.
  - **`CHANGELOG.md`**: *Unreleased → Features*.
  - **`specs/future_improvements.md`**: drop the "Interrupt inside a composed child" entry.

## Project Structure

### Documentation (this feature)

```text
specs/010-interrupt-in-composed-child/
├── plan.md
├── research.md
├── data-model.md
├── quickstart.md
├── contracts/api-surface.md
├── checklists/requirements.md
└── tasks.md             # /speckit-tasks
```

### Source Code (repository root)

```text
lib/ruby_reactor/
├── step/compose_step.rb               # R-01/R-02 pass-through + re-stamp; R-07 mark child composed
├── executor/retry_manager.rb          # R-01 InterruptResult arm
├── executor/result_handler.rb         # R-01/R-03/R-04 arm: cursor + partial-run undo entry
├── executor/compensation_manager.rb   # R-04 replace top entry for the same step
├── executor/step_executor.rb          # R-08 interrupt inside a map element → Failure
├── reactor.rb                         # R-05 ready_interrupt_steps; R-06 path in continue; R-07 guard
└── rspec/
    ├── test_subject.rb                # delegate ready_interrupt_steps; resume(step: path)
    └── matchers.rb                    # be_paused_at / have_ready_interrupts accept paths

spec/
├── ruby_reactor/interrupt_in_compose_spec.rb   # new
└── map/map_compose_fan_out_spec.rb             # un-pend; add a child fixture with an interrupt after the map

demo_app/
├── app/reactors/manager_approval_reactor.rb    # child: reserve → interrupt :wait_for_manager → confirm
├── app/reactors/composed_approval_reactor.rb   # root: charge → compose :approval → ship
├── lib/tasks/demo_reactors.rake                # demo:composed_interrupt
└── spec/reactors/composed_approval_reactor_spec.rb
```

**Structure Decision**: Existing gem layout. No new lib files: each change sits where the
`InterruptResult` is already handled for root-level pauses.

## Implementation Order

Test-first within each step:

1. **US1**: pass-through arms, re-stamp, cursor. Spec: root pauses at depth 1 and 2, sync and
   after a fan-out map (un-pend FR-015).
2. **US2**: `ready_interrupt_steps`, target resolution in `continue`, composed-child guard. Specs:
   - resume by id and by correlation id;
   - wrong path;
   - background resume;
   - `max_attempts`;
   - two interrupts in sequence;
   - a root interrupt ready alongside.
3. **US3**: partial-run undo entry and its replacement. Specs: undo while paused (plain child, and
   a child with a fan-out map), cancel then continue, and an undo after completion that undoes the
   compose once.
4. **US4**: test subject and matchers.
5. **Guard R-08**: map element interrupt, inline and fan-out.
6. **Demo** reactors, rake task, demo spec, Docker acceptance run.
7. **Docs, CHANGELOG, `future_improvements.md`**, then full `rspec` and `rubocop`.

## Complexity Tracking

No violations to justify.
