# Implementation Plan: Rollback and Resume Follow-ups

**Branch**: `rollback_follow_ups` | **Date**: 2026-10-08 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `specs/010-rollback-follow-ups/spec.md`

## Summary

Seven follow-ups from 008, resolved with three shared mechanisms.

1. **Every live run holds its liveness lock, and readers lock, then load** (US1, US2):
   - A synchronous `Executor#execute` takes the run's `async:<id>` lock, auto-extended, and saves
     before releasing it (R-01). The sweeper already skips locked runs, so a live caller-process run
     is never re-enqueued. A killed one lapses within `context_lock_ttl`.
   - `Worker#perform` takes the same lock **before** reading the run, waiting up to 2s, and hands
     the owner to the executor, which re-enters the lock (R-02, R-03). A Worker resumed by a fan-out
     map's completion can no longer race the caller's final save, in either order.
2. **A resume is claimed per interrupt, and applied only by the run's lock owner** (US3, US4, US5):
   - `continue` validates the payload in the calling process, then claims the interrupt with
     `SET NX` (R-04). The claim holds the payload.
   - It then tries to own the run: lock, reload, resume (R-05). Any path that cannot run now (the
     run is busy, the reactor's lock or semaphore is held, a background resume) becomes one hand-off.
     The Worker applies the claims under the lock, and `continue` returns a `DispatchResult`.
   - The claim makes "exactly one resume per interrupt" hold in every mode, including inline
     testing. Claiming per interrupt lets different interrupts be accepted while another resume
     executes.
   - Supporting changes:
     - after admission, the snooze limit no longer escalates a run to `failed` without rollback
       (R-07);
     - interrupt attempts move to an atomic counter (R-08);
     - `Reactor#undo` reloads under its lock (R-09).
3. **Rollback state records what was cut off** (US6):
   - An `aborted` run records its failing step's unfinished `compensate` (step, arguments, error) in
     009's `context.rollback` (R-10).
   - `Executor#undo_all` runs it before the undo stack. Manual undo, composed children and inline
     elements all go through `undo_all`, so every depth is covered.
   - The dashboard shows the outstanding `compensate` (R-11).

Plus one new DSL method, **`map ... undo_all { |completed_results| }`** (US7). When it is declared,
the map's rollback calls the block once with a lazy, index-ordered enumerable of completed
results, instead of replaying each element (R-12, R-13):

- a fan-out map reads its forward result slots and dispatches no rollback jobs;
- an inline map reads element contexts one at a time, and still replays an `aborted` element
  itself.

## Technical Context

**Language/Version**: Ruby >= 3.0

**Primary Dependencies**:

- Sidekiq and ActiveJob adapters, Redis, dry-validation.
- Optional OpenTelemetry middleware.
- GUI: React/Vite (`gui/`, built into `lib/ruby_reactor/web/public`).

No new dependencies.

**Storage**: Redis through `Storage::RedisAdapter` (see [data-model.md](data-model.md)).

- New keys:
  - `reactor:<Class>:context:<id>:resume:<step>`: the claim (`SET NX`, TTL `context_ttl`);
  - `reactor:<Class>:context:<id>:resume_attempts:<step>`: the attempt counter (`INCR`).
- `lock:async:<id>` gains three holders: `execute`, `Worker`, `continue`.
- The `context.rollback` hash gains `arguments` and `error` for aborted runs.
- The map `StepConfig` gains `undo_all_block`.
- No migration. The one compatibility note: attempt counts restart for runs paused across the
  upgrade (R-08).

**Testing**: RSpec against real Redis (`redis://localhost:6780`), with Sidekiq fake mode plus
`drain_async_jobs`.

- **Concurrency specs** (US1, US4, US5): threads, a barrier or latch, real Redis.
- **Interleaving spec** (US2): a public middleware hook drains jobs between the hand-off and the
  caller's final save.
- **Crash spec** (US1, FR-003): `fork` plus `SIGKILL`, tagged `:fork`.
- **Inline mode**: one justified `Sidekiq::Testing.inline!` spec for US4 (FR-016).
- **Scale**: `:slow` tag, 10,000 elements for `undo_all` (SC-007).
- **Demo specs**: the shipped matchers only, plus the new `be_resume_deferred` and
  `have_run_undo_all`.

**Target Platform**: Ruby gem (MRI), Sidekiq/ActiveJob workers, Rails demo app in Docker.

**Project Type**: Library (gem) with a bundled dashboard.

**Performance Goals**:

- **Synchronous run**: one lock acquire and release, and one extender thread, per run.
- **Worker**: one extra lock round-trip, and usually no wait. It waits at most 2s, while a caller
  finishes its hand-off.
- **`continue`**: one `SET NX`, plus one `MGET` per resume for reactors that declare interrupts.
- **`undo_all` over 10,000 elements**: one call. Memory is bounded by the enumerator's chunk
  (1,000 result slots, or one element context).

**Constraints**:

- **Single writer**: `continue` writes the run's context only while holding its lock (J-5).
- **Save before release** for every holder (J-3).
- A claimed payload is never validated again (J-7).
- An admitted run is never escalated to `failed` by snoozes (J-8).
- Inline testing mode takes no context lock, as today (R-14).
- Existing outcomes are unchanged for:
  - uncontended resumes;
  - background resumes;
  - maps without `undo_all`;
  - aborted runs whose `compensate` had finished.

**Scale/Scope**:

- About 14 library files touched. 2 new: `interrupt_claims.rb` and `error/recorded_failure.rb`.
- About 10 new spec files and about 8 updated.
- Demo: 4 reactor files, 3 rake tasks plus the `demo:rollback_follow_ups` group, 3 specs.
- 6 documentation files, the README, CHANGELOG and `future_improvements.md`.
- GUI: `ReactorDetail.tsx` (its API response is untyped, so `lib/reactors.ts` needs no change).

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Status | Note |
| --- | --- | --- |
| I. Gem-First Design | PASS | Everything is in `lib/` behind the existing DSL and `Reactor` API. One DSL method (`undo_all`). The Worker change is in the backend-agnostic `Worker` module, so Sidekiq and ActiveJob both get it. No host coupling. |
| II. Saga Pattern Integrity | PASS (strengthened) | Closes four ways a run lost work or effects: a duplicate forward run (US1), overwritten progress (US2), a lost or double resume (US3–US5), and a `compensate` never finished after an interruption (US6). R-07 removes the snooze escalation that marked runs `failed` without rollback. `undo_all` keeps step-level order (P-6), and an `aborted` inline element still replays its own undos. |
| III. Test-First with Real Infrastructure | PASS with one justified deviation | Each story's specs are written first and fail first, against real Redis. Concurrency is shown with threads, not mocks. The US2 interleaving uses a public middleware hook, not stubs. One new `inline!` spec, for FR-016, justified in Complexity Tracking. |
| IV. Observability by Default | PASS | New key=value log lines: `resume.deferred`, `resume.waiting`, `map.rollback.undo_all.started` / `.completed`. A `:undo_all` trace entry. Dashboard: `pending_compensation` on aborted runs, and a "Resume accepted" API message. A re-run `compensate` fires the standard compensation middleware events. A hand-off never fires `:failed_reactor`. |
| V. Simplicity & SemVer | PASS with notes | Three mechanisms, each serving several stories (Complexity Tracking). Code deleted: `reopen_paused` and the `past_gates?` contention branch in `continue`, and the blob write of attempts. MINOR (R-16), with CHANGELOG migration notes: `continue` returns a hand-off where it raised; "already resumed"; attempt counts restart; a synchronous run holds the liveness lock. No new config knobs. |
| VI. Demo-App Proof of Feature | PASS (planned) | One reactor per file, all class-based steps (R-18): `BulkRefundDemoReactor` with `BulkRefundChargeReactor` (`undo_all`, fan-out, a later failure), `ContendedApprovalDemoReactor` (resume while locked), and `DualApprovalDemoReactor` (two interrupts at once). Rake: `demo:map_undo_all`, `demo:contended_resume`, `demo:concurrent_interrupts`, grouped as `demo:rollback_follow_ups` in `demo:all`. Specs use the shipped matchers. `TestSubject#resume(process_jobs:)`, `be_resume_deferred` and `have_run_undo_all` are added to `lib/ruby_reactor/rspec/`. No new Docker service or environment variable. |

- [x] Documentation impact identified (research R-17):
  - **README.md**: "Durability & Recovery", "Interrupts (Pause & Resume)", "Locks, Semaphores &
    Ordered Locks" and "Map & Parallel Execution".
  - **documentation/**: `interrupts.md`, `locks_and_semaphores.md`, `background_and_async.md`,
    `data_pipelines.md`, `core_concepts.md`, `testing.md`.
  - **demo_app/documentation/data_pipelines.md**.
  - **CHANGELOG.md**.
  - **specs/future_improvements.md**: remove the seven items, and update "Fenced context writes".
  - Carried into tasks.md as a required task per user story.

**Post-design re-check (after Phase 1)**: PASS.

- New public surface:
  - one DSL method;
  - one changed return contract for `continue`, and one new rejection;
  - two log events, plus the `undo_all` pair;
  - one API field;
  - three RSpec additions.
- New internals:
  - one small module (`InterruptClaims`) used by three callers;
  - one error class;
  - three storage methods.
- The spec was revised for what the design fixed (see spec Status): FR-010, FR-017, FR-024, US6-AS3.

## Project Structure

### Documentation (this feature)

```text
specs/010-rollback-follow-ups/
├── plan.md                        # This file
├── research.md                    # Phase 0: R-01..R-19
├── data-model.md                  # Phase 1: lock holders, claim, counter, rollback record, undo_all
├── quickstart.md                  # Phase 1: validation guide
├── contracts/
│   ├── api-surface.md             # continue outcomes, undo on aborted, undo_all, logs, RSpec additions
│   └── resume-protocol.md         # Invariants J-1..J-9, sequences P-1..P-6
├── checklists/requirements.md
└── tasks.md                       # Phase 2 (/speckit-tasks)
```

### Source Code (repository root)

```text
lib/ruby_reactor/
├── interrupt_claims.rb                 # new: claim!(ctx, step, payload) (SET NX), unapplied(ctx) (MGET of
│                                       #   interrupts without a result), apply!(ctx) → set_result (R-04, R-06)
├── error/recorded_failure.rb           # new: StandardError carrying the original message + original_class (R-10)
├── executor.rb                         # execute: acquire_context_lock (root, caller process); save before
│                                       #   releasing it (R-01). context_lock_owner= for re-entry (R-03).
│                                       #   resume_execution: InterruptClaims.apply! after the lock (R-04).
│                                       #   mark_aborted: record the unfinished compensate in `rollback` (R-10).
│                                       #   undo_all: compensate_pending! before the stack (R-10)
├── executor/compensation_manager.rb    # @pending keeps rollback_arguments (R-10)
├── reactor.rb                          # continue: validate → claim → lock → reload → resume, or hand off;
│                                       #   delete reopen_paused (R-05). validate_continue_payload: attempt
│                                       #   counter (R-08). undo: reload under lock, merge the aborted record,
│                                       #   failure: kwarg (R-09, R-10)
├── worker.rb                           # perform: lock, then load (R-02); status table (R-06); release in
│                                       #   ensure; handle_snooze: uncapped once admitted, one
│                                       #   resume.waiting warning (R-07)
├── storage/redis_adapter.rb            # claim_interrupt_resume, retrieve_interrupt_resumes,
│                                       #   increment_interrupt_attempts
├── dsl/map_builder.rb                  # undo_all(&block): once, block required → undo_all_block (R-12)
├── step/map_step.rb                    # compensate/undo: bulk_rollback when undo_all is declared (R-13)
├── map/step_rollback.rb                # bulk_rollback: fan-out result slots / inline two passes; trace,
│                                       #   logs, failure entry (R-13)
├── web/api.rb                          # pending_compensation on aborted; continue → "Resume accepted" (R-11)
└── rspec/{test_subject,matchers}.rb    # resume(process_jobs:), running runs; be_resume_deferred;
                                        #   have_run_undo_all (R-18)

gui/src/components/ReactorDetail.tsx    # outstanding-compensate line on aborted runs
gui/src/lib/reactors.ts                 # pending_compensation type
lib/ruby_reactor/web/public/            # rebuilt bundle

spec/
├── ruby_reactor/caller_process_liveness_spec.rb        # new: US1 (latch, long step, fork + SIGKILL)
├── ruby_reactor/executor/caller_save_race_spec.rb      # new: US2 interleaving (middleware drain)
├── ruby_reactor/worker_lock_then_load_spec.rb          # new: R-02, R-06 status table
├── ruby_reactor/worker_snooze_admitted_spec.rb         # new: R-07
├── ruby_reactor/interrupts/contended_resume_spec.rb    # new: US3
├── ruby_reactor/interrupts/resume_claim_spec.rb        # new: US4, including the one inline! example
├── ruby_reactor/interrupts/concurrent_interrupts_spec.rb  # new: US5
├── ruby_reactor/dsl/map_undo_all_dsl_spec.rb           # new: R-12
├── map/map_undo_all_spec.rb                            # new: US7 (fan-out, inline, atomic, undo, :slow)
├── ruby_reactor/rollback/aborted_execution_spec.rb     # updated: US6 at top level, compose, inline element
├── ruby_reactor/rollback/resume_guard_spec.rb          # updated: contention defers instead of raising
├── ruby_reactor/sweeper_spec.rb                        # updated: caller-process runs skipped
├── ruby_reactor/context_lock_spec.rb                   # updated: execute holds the lock; re-entry by owner
├── ruby_reactor/interrupt_background_resume_spec.rb    # updated: claim-based background resume
├── integration/interrupt_max_attempts_spec.rb          # updated: counter record; failure under lock
├── ruby_reactor/web/*_spec.rb                          # updated: pending_compensation, continue message
└── ruby_reactor/rspec/*_spec.rb                        # new or updated: resume(process_jobs:), new matchers

demo_app/
├── app/reactors/bulk_refund_demo_reactor.rb            # fan-out map with undo_all; a later step fails
├── app/reactors/bulk_refund_charge_reactor.rb          # element reactor (class-based charge step)
├── app/reactors/contended_approval_demo_reactor.rb     # with_lock + interrupt
├── app/reactors/dual_approval_demo_reactor.rb          # finance (resume: :background) + legal interrupts
├── lib/tasks/demo_reactors.rake  # demo:map_undo_all, :contended_resume, :concurrent_interrupts,
│                                 #   :rollback_follow_ups (in demo:all)
└── spec/reactors/{bulk_refund,contended_approval,dual_approval}_demo_reactor_spec.rb

README.md, documentation/*.md, demo_app/documentation/data_pipelines.md, CHANGELOG.md,
specs/future_improvements.md   # per R-17
```

**Structure Decision**: single gem project, existing `lib/ruby_reactor` layout. New interrupt specs
go in a new `spec/ruby_reactor/interrupts/` folder. Rollback specs stay in
`spec/ruby_reactor/rollback/`, and map specs in `spec/map/`.

## Delivery Order

The stories are independently testable. tasks.md is the authoritative order.

1. **Foundation** (blocks US2, US3 and US5):
   - `Executor#context_lock_owner=` (R-03);
   - `Worker#perform` lock, then load, plus the status table (R-02, R-06);
   - `Reactor#undo` reload under its lock (R-09).
2. **US1 (P1)**: `execute` takes and releases the liveness lock, saving first (R-01). Specs: latch,
   long step, fork kill.
3. **US2 (P1)**: the interleaving spec, which passes with foundation plus US1. The inline-`continue`
   variant lands with US3.
4. **Claims foundation** (blocks US3–US5): storage methods, `InterruptClaims`, and `apply!` in
   `resume_execution` (R-04).
5. **US3 (P1)**: the `continue` flow with contention hand-off (R-05), the uncapped snooze after
   admission (R-07), and the `resume_guard_spec` update.
6. **US4 (P2)**: claim race specs, including the one `inline!` example.
7. **US5 (P2)**: accept on `running` (R-05 step 1), the attempt counter (R-08), and the concurrency
   specs.
8. **US6 (P2)**: `@pending` arguments, the `mark_aborted` record, `undo_all`'s
   `compensate_pending!`, the `Reactor#undo` merge (R-10), and the API and GUI (R-11).
9. **US7 (P3)**: the DSL (R-12), `bulk_rollback` (R-13), and the matchers.
10. **Demo, docs, CHANGELOG** per story. Close with the Docker acceptance run of
    `demo:rollback_follow_ups`.

## Complexity Tracking

| Addition | Why needed | Simpler alternative rejected because |
| --- | --- | --- |
| Resume claim record per interrupt (`SET NX`) | FR-015 and FR-016: exactly one resume per interrupt **in every mode**. FR-017: different interrupts accepted concurrently. Also stores the payload until the lock owner applies it, so `continue` never writes the blob unlocked (J-5). | **The context lock** is skipped in inline mode. **A status compare-and-set in the blob** serializes all resumes of the run, which blocks US5, and still writes from outside the owning execution. |
| The Worker takes the liveness lock before loading (wait ≤ 2s) | FR-005: closes the caller-save race in both orders. It also fixes the Workers enqueued by the rollback hand-off handshake and by `Reactor#undo` while holding the lock. | **Peek-then-snooze** leaves a check-then-read gap and adds a full Sidekiq poll (about 5s) to every hand-off from a caller process. **Full fenced writes** are out of scope (spec Assumptions). |
| Uncapped snooze once admitted (R-07) | FR-010. Escalation marks a run with completed work `failed` **without rollback**, a Constitution II violation that also hits `resume: :background` today. | **Escalation with rollback** fails a run the user accepted, because of an unrelated holder. **Keeping the cap** strands an accepted resume. A one-time warning keeps leaked semaphores visible. |
| One new `Sidekiq::Testing.inline!` spec, a deviation from Constitution III | FR-016 requires US4 to hold in inline job-testing mode, the mode that skips the run lock. That is the original 008 gap. | **Fake mode plus drain** cannot show it: the context lock is taken there, so the race under test never opens. Scoped to one example. |
| Attempt counter moved to its own key (R-08) | Once `continue` accepts resumes of a `running` run (US5), the old blob save of the attempt count, from an unlocked snapshot, would overwrite the executing resume's progress. | **Counting under the run's lock** would make an invalid-payload response wait behind, or contend with, a live resume. **Not counting while running** makes `max_attempts` depend on timing. |
