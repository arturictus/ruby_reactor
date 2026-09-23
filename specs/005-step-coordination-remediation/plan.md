# Implementation Plan: Step Coordination Review Remediation

**Branch**: `independent_step_locks` | **Date**: 2026-09-23 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `specs/005-step-coordination-remediation/spec.md`

## Summary

Fix the ten defects that the review of 003 found (F1–F9) or that planning found (F10), without
restarting 003's design. Fix the two root causes once, and the rest individually.

- **A. One park mechanism** (F2, F4, F10):
  - A contention park becomes an exception, `Error::StepContentionPark`, a sibling of
    `AsyncResultPending` under a new `Error::ExecutionParked`.
  - Every executor on the stack parks its own holds as the exception passes. The `Worker`, or
    `Map::ElementExecutor`, requeues once, at the top, after all of them have saved.
  - An explicit `admitted` marker replaces inferring "first run" from `current_step`, so
    quotas are charged once at any depth.
  - `safe_execute_step_sync` stops swallowing park signals. That swallowing is F10: a
    background-result wait inside a composed child failed the parent.
- **B. One ordered-lock gate** (F3, F7, F8):
  - Both levels use one exhaustive gate classifier.
  - The step-level position lifecycle is decided once and finished in `ensure`.
  - A synchronous out-of-turn arrival hands its position back with `failed: false`.
- **C. Rollback under contention** (F1): a new `rollback_wait:` defaults to the lock's `ttl`,
  and `Failure#rollback_failures` lists every undo that did not complete.
- **D. Background step park state** (F5) moves from the parent's root blob to the step's own
  result record.
- **E. Isolated items**: F9, attribution for a direct call; F6, docs; F4, docs.

Design decisions and evidence, including the verification of every review claim and the F10
repro, are in [research.md](./research.md).

## Technical Context

**Language/Version**: Ruby >= 3.0.0

**Primary Dependencies**: redis ~> 5.0, sidekiq ~> 7.0 (and ActiveJob through the adapter),
zeitwerk ~> 2.6. No new dependency.

**Storage**: Redis. No new key space. New state rides on structures that already exist:

- `Context#private_data[:admitted]`;
- per-level `private_data[:parked_primitives]`;
- the Step Result Record's `ordered_lock` and `waiting` fields;
- `Failure#rollback_failures`, which is serialized through `Failure#to_h`.

**Testing**: RSpec against real Redis (Constitution III). The park paths are driven through
the real `Worker#perform`, with a real Sidekiq worker for the async_step scenario (P4). No
stubbing of `OrderedLock` in the parity specs. The only stub allowed is raising
`NoMemoryError` from a test body (P2).

**Target Platform**: Ruby library, with sync and worker-backed (Sidekiq, ActiveJob) execution

**Project Type**: Library / DSL

**Performance Goals**: no change on the happy path. A park does one fewer save: the requeue
no longer persists before the executors' `ensure` blocks do. Rollback under contention may
block for up to `rollback_wait`. That is intended (D-F1).

**Constraints**:

- MINOR and additive (Constitution V).
- Contexts saved before the upgrade must still resume correctly. The `admitted` marker falls
  back to the old inference.
- No change to failure-retry requeue semantics. `RetryQueuedResult` stays for retries.

**Scale/Scope**:

- About 12 library files edited, no new library files except two error classes.
- 4 new behavior-named spec files. 3 review-round spec files folded in and deleted.
- A demo extension and a new matcher.
- Docs in 2 files, plus the README and the CHANGELOG.

## Constitution Check

*GATE: passed before Phase 0. Re-checked after Phase 1 design; see the end of this section.*

| Principle | Assessment |
|---|---|
| **I. Gem-First Design** | ✅ Everything is inside `lib/`. The backend-specific requeue stays behind `Worker` and `async_router`. The OTel handler stays in the optional middleware. |
| **II. Saga Pattern Integrity** | ✅ This is the main reason for the feature. F1: an undo is no longer dropped silently under contention, and one that does not run reaches the caller. F10: a composed background wait no longer triggers a spurious rollback. F5: a crash no longer re-runs completed steps because a background step overwrote the parent's checkpoint. |
| **III. Test-First with Real Infrastructure** | ✅ Each R/P scenario in [quickstart.md](./quickstart.md) is written first and must fail on `ca963444`. Parks go through the real `Worker`. P4 uses a real Sidekiq worker. There are no Redis mocks. |
| **IV. Observability by Default** | ✅ A new `:snooze_step` event, and the OTel span is closed as "parked". Attribution is corrected (F4, F9). `rollback_failures` carries the step, key and reason. The dashboard still shows parked async_steps as waiting, now read from their record. |
| **V. Simplicity and SemVer** | ✅ MINOR. The change is net-negative in mechanism: the `on_contention_park` callback, `RetryManager#park_for_contention`'s requeue and the contention use of `RetryQueuedResult` are all removed. The additions are one error base class, one error class, one marker, one config keyword, one Failure field and one middleware event. Each exists because a verified defect needs it. The review's broader "unify both lifecycles" was deliberately rejected (research R-06). |
| **VI. Demo-App Proof of Feature** | ✅ Blocking work: extend the step-lock demo with rollback under contention (an undo that waited and ran, and one reported on the failure), a `demo:step_lock` output line for each, and a new `have_rollback_failure` matcher in `lib/ruby_reactor/rspec/matchers.rb` used by the demo spec. Then the docker acceptance run. |

- [x] **Documentation impact identified.** This is carried into tasks.md as a required task.
  See research R-11:
  - `documentation/middlewares.md`: the attribution section and the `:snooze_step` event.
  - `documentation/locks_and_semaphores.md`:
    - Step Contention: parks at any depth, and the nesting-order rule (F6);
    - Step Rollback: `rollback_wait`, `rollback_failures`, and the corrected trace and hook
      names;
    - the step ordered-lock warning and the stale-batch skip reason;
    - `:866`.
  - `README.md`: `rollback_wait:` and `Failure#rollback_failures`.
  - `CHANGELOG.md`: Bug Fixes F1–F10, and Features.

**Post-design re-check**: no new violations. Phase 1 added no storage primitive and no
dependency. The one new public event (`:snooze_step`) replaces an event the old park emitted
(`:complete_step(RetryQueuedResult)`), so observability does not regress.

## Project Structure

### Documentation (this feature)

```text
specs/005-step-coordination-remediation/
├── plan.md              # This file
├── spec.md              # Feature specification (F10 and the semaphore default added in planning)
├── research.md          # Phase 0: claim verification, the F10 repro, decisions D-F1/D-F3/D-A2, R-01..R-13
├── data-model.md        # Phase 1: rollback wait, rollback failure entry, admission marker, park signals, record fields
├── quickstart.md        # Phase 1: R1–R6 and P1–P5 validation scenarios, and the gates
├── contracts/
│   └── public-api.md    # Phase 1: rollback_wait:, Failure#rollback_failures, ordering outcomes, :snooze_step
├── checklists/
│   └── requirements.md  # Spec quality checklist (complete)
└── tasks.md             # Phase 2: /speckit-tasks output, NOT created here
```

### Source Code (repository root)

```text
lib/ruby_reactor/
├── error/
│   ├── execution_parked.rb          # NEW: base for park signals (R-01)
│   ├── step_contention_park.rb      # NEW: carries the Contended (R-01)
│   └── async_result_pending.rb      # superclass Base → ExecutionParked
├── executor.rb                      # rescue ExecutionParked in execute and resume_execution; park per level (D-A2);
│                                    #   admitted marker and first_execution? (R-03); drop on_contention_park
├── executor/
│   ├── step_executor.rb             # handle_contention raises; ceiling moved in; let park signals through
│   │                                #   safe_execute_step_sync (F10); :snooze_step (R-04)
│   ├── retry_manager.rb             # remove park_for_contention (R-01)
│   ├── ordered_lock_support.rb      # OrderedLockSupport.gate(info, fresh:) (R-06); fresh_ordered_lock_start? uses admitted
│   ├── step_coordination.rb         # the gate uses the classifier; stale → Skipped (F7); ensure lifecycle (F8, R-07);
│   │                                #   out-of-turn failed: false (F3); rollback_wait (F1); Contended rollback
│   │                                #   failure; step_name for @direct (F9); park signals untouched in around_run
│   ├── compensation_manager.rb      # collect rollback_failures (R-08)
│   └── result_handler.rb            # attach rollback_failures at one choke point; fold in child lists (R-08)
├── step/compose_step.rb             # resume vs execute by admitted (R-02); undo/compensate returns the child's failures
├── dsl/lockable.rb                  # rollback_wait: on with_lock and with_semaphore
├── worker.rb                        # snooze on ExecutionParked; uncapped (R-05)
├── map/element_executor.rb          # rescue StepContentionPark → perform_map_element_in (R-01)
├── step_worker.rb                   # park state into the record; load the stash from the record; no save_root on park (F5, R-09)
├── web/coordination_serializer.rb   # async_step waiting from the record (R-09)
├── open_telemetry.rb                # on_snooze_step (R-04)
├── rspec/matchers.rb                # have_rollback_failure (R-13)
└── ../ruby_reactor.rb               # Failure#rollback_failures, to_h, extract_attributes_from_hash (R-08)

spec/ruby_reactor/step_coordination/
├── park_spec.rb                        # NEW: R2, R4, R6, P4, and folded park cases from the review rounds
├── rollback_under_contention_spec.rb   # NEW: R1 and variants
├── ordering_parity_spec.rb             # NEW: R3, P1, P2, P3
├── attribution_spec.rb                 # NEW: R5, P5
├── review_fixes_spec.rb                # DELETED after folding in (R-12)
├── review_fixes_round3_spec.rb         # DELETED after folding in
└── review_fixes_round4_spec.rb         # DELETED after folding in

demo_app/
├── app/reactors/step_lock_demo_reactor.rb        # + a rollback-under-contention path (or a sibling reactor, R-13)
├── lib/tasks/demo_reactors.rake                  # demo:step_lock prints both rollback outcomes
└── spec/reactors/step_lock_demo_reactor_spec.rb  # + have_rollback_failure assertions

documentation/middlewares.md, documentation/locks_and_semaphores.md, README.md, CHANGELOG.md
specs/003-step-lock-declarations/research.md      # D-F1, D-F3, D-A2 recorded; D4 and the open-risk row amended (FR-025, FR-026)
specs/003-step-lock-declarations/spec.md          # FR-026 amended
```

**Structure Decision**: keep the existing layout. The only new library files are two error
classes, in the directory that already holds `AsyncResultPending`. Every other change edits
the file that already owns the concern. The new spec files are named by behavior, not by review
round (FR-028).

## Phase 2 outline (for `/speckit-tasks`)

This order follows the review's order of work: docs first, then decisions, then B before A
because B is self-contained. Each phase starts by writing its repros and confirming they fail.

1. **Docs-only corrections** (FR-005 wording, FR-022, FR-023, FR-024):
   - F4: `coordinating_step` in `middlewares.md` and `locks_and_semaphores.md:866`;
   - `:802`: the names of the trace entry and the hook;
   - F6: the nesting-order rule.

   No code. These can ship at once.
2. **Design record** (FR-025, FR-026): copy D-F1, D-F3 and D-A2 into 003's `research.md`.
   Amend 003's FR-026, its D4 and its open-risk row.
3. **Refactor B: ordering** (US3):
   1. Write R3, P1, P2 and P3, and confirm they fail.
   2. Add `OrderedLockSupport.gate`, and use it at the reactor level with no behavior change.
      The existing reactor ordered-lock specs must stay green.
   3. Rewrite the step gate and lifecycle (R-06, R-07, D-F3).
   4. Add the step-ordered "background only" warning to the docs.
4. **Refactor A: parks** (US2). This is the riskiest phase:
   1. Write R2, R4, R6 and R5 (the event part), and confirm they fail.
   2. Add the error classes.
   3. Update the rescue sites in the order of the R-01 table.
   4. Add the admission marker, and change `ComposeStep`'s resume choice.
   5. Park per level.
   6. Add `ElementExecutor`'s rescue.
   7. Remove the callback and `park_for_contention`.
   8. Update the specs that asserted the mechanism (R-12).
   9. Add `:snooze_step` and the OTel handler.
   10. Run the full suite.
   11. Audit with `grep -n "rescue StandardError"` along the executor and step paths.
5. **Rollback** (US1): write R1 and its variants, then add `rollback_wait:`, the `Contended`
   rollback failure, collection and attachment, the compose flattening, and
   `Failure#rollback_failures` serialization.
6. **Background step park state** (US4): write P4, then the record fields, load and park,
   remove `save_root` from `record_contention`, and update the dashboard serializer.
7. **F9** (US5-3): write P5, then change `step_name` for `@direct`.
8. **Spec cleanup** (US7): fold the three `review_fixes*` files into the behavior files,
   compare example counts, and delete the round files.
9. **Demo, docs and release notes** (FR-030, FR-031):
   - the demo rollback path, the rake output and the `have_rollback_failure` matcher;
   - the demo spec, and the docker acceptance run in an isolated compose project;
   - README, the CHANGELOG, and the rest of the `locks_and_semaphores.md` step sections.
10. **Gates** (SC-011): `bundle exec rubocop`, `bundle exec rspec`, the demo task and the demo
    spec.

## Complexity Tracking

No Constitution violations to justify. For the record, two scope calls:

| Decision | Why | Simpler alternative rejected because |
|---|---|---|
| F10 fixed here, although it is already on `main` | The A.1 change must route park signals past `safe_execute_step_sync` anyway. Leaving `AsyncResultPending` swallowed there would mean deliberately excluding it from the rescue that lets contention through. | Deferring it would leave FR-006's "parks that wait on a background result, at any depth" false on delivery. |
| The review's B.2 "one lifecycle for both levels" narrowed to the step level | The reactor-level enter and leave calls sit in the `begin` and `ensure` of two methods. A shared block helper restructures both for no change in behavior. | The drift F7 exposed is closed by the shared exhaustive classifier (R-06) and the parity spec (P3). The reactor-level lifecycle already stops the heartbeat in `ensure`. |
