---

description: "Task list for 009 Distributed Map Rollback and Bounded Fan-out"
---

# Tasks: Distributed Map Rollback and Bounded Fan-out

**Input**: Design documents from `specs/009-distributed-map-undo/`

**Prerequisites**: [plan.md](plan.md), [spec.md](spec.md), [research.md](research.md),
[data-model.md](data-model.md), [contracts/](contracts/), [quickstart.md](quickstart.md)

**Tests**: REQUIRED by Constitution III (test-first, real Redis). In every phase, write the spec
tasks first and confirm they FAIL on the current code before implementing.

**Revised 2026-09-30 after `/speckit-analyze`**: every finding is addressed in place, with the
finding IDs cited (C1…A3). The task IDs are unchanged. T076 was repurposed to the leftover
`fail_fast` sweep (G4), because its log-shape spec moved to T020(g) (C3). The constitution's
worker-path drift (C5) was amended directly, as version 1.3.1.

**Citations**:

- research decisions: `R-nn`;
- data-model sections: `DM §n`;
- rollback protocol invariants and sequences: `I-n` / `S-n` (contracts/rollback-protocol.md);
- API contract: `API` (contracts/api-surface.md).

## Format: `[ID] [P?] [Story] Description`

- **[P]**: can run in parallel (different files, no dependency on an incomplete task)
- **[Story]**: US1–US4 from spec.md

## Path Conventions

Single gem project: `lib/ruby_reactor/`, `spec/`, `demo_app/`, `gui/`, `documentation/`.

**Test rules**:

- Run specs against the test Redis at `redis://localhost:6780`.
- Async paths use `for_each_async_backend` (from `spec/support/async_backends.rb`) plus
  `drain_async_jobs`.
- Add no new `Sidekiq::Testing.inline!`, except T041, which tests inline mode itself and is
  justified in plan.md Complexity Tracking. Specs that already use `inline!` (`map_recovery_spec`,
  `map_batch_size_spec`, `fail_fast_spec`) keep it, but new examples in them run in fake mode.
- Don't run the gem suite and the demo suite at the same time: they flush the same Redis. If
  another worktree's suite shares the test Redis, rerun failures alone first.
- Demo specs locally: `cd demo_app && REDIS_URL=redis://localhost:6780/5 RAILS_ENV=test bundle exec rspec …`.

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: test scaffolding shared by every story's specs.

- [X] T001 Create `spec/support/map_rollback_fixtures.rb`, module `MapRollbackFixtures`, built on
  `RollbackRecorder` (`spec/support/rollback_recorder.rb`).
  - **Element classes**:
    - `Elem` (steps e1, e2; e2 fails when `inputs.i == fail_at`, passed in as input);
    - `ElemOk` (e1, e2);
    - `ElemUndoFails` (the e1 undo fails for `i == 1`);
    - `ElemInterruptOnce`: the e1 undo raises `Interrupt` the first time it runs for `i == 0`,
      tracked in a class-level Set, and succeeds after that.
  - **Builder**: `MapRollbackFixtures.parent(namespace, name, element_class, fan_out: false,
    batch_size: nil, b_fails: false, atomic: true, collect: nil)`. It defines
    `recording_step :a` → `map :m` (`source input(:items)`, `argument :i, element(:m)`, the given
    options) → `recording_step :b, after: :m, fail: b_fails`, and sets the constant under
    `namespace`. The oracle specs (I-7) build the same reactor with `fan_out: false` and with
    `fan_out: true`.
- [X] T002 [P] Create `spec/support/queue_probe.rb`, module `QueueProbe`, for back-pressure
  assertions, backend-agnostic like `AsyncTestHelpers`:
  - `QueueProbe.enqueued(worker_class_name)` returns the count of jobs of that class in the Sidekiq
    fake queues or the ActiveJob test adapter's `enqueued_jobs`.
  - `QueueProbe.drain_tracking(worker_class_name)` performs queued jobs of every class one at a
    time (FIFO) until none remain, and returns `{ max_burst: }`: the largest number of jobs of that
    class enqueued while a single job ran. That includes the owner job's first throw.
  - Queue depth is deliberately not reported: the back-pressure bound is per throw (FR-002, R-02),
    and a FIFO drain would make any depth assertion pass by accident.
- [X] T003 [P] Baseline, with no file changes. Run
  `bundle exec rspec spec/map spec/ruby_reactor/rollback spec/ruby_reactor/map spec/compose_spec.rb spec/single_worker_map_spec.rb; bundle exec ruby specs/007-execution-flow-analysis/evidence/run.rb | tail -1`
  and record the pass counts and the evidence tail line in the PR description draft. They are the
  regression bar for T092.

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: the pieces every story builds on:

- map metadata that knows its owner and batch size;
- save-before-release;
- argument-free map undo records;
- the `atomic` internal rename with legacy normalization;
- the owner-resume + adopt-on-re-entry mechanism (R-03) that US1's map-failure rollback and US2
  both need.

**⚠️ CRITICAL**: No user story work can begin until this phase is complete.

### Specs first

- [X] T004 [P] Write `spec/ruby_reactor/executor/context_lock_save_order_spec.rb` (R-13, I-6).
  Run a reactor through `RubyReactor::Worker` (fake mode) whose resume ends with a
  `DispatchResult`. Spy (`and_call_original`) on `RubyReactor::Lock#release` for the
  `async:<id>` key and on `storage.store_context` for that id, and record their call order. Assert
  the last `store_context` happens before the context lock's `release`. It must FAIL on current
  code (the release happens first).
- [X] T005 [P] Write `spec/map/map_owner_resume_spec.rb` (R-03, S-1), with a root-level fan-out
  map, `for_each_async_backend`:
  - (a) after the last element, the collector enqueues exactly one `Worker` job for the owner id,
    and `Map::Collector.perform` never calls `storage.store_context` (spy);
  - (b) two collector deliveries for a settled map enqueue one owner `Worker` (`owner_signalled`);
  - (c) running the owner `Worker` before the map settles returns a `DispatchResult`, enqueues no
    new `MapElementWorker` job, and leaves `map_operations` unchanged;
  - (d) an atomic element failure fails the run through the executor: `be_failure`, same
    message and `rollback_failures` as before the change (copy expectations from
    `spec/map/map_fail_fast_spec.rb`);
  - (e) map metadata written by an older version (delete `owner_context_id` /
    `owner_reactor_class_name` from the metadata hash before the collector runs) falls back to
    `parent_context_id` and the run completes.
- [X] T006 [P] Write `spec/map/map_legacy_payload_spec.rb` (R-11, FR-023, S-6):
  - Enqueue a `MapElementWorker` job by hand with the pre-upgrade payload shape (string keys,
    `"fail_fast" => true`, no `"atomic"`) for a map whose element fails. Assert the map is
    atomic: failed context id stored, remaining indexes `_skipped`.
  - Do the same through `Dispatcher.perform` and `Collector.perform` with legacy args.
- [X] T007 [P] Extend `spec/map/map_recovery_spec.rb` with the latent bug from research §Current
  behavior: a map with `batch_size 3`, atomic, one element job dropped. After
  `Map::Sweeper.run_once`, the re-dispatched element job's args carry `batch_size: 3` and
  `atomic: true`, and the map settles.
- [X] T008 [P] Add to `spec/ruby_reactor/rollback/map_rollback_spec.rb`: after an inline map
  completes, the parent's undo stack entry for `:m` has `arguments == {}` (R-14). The source array
  is not stored in the parent blob: assert the serialized context does not contain the source
  items' marker values.

### Implementation

- [X] T009 [P] Create `lib/ruby_reactor/map.rb`, the Zeitwerk namespace file:
  `module RubyReactor; module Map; DEFAULT_BATCH_SIZE = 50; ROLLBACK_CHUNK = 100; end; end`
  (R-10, R-01, DM §7). Confirm `bin/console`/specs still load `RubyReactor::Map::Collector` etc.
- [X] T010 In `lib/ruby_reactor/executor.rb` `#resume_execution` `ensure`, move
  `save_context unless skip_context_persist?` above `@acquired_context_lock&.release` (R-13).
  T004 passes. Keep `release_locks` and `leave_ordered_lock_scope` order unchanged.
- [X] T011 Storage metadata and owner signal (DM §2, §3):
  - `lib/ruby_reactor/storage/redis_adapter.rb#initialize_map_operation` accepts and stores
    `owner_context_id:`, `owner_reactor_class_name:`, `batch_size:`, `atomic:`.
  - Add `claim_map_owner_signal(map_id, reactor_class_name)`: `SET NX EX durability_ttl` on
    `reactor:<P>:map:<map_id>:owner_signalled`, returning true when claimed.
  - Declare it in `lib/ruby_reactor/storage/adapter.rb`.
  - Unit examples in `spec/ruby_reactor/storage/redis_adapter_spec.rb`.
- [X] T012 Internal rename `fail_fast` → `atomic`, with legacy normalization (R-11). The DSL
  alias and warning come in US4.
  - Add `Map::Helpers.normalize_arguments(arguments)` in `lib/ruby_reactor/map/helpers.rb`
    (module function). It symbolizes keys, and sets `:atomic` from `:fail_fast` when
    `:atomic` is absent, then deletes `:fail_fast`.
  - Call it first in `Map::ElementExecutor.perform`, `Map::Dispatcher.perform` and
    `Map::Collector.perform`, and where `lib/ruby_reactor/executor/retry_manager.rb` reads
    `map_args`.
  - Rename every internal use to `atomic`:
    - the `MapStep` input and `inputs.fail_fast` reads (`lib/ruby_reactor/step/map_step.rb`);
    - `Dispatcher` (`dispatch_batch`, `requeue_index`, `queue_element_job`);
    - `ElementExecutor` (`check_fail_fast?` → `check_atomic?`, `handle_result`,
      `requeue_parked_element`);
    - `lib/ruby_reactor/executor/result_handler.rb#store_failed_map_context`
      (`map_metadata[:atomic]`);
    - the `perform_map_element_async` / `perform_map_element_in` kwargs and payload key in
      `lib/ruby_reactor/adapters/sidekiq/router.rb` and `lib/ruby_reactor/adapters/active_job/router.rb`;
    - `build_step_config` argument key in `lib/ruby_reactor/dsl/map_builder.rb`. Keep the
      `fail_fast` DSL method setting the same ivar for now.
  - T006 passes.
- [X] T013 Argument-free map undo records (R-14). This is not parallel with T012: both edit
  `map_step.rb` and `result_handler.rb`.
  - Add `StepConfig#rollback_arguments(resolved)` in `lib/ruby_reactor/dsl/step_builder.rb`. It
    returns `impl.rollback_arguments(resolved)` when the impl responds to it, else `resolved`.
  - Use it at every `add_to_undo_stack` push: `lib/ruby_reactor/executor/result_handler.rb` (two
    sites) and `lib/ruby_reactor/executor/step_executor.rb#track_interrupted_construct`.
  - Add `def self.rollback_arguments(_resolved) = {}` to `RubyReactor::Step::MapStep`.
  - T008 passes.
- [X] T014 Map metadata carries owner and batch size (R-03, R-10), in
  `lib/ruby_reactor/step/map_step.rb`:
  - Add `#owner_context`, returning `context.root_context || context`.
  - Add `#effective_batch_size`, returning `inputs.batch_size || inputs.source.size` (today's
    behavior; US3 changes this one method).
  - Pass `owner_context_id`, `owner_reactor_class_name` (`RubyReactor.reactor_storage_name`),
    `batch_size: effective_batch_size` and `atomic` into `initialize_map_operation`.
  - `dispatch_async_map` uses `effective_batch_size`.
  - T007 passes, with `Dispatcher.requeue_index` now finding both fields.
- [X] T015 Collector signals the owner and writes nothing (R-03, S-1), in
  `lib/ruby_reactor/map/collector.rb#perform_collection`:
  - Keep the settle check (`results_count < total_count` → return).
  - Remove the parent-context load, the idempotency check on the parent, `handle_failure`,
    `apply_collect_block` and `resume_parent_execution`.
  - When settled: `return unless storage.claim_map_owner_signal(map_id, class)`, then
    `async_router.perform_async(owner_id, owner_class)`. The owner comes from the metadata, falling
    back to `parent_context_id` / `parent_reactor_class_name` (S-6).
  - Log `event=ruby_reactor.map.settled map_id=… owner=…`.
- [X] T016 `MapStep#run` adopts a settled map on re-entry (R-03, S-1), in
  `lib/ruby_reactor/step/map_step.rb`:
  - If `context.map_operations[step]` is present, call `adopt_dispatched_map(step)` instead of
    `run_async`.
  - Not settled (`storage.count_map_results < metadata count`): return a `DispatchResult` for
    `"map:#{map_id}"` without dispatching.
  - Settled with `retrieve_map_failed_context_id`: load that element context
    (`resolve_reactor_class(metadata["reactor_class_info"])`), and return its `failure_reason` as a
    `Failure` carrying its `rollback_failures`. The logic comes from the deleted
    `Collector.handle_failure`.
  - Otherwise: `Success(collect_block ? collect_block.call(ResultEnumerator) : ResultEnumerator)`,
    rescuing `Error::Rescuable` into `Failure`, as the deleted `Collector.apply_collect_block` did.
    Also set `composed_contexts[step][:started] = metadata count` (from the deleted
    `Helpers#record_elements_started`).
  - T005 passes.
- [X] T017 Delete dead code in `lib/ruby_reactor/map/helpers.rb`: `resume_parent_execution`,
  `resume_parked_aware`, `record_elements_started`, `store_parent` and `apply_collect_block`, once
  `grep -rn` shows no callers. Remove the ponytail note about composed children.
- [X] T018 Run `bundle exec rspec spec/map spec/ruby_reactor/map spec/ruby_reactor/rollback spec/compose_spec.rb spec/single_worker_map_spec.rb`.
  It must reach the T003 bar or better; fix regressions in the files above only.

**Checkpoint**:

- map completion resumes the owner run;
- the collector writes no context;
- legacy payloads work;
- US1–US4 can start.

---

## Phase 3: User Story 1 - Roll back a large fan-out map the way it ran (Priority: P1) 🎯 MVP

**Goal**: A fan-out map's compensate/undo dispatches one rollback job per completed element,
`batch_size` per throw. The run hands off as `rolling_back` and resumes when the last element
reports. It finishes with the same `Failure` the inline path gives. Inline maps roll back in
process in chunks of 100.

**Independent Test**: a fan-out map of N elements, `batch_size B`, and a step after the map
fails. Each completed element is rolled back by its own job, no throw enqueues more than B, the
steps before the map are undone after the last element, and the run ends `failed` with every
element undone once.

### Tests for User Story 1 ⚠️ (write first, confirm FAIL)

- [X] T019 [P] [US1] Write `spec/ruby_reactor/executor/resume_rollback_spec.rb` (R-04), with a
  stub construct: a step class `HandsOffOnce` whose `undo` raises
  `RubyReactor::Error::RollbackHandedOff.new(map_id: "stub")` while a Redis key `stub:pending`
  exists, and returns `Success` once it is deleted.
  - (a) Run `a → HandsOffOnce → b(fails)` through `Worker` (fake mode). Status is `rolling_back`,
    and `a` has not been undone yet (RollbackRecorder). `context.rollback` is stored with string
    keys and also carries `"failure"`, so assert with `include`:
    `expect(ctx.rollback).to include("trigger" => "failure", "step" => "b", "compensated" => true, "failures" => [])`
    and `expect(ctx.rollback["failure"]).to be_present`.
  - (b) Delete the key, then `Worker.new.perform(id, class)`. `a` is undone, the status is
    `failed`, `rollback` is nil, and the final `Failure` equals a run of the same reactor with a
    plain undo step.
  - (c) `RubyReactor::Error::Rescuable === RollbackHandedOff.new(map_id: "x")` is false.
  - (d) The run is never marked `aborted` by the hand-off.
- [X] T020 [P] [US1] Write `spec/ruby_reactor/rollback/distributed_map_rollback_spec.rb` (US1
  acceptance 1–4, FR-001…FR-009, I-4, I-7). Use `for_each_async_backend`, `MapRollbackFixtures`,
  20 items, `batch_size 5`, and `test_reactor(..., process_jobs: false)` where intermediate state is
  asserted.
  - (a) Later step fails:
    - perform `pending_async_jobs` one at a time until a pending job's `worker_class` is
      `MapElementRollbackWorker`, then `be_rolling_back`;
    - after `drain_async_jobs`, `be_failure`;
    - `RollbackRecorder.log` has `undo:e.e2[i]` and `undo:e.e1[i]` exactly once for every i;
    - every element undo precedes `undo:a`.
  - (b) Oracle: the same fixture with `fan_out: false` and `fan_out: true` has an equal
    `error.message`, `step_name`, the same `rollback_failures` sorted by `element_index`, and the
    same set of undone elements.
  - (c) Atomic element failure at i=7 (spec US1-AS2, FR-007):
    - `MapElementRollbackWorker` jobs performed == elements that **started** (the element-context
      index length);
    - the outcome for index 7 is `not_needed`, and no `undo:e.*[7]` is logged;
    - no outcome and no job exist for skipped indexes, which never started;
    - every completed element is undone once.
  - (d) `ElemUndoFails`:
    - `rollback_failures` contains an entry with symbol values:
      `include(step: :e1, kind: :undo, map_step: :m, element_index: 1)`. Assert with `eq` against
      the inline oracle's entry (U1: re-symbolized after the JSON round-trip);
    - `undo:a` is still logged.
  - (e) Back pressure (via `QueueProbe.drain_tracking("…MapElementRollbackWorker")`):
    `max_burst <= 5`. Queue depth is not asserted, because the bound is per throw (FR-002, R-02).
  - (f) No rollback job loads more than one element context: spy on `storage.retrieve_context`
    with the element class name, grouped by job. `MapStep` never calls
    `retrieve_map_element_context_ids` (the full `LRANGE`).
  - (g) Structured logs (FR-011, `API` §Structured logs), written first here, not in Polish.
    Capture `RubyReactor.configuration.logger` into a `StringIO`. Assert exactly one
    `event=ruby_reactor.map.rollback.started`, one `…element` line per started element and one
    `…completed` line, each carrying `reactor=`, `context_id=` and `map_step=`, plus
    `total=`/`batch_size=`, `index=`/`outcome=`/`failures=`, or `total=`/`failed=` respectively.
  - (h) Expired element (I2): delete element 3's context row before `b` fails. With the fan-out map
    and with the inline map (oracle), `rollback_failures` holds exactly **one**
    `context_unavailable` entry, for `element_index: 3`.
- [X] T021 [US1] Add a manual undo context (same file as T020, so not parallel with it) to
  `spec/ruby_reactor/rollback/distributed_map_rollback_spec.rb` (US1 acceptance 3, R-12, FR-027):
  - a completed run with a fan-out map, then `Reactor.undo(id)`: status `rolling_back`, the steps
    after the map undone, the steps before it not yet;
  - after `drain_async_jobs`: `cancelled`, everything undone once;
  - a second `Reactor.undo(id)` while `rolling_back` raises `ValidationError` "rollback already in
    progress";
  - with the `async:<id>` lock held by another owner, `Reactor.undo(id)` raises
    `Lock::AcquisitionError`;
  - `Reactor.cancel(id:, reason: "x")` while `rolling_back` raises `ValidationError` "rollback in
    progress; cannot cancel". The status stays `rolling_back`, and after draining the run is
    `cancelled` with the steps before the map undone (G1).
- [X] T022 [P] [US1] Write `spec/ruby_reactor/rollback/map_rollback_recovery_spec.rb` (US1
  acceptance 5, FR-006, FR-010, S-5, SC-003), with `for_each_async_backend`:
  - (a) `ElemInterruptOnce`: performing the element-0 rollback job raises `Interrupt`, which is
    rescued in the spec. Re-perform the same job args: `undo:e.e2[0]` is logged once and
    `undo:e.e1[0]` succeeds on the redelivery. The run finishes `failed`.
  - (b) Delete one queued rollback job, drain, then `Map::Sweeper.run_once`: the missing position
    is re-dispatched and the run finishes.
  - (c) Delete the job at the batch-trigger position after it stores its outcome (perform it with
    the trigger stubbed off), then `Map::Sweeper.run_once`: the next batch is claimed and the run
    finishes.
  - (d) Delete the owner `Worker` job after `rollback:signalled` is set, then
    `RubyReactor::Sweeper.run_once`: the owner is re-enqueued and the run finishes.
  - (e) Duplicate delivery of one rollback job, performed sequentially: the element is undone once,
    and the second outcome is `undone` with no failures.
  - (f) Contended element lock (R-07, U2): hold `map_element:<map>:<index>` with another owner while
    performing that element's rollback job.
    - The job stores no outcome, and enqueues a `MapElementRollbackWorker` job with
      `attempt: 1` through `perform_map_element_rollback_in`.
    - Release the lock and drain: the element is undone and there is no `element_in_flight` entry.
    - Repeat with the lock held through `lock_snooze_max_attempts` requeues: the outcome is
      `element_in_flight`, as today.
  - (g) Superseded context for the same index: register a second, completed element context id
    for index 2, as a sweeper re-dispatch would. Both contexts are undone once each, and there is no
    false `element_in_flight`.
- [X] T023 [P] [US1] Update `spec/ruby_reactor/rollback/map_rollback_spec.rb`:
  - Wrap the existing 008 examples in `[false, true].each { |fan_out| context "fan_out: #{fan_out}" }`,
    using `MapRollbackFixtures.parent`, so every 008 guarantee holds on both paths.
  - Add an inline-chunking example: 250 elements inline, and the element contexts are read in 3
    range reads of at most 100, highest index first (spy on the new range-read storage method).
  - Nested map inside an element (spec Edge Cases, G3): the element reactor contains an inline map
    `n` of `ElemOk`, then a step after it. For `fan_out: true` on the outer map and a later failure:
    - the nested map is rolled back inline inside the outer element's rollback job: its undos are
      logged between that element's later-step undo and its earlier-step undo;
    - no rollback job is dispatched for the nested map.
- [X] T024 [P] [US1] Update `spec/ruby_reactor/rollback/map_scale_spec.rb` (`:slow`) with a fan-out
  variant: 10,000 elements, `batch_size 50`, `collect` raises.
  - Every element is undone once.
  - The owner's serialized context size is independent of N (reuse the existing size assertion).
  - `QueueProbe` `max_burst <= 50`.

### Implementation for User Story 1

- [X] T025 [P] [US1] Create `lib/ruby_reactor/error/rollback_handed_off.rb`:
  `class RollbackHandedOff < Base`, with `attr_reader :map_id` and
  `initialize(map_id:, message: "rollback handed off at map #{map_id}")`. Document the contract as
  a control signal: never a failure, rescued only by `Executor` and `Reactor#undo` (R-04).
- [X] T026 [US1] In `lib/ruby_reactor/error/rescuable.rb`, make `===` return false for
  `Error::RollbackHandedOff`, with a comment explaining why it passes the `Rescuable` sites
  (R-04). T019(c) passes.
- [X] T027 [P] [US1] Add the context `rollback` field (DM §1): `attr_accessor :rollback` in
  `lib/ruby_reactor/context.rb`, included in both serialization hashes and restored in
  deserialization (`context.rollback = data["rollback"]`), with `failure` serialized via
  `ContextSerializer.serialize_value`. Add `rolling_back` to the known statuses in
  `lib/ruby_reactor/storage/redis_reactor_scan.rb`. Confirm `Worker::TERMINAL_STATUSES` does not
  include it.
- [X] T028 [US1] `lib/ruby_reactor/executor/compensation_manager.rb` (R-04, R-07):
  - `handle_step_failure` records `@pending = { step: step_config.name, error: error,
    compensated: false }` before `compensate_step`, and sets `compensated: true` after it returns.
  - Expose `attr_reader :pending`.
  - `rollback_completed_steps(&after_pop)` yields each popped entry after `undo_stack.pop`
    (no-op without a block).
  - Add `restore_rollback_failures(list)`.
- [X] T029 [US1] In `lib/ruby_reactor/executor.rb`, rescue the hand-off (R-04, S-2, S-3):
  - **`#undo_all` records and restores its level's failures around a hand-off** (G2). This is the
    path `ComposeStep#compensate` and `Reactor#undo` take into a child; they never go through
    `execute` / `resume_execution`.
    - On entry, if `@context.rollback` is present, call
      `compensation_manager.restore_rollback_failures(@context.rollback["failures"])`.
    - Wrap `rollback_completed_steps` in `rescue Error::RollbackHandedOff`: set
      `(@context.rollback ||= {})["failures"] = compensation_manager.rollback_failures`, then
      re-raise.
    - On normal completion, clear the saved failures and keep any `trigger` the caller owns.
  - Add `rescue Error::RollbackHandedOff => e` in `#execute` and `#resume_execution`, placed
    before the contention/park/`Rescuable`/`Exception` clauses.
  - Also let it through `#aborting_on_interruption`: re-raise without `mark_aborted`.
  - The handler calls `record_rollback_handoff(e)`:
    - Build `rollback = { "trigger" => "failure", "step" => pending_step, "compensated" => …,
      "failure" => serialize(provisional Failure built by
      `result_handler.create_failure_from_error` from the pending error), "failures" =>
      rollback_failures }`, keeping any existing `@context.rollback` trigger (for `undo`).
    - **Composed child** (`@context.root_context` present and this executor is not the owner):
      store it on `@context` and re-raise.
    - **Top-level**, inside the rescue while the lock is still held (I-6):
      - set status `:rolling_back` and `save_context`;
      - then run the handshake (R-05, U3): `storage.mark_map_rollback_handed_off(e.map_id, rc)`;
        then, if `count_map_rollback_outcomes == total` and `claim_map_rollback_signal`, enqueue the
        owner `Worker`;
      - log `event=ruby_reactor.rollback.handed_off context_id=… map_id=…`;
      - set `@result = DispatchResult.new(job_id: "map_rollback:#{e.map_id}", execution_id: …)`.
      - Put the handshake in one private method `hand_off_rollback!(map_id)`, reused by T039.
    - For a hand-off raised while no step failure is pending (a compose whose child handed off from
      inside `ComposeStep#run`), `step` is the current step and `compensated` is false.
  - Emit `:complete_reactor` with the `DispatchResult`, as a forward hand-off does.
- [X] T030 [US1] Add `Executor#resume_rollback` in `lib/ruby_reactor/executor.rb` (R-04):
  - Emit the `start_reactor` event and `acquire_context_lock`, then
    `compensation_manager.restore_rollback_failures(@context.rollback["failures"])`.
  - If `compensated` is false, `handle_step_failure(steps[step], provisional_error, {})`, rescuing
    `CompensationError` as `Map::Helpers#resume_parent_execution` did (see git history of
    `lib/ruby_reactor/map/helpers.rb`).
  - `rollback_completed_steps`.
  - Finalize:
    - `failure` trigger: rebuild the error and call `result_handler.handle_execution_error`, as
      `Helpers#resume_parent_execution` did (U6):
      `StepFailureError.new(failure.error, step: step, context: @context, original_error:
      (failure.error if failure.error.is_a?(Exception)), exception_class: failure.exception_class)`,
      plus `set_backtrace(failure.backtrace)` when present. `context:` supplies the reactor name and
      the redacted inputs of the final `Failure`;
    - `undo` trigger: `status = :cancelled`, `cancelled = true`,
      `cancellation_reason = "Undo triggered"`.
  - Clear `@context.rollback`, `update_context_status`, save, release (the same ensure ordering as
    T010).
  - Rescue `RollbackHandedOff` again, through the same handler, for a second fan-out map.
  - Emit `failed_reactor` / `complete_reactor`.
- [X] T031 [US1] In `lib/ruby_reactor/worker.rb#perform`, after deserialization, call
  `executor.resume_rollback` instead of `resume_execution` when `context.status.to_s ==
  "rolling_back"`. The snooze and contention rescue branches apply unchanged. T019 passes.
- [X] T032 [P] [US1] In `lib/ruby_reactor/sweeper.rb#run_once`, treat `rolling_back` like
  `running`: re-enqueue it when `async:<id>` is not held (R-05, S-5). Add a unit example to the
  existing sweeper spec (`spec/ruby_reactor/sweeper_spec.rb` or its current location).
- [X] T033 [US1] Storage for map rollback records (DM §5), in
  `lib/ruby_reactor/storage/redis_adapter.rb`, declared in `lib/ruby_reactor/storage/adapter.rb`,
  all keys with `durability_ttl`:
  - `count_map_element_context_ids(map_id, rc)`: `LLEN`.
  - `retrieve_map_element_context_ids_from_tail(map_id, rc, position, count)`: `LRANGE` of the
    given tail positions, returned in tail order.
  - `start_map_rollback(map_id, rc, **meta)`: `HSETNX` on a `created_at` sentinel plus `HSET` of
    the fields; returns `[created_bool, metadata]`.
  - `retrieve_map_rollback_metadata`.
  - `claim_map_rollback_positions(map_id, rc, count)`: `INCRBY`, returning a `start…stop` range
    clipped to `total`.
  - `store_map_rollback_outcome(map_id, rc, position, outcome_hash)`: `HSET` JSON, plus `SADD`
    indexes when `index` is present.
  - `count_map_rollback_outcomes`: `HLEN`.
  - `each_map_rollback_outcome(map_id, rc, &)`: `HSCAN`, count 500.
  - `map_rollback_indexes_seen(map_id, rc, indexes)`: a pipelined `SISMEMBER` returning booleans.
  - `mark_map_rollback_handed_off(map_id, rc)`: `SET`. `map_rollback_handed_off?(map_id, rc)`:
    `EXISTS` (R-05).
  - `claim_map_rollback_signal`: `SET NX`.
  - `map_rollback_summary(map_id, rc)`: `{total, settled, outstanding, failed}`, with
    `outstanding = total - settled` and failed counted from outcomes (A3).
  - `scan_map_rollbacks(count:)`: for the sweeper.
  - Unit examples in `spec/ruby_reactor/storage/redis_adapter_spec.rb`.
- [X] T034 [US1] Create `lib/ruby_reactor/map/element_rollback.rb`, `Map::ElementRollback` (R-07,
  DM §5 outcomes). Move `acquire_element_lock` and `rollback_element` out of `MapStep`.
  - `.call(map_id:, element_context_id:, element_class:, step_name:)` returns
    `{ "index" =>, "outcome" =>, "failures" => [] }`:
    - no row: `context_unavailable` (index nil, one entry);
    - `map_element:<map>:<index>` lock held after `MapStep::ELEMENT_LOCK_WAIT`: return `:contended`.
      The inline caller maps this to `element_in_flight`, which is today's inline behavior;
    - status `completed`/`aborted`: `Executor#undo_all`, passing a block to
      `rollback_completed_steps` that calls `executor.save_context` after each pop, then a final
      save; `undone` or `failed`, with failures tagged `map_step:`, `element_index:`;
    - else (`failed`, `halted`, or a superseded `running` context) `not_needed`.
  - Skip the lock in inline testing mode, as today.
  - `.perform(args)` is the job entry:
    - `Map::Helpers.normalize_arguments`;
    - `.call`;
    - on `:contended` with `attempt < lock_snooze_max_attempts`: call
      `perform_map_element_rollback_in(Worker.snooze_delay(config, nil), **args, attempt: attempt + 1)`
      and return, storing nothing (R-07, U2);
    - on `:contended` at the max: an `element_in_flight` outcome;
    - `store_map_rollback_outcome`;
    - log `event=ruby_reactor.map.rollback.element` with the `API` fields (T020(g));
    - if `(position + 1) % batch_size == 0`, `Dispatcher.dispatch_rollback_batch`;
    - if `count_map_rollback_outcomes == total` **and** `map_rollback_handed_off?` **and**
      `claim_map_rollback_signal`, enqueue the owner `Worker`. The `handed_off` gate is the
      handshake (R-05, U3): it never enqueues before the hand-off is saved, and never in inline
      mode.
- [X] T035 [US1] Rollback batch dispatch in `lib/ruby_reactor/map/dispatcher.rb`, new
  `Dispatcher.dispatch_rollback_batch(map_id:, parent_reactor_class_name:)` (R-02, R-06, R-08):
  - read the rollback metadata, `claim_map_rollback_positions(batch_size)`;
  - `retrieve_map_element_context_ids_from_tail`;
  - one `async_router.perform_map_element_rollback_async(...)` per position, with the args listed
    in `API` §Background workers.
  - Unit examples in `spec/ruby_reactor/map/dispatcher_spec.rb`: claims at most `batch_size`,
    newest-first ids, and no enqueue past `total`.
- [X] T036 [P] [US1] Routers and workers (`API` §Background workers):
  - Add `perform_map_element_rollback_async(**args)` and `perform_map_element_rollback_in(delay,
    **args)` to `lib/ruby_reactor/adapters/sidekiq/router.rb` and
    `lib/ruby_reactor/adapters/active_job/router.rb`. They mirror `perform_map_element_async` /
    `perform_map_element_in`: queue, string-key payload, `attempt` defaulting to 0.
  - Create `lib/ruby_reactor/adapters/sidekiq/map_element_rollback_worker.rb` and
    `lib/ruby_reactor/adapters/active_job/map_element_rollback_worker.rb`, mirroring the
    `map_element_worker.rb` files, whose `perform` calls `RubyReactor::Map::ElementRollback.perform(args)`.
  - Register them wherever the existing map workers are registered or required.
  - Add `RubyReactor::Adapters::Sidekiq::MapElementRollbackWorker` to
    `RubyReactor::RSpec::SidekiqHelpers.worker_classes` in `lib/ruby_reactor/rspec/sidekiq_helpers.rb`.
    Without it, `drain_async_jobs` never runs rollback jobs. The ActiveJob helper drains
    generically and needs no change.
  - Unit example in `spec/ruby_reactor/adapters/` that each router enqueues the right worker with
    string-key args.
- [X] T037 [US1] Rewrite `MapStep#compensate` / `#undo` in `lib/ruby_reactor/step/map_step.rb`
  (R-01, R-02, R-05, R-06, R-09, S-2, S-4):
  - **Fan-out** (`context.map_operations[step]` present):
    - `start_map_rollback` with `total = count_map_element_context_ids`, `batch_size` (metadata
      `batch_size`, else `Map::DEFAULT_BATCH_SIZE`), the owner ids and `reactor_class_info`;
    - on create, log `rollback.started` and `Dispatcher.dispatch_rollback_batch`;
    - then, if settled (`count_map_rollback_outcomes == total`), aggregate and return;
    - else raise `RollbackHandedOff.new(map_id:)`.
  - **Inline**: iterate tail positions in `Map::ROLLBACK_CHUNK` pages through
    `retrieve_map_element_context_ids_from_tail`, calling `Map::ElementRollback.call` per id, and
    collect failures and seen indexes.
  - **Aggregation**, shared by both modes (DM §5):
    - fan-out: failures from `each_map_rollback_outcome` (`failed` and `element_in_flight` only),
      **re-symbolized**: symbol keys, and symbol `step` / `kind` / `reason` / `map_step` values
      (U1);
    - **unavailable elements, reported once** (I2):
      - `started = composed_contexts[step][:started]` known: add a `context_unavailable` entry
        (`rollback_entry`) per started-but-unseen index (fan-out via `map_rollback_indexes_seen` in
        chunks of 1,000, inline from the in-memory Set), and **drop** nil-index
        `context_unavailable` outcomes;
      - `started` unknown: one unnamed entry per nil-index outcome;
    - log `rollback.completed` with the `API` fields (T020(g));
    - return `Success` or `Failure("map :#{step} rollback incomplete", rollback_failures:)`.
  - **Log** `rollback.started` with the `API` fields when `start_map_rollback` creates the
    records.
  - Delete `completed_elements`, `report_unavailable`, `rollback_element`, `acquire_element_lock`
    and the ponytail comment.
  - T020 and T023 pass.
- [X] T038 [US1] In `lib/ruby_reactor/map/element_executor.rb#perform_element`, call
  `store_map_element_context_id` only when `arguments[:serialized_context]` is nil. This is a fresh
  element context, not a parked or retried re-entry (R-06).
- [X] T039 [US1] Manual undo (R-12, DM §7, `API` §Reactor.undo), in `lib/ruby_reactor/reactor.rb`:
  - Add `UNDO_LOCK_WAIT = 5`.
  - `#undo` raises `Error::ValidationError, "rollback already in progress"` when the status is
    `rolling_back`.
  - It acquires `RubyReactor::Lock.new("async:#{root id}", owner: SecureRandom.uuid, ttl:
    context_lock_ttl, wait: UNDO_LOCK_WAIT)`, skipped in inline testing mode as
    `Executor#acquire_context_lock` does.
  - It sets `@context.rollback = { "trigger" => "undo", "compensated" => true, "failures" => [] }`
    before `executor.undo_all`. `undo_all` records its failures on a hand-off (T029).
  - It rescues `RollbackHandedOff`: status `rolling_back`, save inside the lock, then
    `executor.hand_off_rollback!(e.map_id)` (the T029 handshake), and returns `:handed_off`.
  - Otherwise it clears `rollback`, saves, and releases in `ensure`.
  - `Reactor.undo` skips `cancel` when `#undo` returned `:handed_off`.
  - **Cancel guard** (G1, FR-027): `#cancel` raises
    `Error::ValidationError, "rollback in progress; cannot cancel"` when the status is
    `rolling_back`. `Reactor.cancel` inherits it, and nothing else changes.
  - T021 passes.
- [X] T040 [US1] Rollback pass in `lib/ruby_reactor/map/sweeper.rb` (R-05, S-5): for each entry
  from `scan_map_rollbacks`,
  - re-dispatch every position below the claimed offset that has no outcome and no live
    `map_element:<map>:<index>` lock (the index comes from the element row, or dispatch it if the
    row is gone);
  - if every claimed position is settled and `offset < total`, call
    `Dispatcher.dispatch_rollback_batch`;
  - return a `rollback_redispatched:` count alongside the existing counts.
  - Unit examples in `spec/ruby_reactor/map/sweeper_spec.rb`.
  - T022(b)(c) pass.
- [X] T041 [US1] Inline testing mode (R-05): add an example to
  `spec/ruby_reactor/rollback/distributed_map_rollback_spec.rb` under `Sidekiq::Testing.inline!`
  (the one justified use; plan.md Complexity Tracking). A later failure after a fan-out map
  finishes:
  - no `rolling_back` status is ever persisted (spy on `store_context` payload statuses);
  - `mark_map_rollback_handed_off` is never called, and no owner `Worker` is performed nested inside
    the rollback (spy on `Worker#perform` call depth);
  - the final `Failure` equals the fake-mode result.

  The design guarantees this through the handshake (R-05); no fix-if-it-happens is left to
  implementation.
- [X] T042 [P] [US1] RSpec surface (`API` §RSpec):
  - Add a `be_rolling_back` matcher in `lib/ruby_reactor/rspec/matchers.rb`, with the same shape
    as `be_paused`.
  - In `lib/ruby_reactor/rspec/test_subject.rb`, add `rolling_back?`, and make `ensure_executed!`
    drain when the status is `running` or `rolling_back`.
  - In `lib/ruby_reactor/rspec/active_job_helpers.rb`, add `alias worker_class job_class` on
    `PendingJob`, so `pending_async_jobs.first.worker_class` works on both backends (U4). T020(a)
    and T048 use it under `for_each_async_backend`.
  - Add a spec in `spec/ruby_reactor/rspec/be_rolling_back_spec.rb`, including one example that uses
    `worker_class` on the ActiveJob backend.
- [X] T043 [US1] Dashboard API (R-15): in `lib/ruby_reactor/web/api.rb#hydrate_map_ref`, add
  `"rollback" => storage.map_rollback_summary(map_id, reactor_class_name)`
  (`{total, settled, outstanding, failed}`) when rollback metadata exists. Add a request example to
  the existing web API spec, using `spec/support/rack_test.rb`.
- [X] T044 [P] [US1] GUI (R-15, C4, A3). Every status surface learns `rolling_back`:
  - `gui/src/lib/reactors.ts`: add `'rolling_back'` to `STATUS_GROUPS.running`, with a comment, so
    the run counts and filters with live runs;
  - `gui/src/components/StatusBadge.tsx`: amber style and an undo icon for `rolling_back` (no grey
    fallback);
  - `gui/src/components/LiveView.tsx` and `gui/src/components/ReactorClassInstances.tsx`: add
    `rolling_back` to the status filter options;
  - `gui/src/components/ReactorDetail.tsx`: amber status colour, and disable "Cancel" for
    `rolling_back`, since the API rejects it (FR-027);
  - `gui/src/components/StepInspector.tsx`: show "Rolling back {settled}/{total} ({outstanding}
    outstanding, {failed} failed)" **only when the run's status is `rolling_back`** and the
    hydrated map ref has `rollback`.
  - Tests:
    - `gui/src/lib/__tests__/` for `matchesStatusFilter('rolling_back', 'running')`;
    - `gui/src/components/__tests__/ReactorDetail.test.tsx` for the colour, the disabled Cancel,
      and progress shown only while `rolling_back`.
  - `cd gui && npm test && npm run build`, and commit the rebuilt `lib/ruby_reactor/web/public/`
    bundle.
- [X] T045 [US1] Run `bundle exec rspec spec/ruby_reactor/rollback spec/ruby_reactor/executor spec/map`.
  T019–T024 and T041 must be green and the T003 bar held. Run the `:slow` T024 once:
  `bundle exec rspec spec/ruby_reactor/rollback/map_scale_spec.rb --tag slow`.

### Demo and docs for User Story 1 (Constitution VI + Development Workflow)

- [X] T046 [P] [US1] Create the demo reactors, **one reactor per file** named after its class
  (Constitution VI.1, C1). The demo runs with `eager_load = false`, so a fresh Sidekiq process
  resolves the element class by name through Zeitwerk and needs it in its own file. Use class-based
  steps, following `map_refund_demo_reactor.rb`:
  - `demo_app/app/reactors/distributed_refund_element_reactor.rb`: `DistributedRefundElementReactor`
    (`charge` step with an `undo` refund), plus its `DistributedRefundChargeStep` class in the same
    file, which is only referenced from it;
  - `demo_app/app/reactors/distributed_refund_demo_reactor.rb`: `DistributedRefundDemoReactor`:
    - `load_orders` (40 orders);
    - `charge_orders` map with `fan_out batch_size: 10` of `DistributedRefundElementReactor`;
    - `notify`, which fails when input `fail_notify: true`;
    - class-level `charges` / `refunds` logs, as in the existing demo.
- [X] T047 [US1] Register `demo:distributed_map_rollback` in
  `demo_app/lib/tasks/demo_reactors.rake`:
  - `desc "DistributedRefundDemoReactor — a fan-out map's elements are refunded by one rollback job each, at most batch_size per throw"`,
    `[:environment, :flush_redis]`.
  - Run with `fail_notify: true`, then print: the dispatch, a `rolling_back` line with
    `map_rollback_summary`, the polled final status, and `charges == refunds`.
- [X] T048 [US1] Create `demo_app/spec/reactors/distributed_refund_demo_reactor_spec.rb`
  (`type: :reactor`), using shipped helpers and matchers only:
  - `test_reactor(DistributedRefundDemoReactor, {fail_notify: true}, process_jobs: false)`;
    perform `pending_async_jobs.first.perform!` in a loop until a pending job's `worker_class`
    name ends in `MapElementRollbackWorker`, then `be_rolling_back`. These are shipped helpers
    only; `worker_class` works on both backends after T042;
  - then `drain_async_jobs`, `be_failure`, refunds equal charges;
  - a happy path `be_success`.
- [X] T049 [US1] Add a benchmark for SC-002 (quickstart §5, U7):
  - Create `demo_app/app/reactors/inline_refund_benchmark_reactor.rb`: `InlineRefundBenchmarkReactor`,
    the same steps as `DistributedRefundDemoReactor` with the same `DistributedRefundElementReactor`,
    but an inline map (no `fan_out`), and `notify` failing.
  - Register `demo:map_rollback_benchmark[count]` in `demo_app/lib/tasks/demo_reactors.rake`:
    - `desc "Times the serial in-process rollback against the distributed rollback of the same N elements (SC-002)"`,
      depending on `[:environment, :flush_redis]`;
    - build `count` orders;
    - time `InlineRefundBenchmarkReactor` (the baseline: today's serial algorithm, the inline-map
      rollback path);
    - time `DistributedRefundDemoReactor` (its declared `batch_size 10`), polling the status until
      terminal;
    - print both times and the ratio.
- [X] T050 [P] [US1] Documentation (FR-025, R-17):
  - `documentation/data_pipelines.md` §Rollback:
    - distributed per element with back pressure;
    - the `rolling_back` status;
    - steps before the map undone after every element;
    - at-least-once for an undo that was cut off, so undos must be idempotent;
    - the inline map reads 100 at a time.
  - §Back Pressure: it applies to rollback.
  - `documentation/background_and_async.md` §Fan-out maps:
    - rollback hand-off and resume;
    - `MapElementRollbackWorker`;
    - both sweepers cover rollback.
  - `documentation/core_concepts.md`: the rollback table `map` row, and `rolling_back` in the
    statuses.
  - `documentation/testing.md`: `be_rolling_back`.
  - `README.md`: the map rollback paragraph (~line 902), the status list, the Durability section,
    `Reactor.undo` behavior with a fan-out map, and `cancel` / `undo` rejected while
    `rolling_back`.
- [X] T051 [P] [US1] Add `CHANGELOG.md` entries:
  - Features: distributed map rollback, `rolling_back` status, `MapElementRollbackWorker` /
    router method, `be_rolling_back`;
  - Bug Fixes: sweeper re-dispatch kept `batch_size` / `atomic` (T007), save before
    releasing the context lock (T010);
  - a note on the extra owner-resume job per fan-out map (R-03).

**Checkpoint**: US1 works on its own. A large fan-out map rolls back distributed, the oracle holds,
recovery works, and the demo passes locally.

---

## Phase 4: User Story 2 - Fan-out map inside a composed child finishes (Priority: P2)

**Goal**: A root composing a child (at any depth) whose fan-out map hands off resumes and
finishes. Rollback travels through the root, distributed when US1 is in.

**Independent Test**: Root composes Child, and Child runs `map … fan_out batch_size: 1`. After
draining, the root is `completed`. Repeat with an interrupt after the map, and with a failing root
step after the compose step.

### Tests for User Story 2 ⚠️ (write first, confirm FAIL)

- [X] T052 [P] [US2] Write `spec/map/map_compose_fan_out_spec.rb` (US2 acceptance 1, 2, 5,
  FR-013–FR-015), with `for_each_async_backend` and `RollbackRecorder` fixtures:
  - (a) Root(`r1` → compose `c`(Child: `c1` → fan-out map `m` of `ElemOk` → `c2`) → `r2`):
    `be_success`, and `step_result(:r2)` present;
  - (b) Child has an interrupt `wait` after `m`: `be_paused_at(:c, :wait)` or the nested path the
    matcher supports, then `resume`, then `be_success`;
  - (c) Root → compose → Child → compose → Grandchild with the fan-out map: `be_success`;
  - (d) the owner `Worker` job enqueued by the collector carries the ROOT id, not the child id;
  - (e) the child's standalone row is never resumed: its stored status never becomes `completed`
    on its own.
- [X] T053 [US2] Add a rollback context to `spec/map/map_compose_fan_out_spec.rb` (same file as
  T052; US2 acceptance 3, 4, FR-016, S-3, spec Edge Cases):
  - (a) `r2` fails: the log shows every element undo, then `undo:c1`, then `undo:r1`, and the root
    is `be_failure`;
  - (b) an element of `m` fails under `atomic`: the ROOT is `be_failure`, not only the child's row;
    completed elements undone, then `c1`, then `r1`;
  - (c) `c2` (the child step after the map) fails: element undos, `undo:c1`, `undo:r1`;
  - (d) the oracle (I-7) against the same tree with an inline map;
  - (e) manual undo from the root (G2, spec Edge Cases): a completed root whose child ran the fan-out
    map; `Reactor.undo(root id)` makes the root `rolling_back`. After draining it is `cancelled`,
    and every element, `c2`, `c1` and `r1` is undone exactly once;
  - (f) failures survive the child hand-off (G2): `r2` fails, and `c2`'s undo returns a `Failure`.
    `c2` is undone before the child's map hands off, and after the resume its entry is still in the
    root's final `rollback_failures`.

### Implementation for User Story 2

- [X] T054 [US2] Store the owner tree before dispatch (R-03), in
  `lib/ruby_reactor/step/map_step.rb#prepare_async_execution`:
  - after `before_async_enqueue`, also `store_context(owner_context.context_id,
    ContextSerializer.serialize(owner_context), reactor_storage_name(owner_context.reactor_class))`
    when `owner_context != context`;
  - keep the child snapshot write, which the Dispatcher reads to resolve the source.
  - T052(a)(d)(e) pass.
- [X] T055 [US2] Verify and fix the re-entry path through `ComposeStep#run` →
  `executor.resume_execution` of the admitted child → `MapStep#run` adopt (T016). Touch
  `lib/ruby_reactor/step/compose_step.rb` only if T052(b)(c) show the child re-executing `c1` or
  re-dispatching. Record the finding in research.md R-03 if a change was needed.
- [X] T056 [US2] In `lib/ruby_reactor/map/sweeper.rb`, `recollect?`/`parent_live_lock?` check
  `async:<owner_context_id>` (falling back to the parent id), and `parent_already_collected?`
  reads the owner's status (terminal → collected) (S-5). Update the matching examples in
  `spec/ruby_reactor/map/sweeper_spec.rb`.
- [X] T057 [US2] Composed-child hand-off (S-3; needs US1 T029, T030, T037). Confirm that:
  - `Executor#record_rollback_handoff` (the `execute` path) and `Executor#undo_all` (the
    `ComposeStep#compensate` and manual-undo path, T029) both store the child's `rollback`,
    including its failures so far, on the embedded child context and re-raise;
  - root `resume_rollback` with `compensated: false` on the compose step finishes the child's
    rollback through `ComposeStep#compensate`, and the restored child failures reach the root's
    final `Failure`.

  Make T053 pass, touching `lib/ruby_reactor/executor.rb` / `lib/ruby_reactor/step/compose_step.rb`
  as needed.
- [X] T058 [US2] Run `bundle exec rspec spec/map spec/ruby_reactor/map spec/compose_spec.rb spec/ruby_reactor/rollback`.
  All green.

### Demo and docs for User Story 2

- [X] T059 [P] [US2] Create the demo reactors, class-based, **one reactor per file** named after its
  class (Constitution VI.1, C1), each step class living in the file of the reactor that uses it:
  - `demo_app/app/reactors/composed_fan_out_item_reactor.rb`: `ComposedFanOutItemReactor` (`ship`
    step with an `undo` "unship");
  - `demo_app/app/reactors/composed_fan_out_child_reactor.rb`: `ComposedFanOutChildReactor`
    (`reserve` → fan-out map `ship_items`, `batch_size: 2`, of `ComposedFanOutItemReactor` →
    `confirm`);
  - `demo_app/app/reactors/composed_fan_out_demo_reactor.rb`: `ComposedFanOutDemoReactor`
    (`prepare` → compose `fulfil` of `ComposedFanOutChildReactor` → `notify`, which fails when
    `fail_notify: true`), with class-level `shipped` / `unshipped` logs.
- [X] T060 [US2] Register `demo:composed_fan_out` in `demo_app/lib/tasks/demo_reactors.rake`:
  - desc: "ComposedFanOutDemoReactor — a fan-out map inside a composed child: the root resumes
    and finishes, and rolls back through the root", with `[:environment, :flush_redis]`;
  - print the happy path final status `completed`, and the failure path `failed` with
    `shipped == unshipped`.
- [X] T061 [US2] Create `demo_app/spec/reactors/composed_fan_out_demo_reactor_spec.rb`
  (`type: :reactor`), with shipped matchers only: the happy path is `be_success`; the failure path
  is `be_failure` with every shipped item unshipped.
- [X] T062 [P] [US2] Documentation:
  - `documentation/composition.md`: `compose` + `fan_out` supported; the top-level run resumes;
    how rollback travels.
  - `documentation/background_and_async.md` §Fan-out maps: the collector signals the owner run,
    and the map adopts its outcome on resume.
  - `README.md`: the composition section note.
  - `specs/future_improvements.md`: delete §"Fan-out map inside a composed child"; mark the
    "Map collector, failure branch" writer row as fixed by 009 R-03.
- [X] T063 [P] [US2] `CHANGELOG.md` Bug Fixes entry: "a fan-out map inside a composed reactor no
  longer leaves the root running forever". Add the S-6 note: maps started before the upgrade
  inside a composed child keep the old behavior.

**Checkpoint**: US1 and US2 both work independently.

---

## Phase 5: User Story 3 - Fan-out never floods the queue by default (Priority: P2)

**Goal**: `fan_out` without `batch_size` enqueues at most 50 element jobs per throw, forward and
rollback.

**Independent Test**: a fan-out map of 500 elements with no declared batch size never enqueues
more than 50 element jobs in one throw, and all 500 outcomes are collected.

### Tests for User Story 3 ⚠️ (write first, confirm FAIL)

- [X] T064 [P] [US3] Extend `spec/map/map_batch_size_spec.rb` (US3 acceptance 1–4, FR-017–FR-019,
  SC-004), with `for_each_async_backend` and `QueueProbe.drain_tracking("…MapElementWorker")`:
  - (a) 500 elements, no `batch_size`: `max_burst <= 50`, 500 results collected, and map metadata
    `batch_size == 50`. Queue depth is not asserted; the bound is per throw (FR-002, R-02);
  - (b) 20 elements: all 20 enqueued by the first dispatch;
  - (c) `fan_out batch_size: 200` over 500: `max_burst == 200`;
  - (d) 120 elements, no `batch_size`, a later step fails: the rollback probe on
    `MapElementRollbackWorker` has `max_burst <= 50` (requires US1; mark `pending` if US1 is
    absent).

### Implementation for User Story 3

- [X] T065 [US3] Change `MapStep#effective_batch_size` in `lib/ruby_reactor/step/map_step.rb` to
  `inputs.batch_size || RubyReactor::Map::DEFAULT_BATCH_SIZE`. Change the `Dispatcher.dispatch_batch`
  fallback in `lib/ruby_reactor/map/dispatcher.rb` to `arguments[:batch_size] ||
  RubyReactor::Map::DEFAULT_BATCH_SIZE`. Update the `MapBuilder#fan_out` comment in
  `lib/ruby_reactor/dsl/map_builder.rb` ("without it the whole source fans out at once" → default
  50). T064 passes.
- [X] T066 [US3] Run `bundle exec rspec spec/map`. Update any existing example that asserted
  "every element enqueued at once" for a source over 50, citing R-10 in the change.

### Demo and docs for User Story 3

- [X] T067 [P] [US3] Demo:
  - Add `DefaultBatchFanOutDemoReactor` in
    `demo_app/app/reactors/default_batch_fan_out_demo_reactor.rb`: 120 elements, `fan_out` with no
    `batch_size`, and a `collect` that counts.
  - Register `demo:default_batch_size` in `demo_app/lib/tasks/demo_reactors.rake` (desc, and
    `[:environment, :flush_redis]`), printing the map metadata `batch_size` and the collected
    count.
  - Add `demo_app/spec/reactors/default_batch_fan_out_demo_reactor_spec.rb` with shipped matchers:
    `be_success`, and `step_result` count 120.
  - **G5 (revised by /speckit-demo-tests)**: no burst matcher was added. The demo specs read the
    first throw with the shipped `pending_async_jobs` under `process_jobs: false`: 50 element jobs
    here, and 10 forward plus 10 rollback in the T048 spec. Gem spec T064 covers every throw, and
    the rake task prints the stored `batch_size` for the operator.
- [X] T068 [P] [US3] Documentation:
  - rewrite `documentation/data_pipelines.md` §"`fan_out` Without `batch_size`": default 50, no
    unbounded mode, set `batch_size` to change it;
  - `README.md` (~line 908, the "`batch_size` is optional" paragraph);
  - `demo_app/documentation/data_pipelines.md`, kept in sync;
  - `CHANGELOG.md` Features entry, with the throughput note (R-18).

**Checkpoint**: US1–US3 work independently.

---

## Phase 6: User Story 4 - The map failure policy says what it means (Priority: P3)

**Goal**: `atomic` names the policy. `fail_fast` still works with one deprecation warning per
call site, and declaring both is an error.

**Independent Test**: `atomic false` with one failing element completes with that failure
among the results. `fail_fast false` behaves the same and prints one deprecation line naming
`atomic`.

### Tests for User Story 4 ⚠️ (write first, confirm FAIL)

- [X] T069 [P] [US4] Write `spec/map/map_atomic_spec.rb` (US4 acceptance 1–4, FR-020–FR-022,
  SC-006):
  - (a) no declaration: one failing element fails the map and rolls back the completed elements;
  - (b) `atomic false`: the map completes, and the `ResultEnumerator` has one `Failure`;
  - (c) `fail_fast false` in a class body:
    `expect { define }.to output(/\[RubyReactor\] DEPRECATION: .* fail_fast.*atomic/).to_stderr`,
    with the behavior identical to (b), and the same site defined twice warns once;
  - (d) `fail_fast` and `atomic` in one map: `ValidationError` "declares both fail_fast and
    atomic" at class definition.

### Implementation for User Story 4

- [X] T070 [US4] Extract `lib/ruby_reactor/dsl/definition_warnings.rb`, module
  `Dsl::DefinitionWarnings`, holding `warn_definition(site, prefix, message)`,
  `warn_deprecation(site, message)` and the shared `deprecation_sites` Set, moved from
  `lib/ruby_reactor/dsl/step_builder.rb`. `StepBuilder` includes it, with no behavior change:
  existing step deprecation specs stay green.
- [X] T071 [US4] In `lib/ruby_reactor/dsl/map_builder.rb`:
  - include `DefinitionWarnings`;
  - add `atomic(enabled = true)`, which records `@atomic_declared = true`;
  - `fail_fast(enabled = true)` records `@fail_fast_site = caller_locations(1, 1).first`, sets the
    same ivar and warns via `warn_deprecation` with the `API` §Map DSL message;
  - `build` raises `Error::ValidationError` when both were declared;
  - rename `@fail_fast` to `@atomic`.
  - T069 passes.
- [X] T072 [US4] Migrate internal usages to `atomic`, keeping exactly one deprecated-alias
  example in `spec/map/map_atomic_spec.rb`:
  - `spec/map/fail_fast_spec.rb` and `spec/map/map_fail_fast_spec.rb`, renamed to
    `spec/map/atomic_inline_spec.rb` / `spec/map/map_atomic_async_spec.rb` via
    `git mv`;
  - `spec/map/map_retry_spec.rb`, `spec/map/map_async_retry_spec.rb`;
  - `spec/ruby_reactor/rollback/map_rollback_spec.rb`, `spec/ruby_reactor/rspec/helpers_spec.rb`;
  - `spec/support/map_rollback_fixtures.rb`.
- [X] T073 [P] [US4] Demo: in `demo_app/app/reactors/ar_map_reactor_not_fail.rb`, change
  `fail_fast false` to `atomic false`. Confirm `demo_app/spec/reactors/ar_map_reactor_not_fail_spec.rb`
  passes unchanged and that `demo:ar` prints no deprecation line.
- [X] T074 [P] [US4] Documentation:
  - rewrite `documentation/data_pipelines.md` §"fail_fast" as §"Atomic maps (`atomic`)",
    with the deprecation note for `fail_fast`;
  - the `README.md` mentions (~lines 902, 908);
  - `demo_app/documentation/data_pipelines.md`, kept in sync;
  - `CHANGELOG.md` Deprecations: `fail_fast` → `atomic`, removal no earlier than the next
    MAJOR.

**Checkpoint**: all four stories work independently.

---

## Phase 7: Polish & Cross-Cutting Concerns

- [X] T075 Register the aggregate `demo:map_execution_undo` in `demo_app/lib/tasks/demo_reactors.rake`
  (`desc "Distributed map rollback, composed fan-out, default batch size"`, depending on
  `[:environment, :flush_redis, :distributed_map_rollback, :composed_fan_out, :default_batch_size]`),
  and add `:map_execution_undo` to `demo:all`.
- [X] T076 [P] Sweep for leftover `fail_fast` (FR-024, G4): run
  `grep -rn "fail_fast\|failFast" lib gui/src documentation README.md demo_app/app demo_app/documentation demo_app/lib`.
  Rewrite every hit to `atomic` except three:
  - the deprecated DSL alias and its warning in `lib/ruby_reactor/dsl/map_builder.rb`;
  - `Map::Helpers.normalize_arguments`;
  - the CHANGELOG deprecation entry.

  Known hits: the comments at `gui/src/components/StepInspector.tsx:590` and
  `gui/src/components/DagVisualizer.tsx:385`. Rebuild the GUI bundle if any `.tsx` changed.
- [X] T077 [P] Update `specs/future_improvements.md`:
  - delete §"Rollback fan-out for very large maps" (Rollback follow-ups);
  - add a follow-up for "a synchronous caller's final save racing a worker resume", with a
    pointer from R-13's out-of-scope note.
- [X] T078 [P] Audit `rescue StandardError` / bare `rescue` sites on the rollback path for
  swallowing `RollbackHandedOff` (it is an `Error::Base`):
  - `grep -rn "rescue StandardError\|rescue =>" lib/ruby_reactor/{executor,step,map,reactor.rb,worker.rb}`;
  - add explicit re-raises where one sits between `MapStep#undo` and `Executor`/`Reactor#undo`;
  - list the sites checked in the PR description.
- [X] T079 Run the 007 evidence harness:
  `bundle exec ruby specs/007-execution-flow-analysis/evidence/run.rb | tail -1`. Update the
  expected sequences in `specs/007-execution-flow-analysis/evidence/probes/*.rb` only for fan-out
  map rollback scenarios whose element order legitimately changes (R-08), each with a comment
  citing 009 R-08. Everything else must match T003.
- [X] T080 Run `bundle exec rubocop` and fix offenses in the changed files, without
  `--disable-pending-cops`.
- [X] T081 Run the full suite: `bundle exec rspec`, and `bundle exec rspec --tag slow` for
  `map_scale_spec.rb`. All green. Rerun flaky failures alone before investigating.
- [X] T082 Run the demo specs locally:
  `cd demo_app && REDIS_URL=redis://localhost:6780/5 RAILS_ENV=test bundle exec rspec spec/reactors`.
  All green.
- [X] T083 Docker acceptance (Constitution VI.4), in an isolated compose project per quickstart §5
  (`-p rr_009` plus an override with unique `container_name`s and `ports: !reset []`):
  `bin/rails db:prepare && bin/rails demo:map_execution_undo`. The output matches quickstart §5.
  Ask before stopping another worktree's containers.
- [ ] T084 SC-002 benchmark (quickstart §5): with `demo-sidekiq` at `-c 10`, run
  `bin/rails "demo:map_rollback_benchmark[10000]"`. Record both times and the ratio (at least 5×)
  in the PR description. If it falls short, profile before changing the batch mechanism.
- [X] T085 Walk quickstart.md §1–§4 end to end and confirm every "Expected" row. Fix the
  quickstart if a command or path changed during implementation.
- [X] T086 Constitution re-check against `plan.md` §Constitution Check:
  - `README.md` and every `documentation/` file listed in R-17 updated;
  - CHANGELOG complete (Features, Bug Fixes, Deprecations);
  - demo reactor, rake task and matcher-only spec for each story, with one reactor per file;
  - no **new** `Sidekiq::Testing.inline!` outside T041. Existing uses in `map_recovery_spec`,
    `map_batch_size_spec` and the renamed `atomic_inline_spec` may remain. Check with
    `git diff main -- spec | grep '^+.*inline!'`, which must show only T041.

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: none.
- **Foundational (Phase 2)**: after Setup. Blocks every story. T010 and T015/T016 matter most: the
  owner-resume path and save-before-release are what US1's resume and US2 stand on.
- **US1 (Phase 3)**: after Foundational.
- **US2 (Phase 4)**:
  - after Foundational;
  - its specs (T052, T053) and T055 are independent of US1 in behavior;
  - T054 edits `map_step.rb` after T037, and T056 edits `map/sweeper.rb` after T040 (the same-file
    chains below);
  - T057 (rollback hand-off through a composed child) needs US1 T029, T030 and T037;
  - without US1, T053(a)–(d) pass with serial in-process map rollback, but (e)–(f) need US1.
- **US3 (Phase 5)**:
  - after Foundational;
  - T064 can be written any time after Foundational;
  - T065 edits `map_step.rb` and `dispatcher.rb` after T037 / T035;
  - T064(d) needs US1 (pending otherwise).
- **US4 (Phase 6)**:
  - after Foundational (T012 did the internal rename);
  - T069–T070 are independent;
  - T071 edits `map_builder.rb` after T065;
  - T072 edits `map_rollback_spec.rb` and `map_rollback_fixtures.rb` after T023.
- **Polish (Phase 7)**: after the desired stories.

### Within Phases

- Spec tasks first, confirmed failing.
- US1 order:
  1. T025–T028 (signal, context field, manager);
  2. T029–T031 (executor incl. `undo_all` and the handshake, then the worker; T019 green);
  3. T033–T036 (storage, element rollback, dispatch, workers);
  4. T037 (MapStep);
  5. T038–T041;
  6. T042–T044 (test surface, API, GUI).
- Tasks touching the same file are sequential even across stories. [P] never overrides this list:
  - `map_step.rb`: T012 → T013 → T014 → T016 → T037 → T054 → T065;
  - `result_handler.rb`: T012 → T013;
  - `executor.rb`: T010 → T029 → T030 → T057;
  - `reactor.rb`: T039;
  - `map/sweeper.rb`: T040 → T056;
  - `map/dispatcher.rb`: T012 → T035 → T065;
  - `map/element_executor.rb`: T012 → T038;
  - `dsl/map_builder.rb`: T012 → T065 → T071;
  - `storage/redis_adapter.rb`: T011 → T033;
  - `spec/ruby_reactor/rollback/distributed_map_rollback_spec.rb`: T020 → T021 → T041;
  - `spec/ruby_reactor/rollback/map_rollback_spec.rb`: T008 → T023 → T072;
  - `spec/map/map_compose_fan_out_spec.rb`: T052 → T053;
  - `spec/support/map_rollback_fixtures.rb`: T001 → T072;
  - `demo_reactors.rake`: T047 → T049 → T060 → T067 → T075;
  - `README.md`: T050 → T062 → T068 → T074;
  - `documentation/data_pipelines.md`: T050 → T068 → T074;
  - `documentation/background_and_async.md`: T050 → T062;
  - `CHANGELOG.md`: T051 → T063 → T068 → T074;
  - `demo_app/documentation/data_pipelines.md`: T068 → T074;
  - `specs/future_improvements.md`: T062 → T077.

### Parallel Opportunities

- Setup: T002 and T003 alongside T001.
- Foundational specs T004–T008 are all [P]. Implementation T009 is [P] beside T010–T012; T013
  follows T012.
- US1 specs T019, T020, T022, T023 and T024 are [P]; T021 follows T020. T025, T027, T032, T036,
  T042 and T044 are [P] once their inputs exist. Demo and docs tasks T046, T050 and T051 are [P].
- US2's T052 comes first, then T053.
- Once Foundational is done, the **spec** tasks of US3 (T064) and US4 (T069) can be written
  alongside US1. Their implementation tasks follow the same-file chains above.

---

## Parallel Example: User Story 1

```bash
# Specs first, together:
Task: "resume_rollback stub-construct spec in spec/ruby_reactor/executor/resume_rollback_spec.rb"      # T019
Task: "distributed rollback spec in spec/ruby_reactor/rollback/distributed_map_rollback_spec.rb"      # T020
Task: "recovery/fault-injection spec in spec/ruby_reactor/rollback/map_rollback_recovery_spec.rb"     # T022
Task: "both-path 008 coverage in spec/ruby_reactor/rollback/map_rollback_spec.rb"                     # T023

# Independent building blocks, together:
Task: "RollbackHandedOff in lib/ruby_reactor/error/rollback_handed_off.rb"                             # T025
Task: "context rollback field in lib/ruby_reactor/context.rb + redis_reactor_scan.rb"                  # T027
Task: "routers + MapElementRollbackWorker for sidekiq and active_job"                                  # T036
Task: "be_rolling_back matcher + TestSubject in lib/ruby_reactor/rspec/"                               # T042
```

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Phase 1 Setup.
2. Phase 2 Foundational: owner resume, save-before-release, metadata, rename internals.
3. Phase 3 US1: distributed rollback.
4. **Stop and validate**: T045, the demo spec T048, and quickstart §1.

### Incremental Delivery

1. Setup + Foundational: root-level maps resume through the owner, and the latent sweeper bug is
   fixed.
2. Add US1: large maps roll back distributed. This is the MVP.
3. Add US2: composed fan-out works; rollback through the root.
4. Add US3: default batch size 50.
5. Add US4: `atomic`.
6. Polish: Docker acceptance and the SC-002 benchmark.

---

## Notes

- `[P]` means different files and no dependency on an incomplete task.
- Commit after each task or logical group, with conventional commit messages: `feat:` for the
  stories, `fix:` for T007/T010.
- If a spec cannot be expressed with the shipped RSpec surface in `demo_app/spec/reactors/`, add
  the matcher to `lib/ruby_reactor/rspec/` (as T042 does). Never hand-roll scaffolding there.
- Record any design deviation found while implementing in research.md, under the decision it
  changes.
