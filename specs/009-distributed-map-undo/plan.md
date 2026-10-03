# Implementation Plan: Distributed Map Rollback and Bounded Fan-out

**Branch**: `distributed_map_undo` | **Date**: 2026-09-30 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `specs/009-distributed-map-undo/spec.md`

**Revised 2026-09-30 after `/speckit-analyze`**:

- per-throw back-pressure bound;
- started-element coverage;
- the handed-off handshake;
- requeue on a contended element lock;
- aggregation dedup and symbols;
- the `cancel` guard;
- the GUI status surfaces;
- one reactor per demo file;
- the justified `inline!` spec.

## Summary

Four changes to `map`, one shared mechanism:

1. **Distributed rollback (US1, P1)**. A fan-out map's compensate/undo stops loading every element
   into one process.
   - It starts a map rollback: one job per started element (only completed ones undo anything),
     with the forward back-pressure mechanism. No throw enqueues more than `batch_size` (R-02,
     R-06).
   - The rollback then hands off with `Error::RollbackHandedOff` (R-04). The undo stack is the
     resume cursor, the run becomes `rolling_back`, and it saves under its lock.
   - The owner's `Worker` is resumed once, and only after the hand-off is saved. Whichever of the
     last-settling job and the hand-off handler sees both "settled" and `handed_off` claims the
     signal (R-05). `Executor#resume_rollback` then adopts the settled map, undoes the steps before
     it and finalizes with the same `Failure` the inline path produces (I-7).
   - Inline maps keep rolling back in process, reading element states in chunks of 100 (R-01).
2. **Fan-out map inside a composed child (US2, P2)**. The collector stops resuming contexts. It
   signals the **owner** run, the top-level `root_context || context`, and `MapStep#run` adopts the
   settled outcome on re-entry at any depth (R-03). This also removes the collector's
   failure-branch write: map failures now roll back through the executor's normal path.
3. **Default batch size 50 (US3, P2)**. `Map::DEFAULT_BATCH_SIZE`, stored in the map metadata with
   `atomic`. This fixes the sweeper re-dispatch losing both (R-10).
4. **`atomic` (US4, P3)**. It renames `fail_fast`, which stays as a warned alias. Legacy job
   payloads are normalized in one place (R-11).

Supporting changes:

- `Reactor#undo` holds the run's context lock, and neither undo nor cancel is accepted on a
  `rolling_back` run (R-12, FR-027).
- An element rollback job requeues itself on a contended element lock before reporting it in
  flight (R-07).
- `resume_execution` saves before releasing that lock (R-13).
- Map undo records carry no arguments (R-14).
- Observability: `rolling_back` status, map rollback progress in the dashboard, and structured log
  lines (R-15).

## Technical Context

**Language/Version**: Ruby >= 3.0

**Primary Dependencies**: Sidekiq and ActiveJob adapters, Redis, dry-validation. Optional
OpenTelemetry middleware. GUI: React/Vite (`gui/`, built into `lib/ruby_reactor/web/public`). No
new dependencies.

**Storage**: Redis through `Storage::RedisAdapter`. New data (see [data-model.md](data-model.md)):

- Context: the `rollback` hash and the `rolling_back` status.
- Map metadata: `owner_context_id`, `owner_reactor_class_name`, `batch_size`, `atomic`.
- `map:<id>:owner_signalled`.
- The `map:<id>:rollback:{metadata,offset,results,indexes,handed_off,signalled}` records.

The element-context index write is deduplicated at the source.

**Testing**: RSpec against real Redis (`redis://localhost:6780`), with Sidekiq fake mode plus
`drain_async_jobs` for every async path. One new `inline!` spec, for the inline-mode settle check;
it is justified in Complexity Tracking.

- **Oracle** (I-7): the same reactor with an inline map and with a fan-out map.
- **Fault injection**: an interruption during an element undo, a dropped rollback job, a dropped
  owner resume.
- **Scale**: `:slow` tag, 10k elements.
- **Demo specs**: shipped matchers only, plus a new `be_rolling_back`.
- **SC-002**: a demo benchmark rake task on Docker Sidekiq at `-c 10` (quickstart §5).

**Target Platform**: Ruby gem (MRI), Sidekiq/ActiveJob workers, Rails demo app in Docker.

**Project Type**: Library (gem) with a bundled dashboard.

**Performance Goals**:

- No rollback job loads more than one element context.
- The coordinating owner holds no per-element state beyond the failures it reports (R-09).
- With 10 workers, rolling back 10k elements is at least 5× faster than the serial in-process
  rollback of the same elements, the inline-map path (SC-002).
- Enqueue burst at most `B` per throw. Outstanding jobs are not bounded: the trigger is
  position-based, as forward (R-02).
- Forward fan-out gains one job hop per map completion (collector → owner Worker, R-03).

**Constraints**:

- Single-writer rule (I-1): the collector and element rollback jobs never write a reactor context.
- A hand-off saves before its lock is released (I-6, R-13).
- The undo stack pops only after an undo returns (I-5, 008 R-16).
- `Error::Rescuable` must not match `RollbackHandedOff` (R-04).
- Legacy in-flight payloads (`fail_fast`, metadata without owner ids) keep working (S-6).
- An owner resume from a rollback requires `rollback:handed_off`, which is set after the hand-off
  save (I-2, R-05).
- A `rolling_back` run is never cancelled or undone again (I-8, FR-027).

**Scale/Scope**:

- About 24 library files touched. New files: `map.rb`, `error/rollback_handed_off.rb`,
  `map/element_rollback.rb`, one `map_element_rollback_worker.rb` per adapter, and
  `dsl/definition_warnings.rb` (extracted).
- 9 new spec files and about 14 updated, plus 2 new spec support files.
- Demo:
  - 7 reactor files, one reactor per file: `DistributedRefundDemoReactor`,
    `DistributedRefundElementReactor`, `ComposedFanOutDemoReactor`, `ComposedFanOutChildReactor`,
    `ComposedFanOutItemReactor`, `DefaultBatchFanOutDemoReactor`, `InlineRefundBenchmarkReactor`;
  - 4 rake tasks plus the `map_execution_undo` group;
  - 3 demo specs.
- 7 documentation files, CHANGELOG, and `future_improvements.md`. The constitution's worker-path
  drift (C5) was already amended to 1.3.1 during analysis remediation.
- GUI: 5 components plus `lib/reactors.ts`.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Status | Note |
| --- | --- | --- |
| I. Gem-First Design | PASS | Everything is in `lib/` behind the existing DSL. The new workers live in the existing adapter modules; the Sidekiq and ActiveJob routers both gain the method. No host coupling. |
| II. Saga Pattern Integrity | PASS (the feature strengthens it) | Large-map rollback stops being bounded by one job's time and memory. Step-level reverse order is kept (I-4). Every hand-off has a recovery path: the sweepers for lost jobs and resumes (S-5), and resume from the last saved undo after a crash (R-07). Fixes a hang that left composed runs with no recovery path. |
| III. Test-First with Real Infrastructure | PASS with one justified deviation | Each story's specs are written first and fail first, against real Redis, including the FR-011 log-shape spec (T020(g)). Async orchestration uses fake mode plus drain. There is one new `inline!` spec (T041), justified in Complexity Tracking. Existing specs that already use `inline!` gain no new `inline!` blocks. |
| IV. Observability by Default | PASS | `rolling_back` appears in the state model, the scan, and every dashboard status surface (badge, status groups, live and per-class filters, detail colour). Map rollback progress (`total/settled/outstanding/failed`) is shown in the API, and in the GUI while `rolling_back`. Structured key=value log lines cover rollback start, element and completion. Element undo middleware events keep firing. Rollback failures keep `map_step` / `element_index`, and the symbol values are restored. |
| V. Simplicity & SemVer | PASS with notes | See Complexity Tracking for the two mechanisms added. Code is deleted: `Helpers#resume_parent_execution` and its helpers, and the collector's failure branch. No config knob for the default batch size. `fail_fast` is aliased, not removed. MINOR (R-18), with CHANGELOG notes for the default batch size, `rolling_back`, the extra job hop and the deprecation. |
| VI. Demo-App Proof of Feature | PASS (planned) | One reactor per file, named after its class, so a fresh Sidekiq process autoloads an element class by name (`eager_load = false`). Demos: `DistributedRefundDemoReactor` (fan-out, a later failure, distributed rollback with progress), `ComposedFanOutDemoReactor` (compose → fan-out, happy and failure paths) and `DefaultBatchFanOutDemoReactor` (default batch size), each with its element and child reactors in their own files. Rake `demo:distributed_map_rollback`, `demo:composed_fan_out` and `demo:default_batch_size`, grouped as `demo:map_execution_undo` in `demo:all`, plus `demo:map_rollback_benchmark`. Matcher-only specs; `be_rolling_back` and the ActiveJob `PendingJob#worker_class` alias are added to `lib/ruby_reactor/rspec/`. `ar_map_reactor_not_fail.rb` migrates to `atomic false`. No new Docker service. |

- [x] Documentation impact identified (research R-17):
  - **README.md**: map section (~880–930), statuses, Durability.
  - **documentation/**: `data_pipelines.md`, `background_and_async.md`, `composition.md`,
    `core_concepts.md`, `testing.md`.
  - **demo_app/documentation/data_pipelines.md**: kept in sync.
  - **CHANGELOG.md**.
  - **specs/future_improvements.md**: remove the fixed items.
  - Carried into tasks.md as a required task per user story.

**Post-design re-check (after Phase 1)**: PASS.

- New public surface:
  - one DSL method (`atomic`);
  - one status;
  - two router methods with their worker per adapter;
  - one matcher and one test-helper alias;
  - the dashboard `rollback` field;
  - the `cancel` / `undo` guard on `rolling_back`.
- New internals: one control signal and one per-element rollback class, shared by the job and the
  inline path.
- The complexity is justified below.

## Project Structure

### Documentation (this feature)

```text
specs/009-distributed-map-undo/
├── plan.md                        # This file
├── research.md                    # Phase 0: R-01..R-18
├── data-model.md                  # Phase 1: records, statuses, outcomes
├── quickstart.md                  # Phase 1: validation guide
├── contracts/
│   ├── api-surface.md             # DSL, statuses, undo, routers/workers, dashboard, logs, matcher
│   └── rollback-protocol.md       # Invariants I-1..I-8, sequences S-1..S-6
├── checklists/requirements.md
└── tasks.md                       # Phase 2 (/speckit-tasks)
```

### Source Code (repository root)

```text
lib/ruby_reactor/
├── error/rollback_handed_off.rb        # new: control signal carrying map_id (R-04)
├── error/rescuable.rb                  # === false for RollbackHandedOff (R-04)
├── map.rb                              # new Zeitwerk namespace file: DEFAULT_BATCH_SIZE = 50,
│                                       #   ROLLBACK_CHUNK = 100 (R-10, R-01)
├── map/element_rollback.rb             # new: roll back one element (lock with requeue on contention,
│                                       #   per-entry checkpoint, outcome, handed_off-gated owner signal);
│                                       #   used by the job and the inline path (R-05, R-07)
├── map/collector.rb                    # settled → SET NX owner_signalled → enqueue owner Worker;
│                                       #   no context writes; legacy fallback to parent ids (R-03, S-6)
├── map/helpers.rb                      # delete resume_parent_execution & co.; add normalize_arguments
│                                       #   (fail_fast → atomic) (R-03, R-11)
├── map/dispatcher.rb                   # default batch size; atomic; rollback batch dispatch
│                                       #   (claim positions, LRANGE, enqueue) (R-02, R-06, R-10)
├── map/element_executor.rb             # register the id only for a fresh context; atomic (R-06, R-11)
├── map/sweeper.rb                      # rollback pass (missing positions, lost batch trigger);
│                                       #   owner lock for recollect (R-05, S-5)
├── step/map_step.rb                    # run: adopt on re-entry; owner ids + batch_size +
│                                       #   atomic in metadata; store the owner tree before dispatch.
│                                       #   compensate/undo: distributed start / settle / aggregate /
│                                       #   hand-off; inline chunked; aggregation dedups unavailable
│                                       #   entries and re-symbolizes. rollback_arguments → {} (R-01..R-10, R-14)
├── step/compose_step.rb                # none expected; covered by the specs (S-3)
├── executor.rb                         # rescue RollbackHandedOff in execute/resume_execution; handed_off
│                                       #   handshake; undo_all records/restores its level's failures; new
│                                       #   resume_rollback; save before releasing the context lock (R-04, R-05, R-13)
├── executor/compensation_manager.rb    # track the pending failing step + compensated flag; per-entry
│                                       #   callback on rollback_completed_steps (R-04, R-07)
├── executor/result_handler.rb          # undo entry uses step_config.rollback_arguments (R-14)
├── executor/retry_manager.rb           # atomic in element requeue args (R-11)
├── dsl/map_builder.rb                  # atomic; fail_fast alias + warning; both → error (R-11)
├── dsl/definition_warnings.rb          # new: warn_definition extracted from StepBuilder (R-11)
├── dsl/step_builder.rb                 # include DefinitionWarnings; StepConfig#rollback_arguments (R-11, R-14)
├── context.rb / context_serializer.rb  # `rollback` field (R-04)
├── reactor.rb                          # undo: context lock, reject rolling_back, hand-off → handshake,
│                                       #   skip cancel; cancel rejects rolling_back (R-12, FR-027)
├── worker.rb                           # rolling_back → resume_rollback; non-terminal (R-04, R-15)
├── sweeper.rb                          # re-enqueue rolling_back without an async: lock (R-05)
├── storage/redis_adapter.rb            # metadata fields; owner signal; rollback records; LRANGE by range
├── storage/redis_reactor_scan.rb       # rolling_back known status (R-15)
├── adapters/{sidekiq,active_job}/router.rb                       # perform_map_element_rollback_async / _in
├── adapters/{sidekiq,active_job}/map_element_rollback_worker.rb  # new
├── web/api.rb                          # map_ref hydration: rollback {total, settled, outstanding, failed} (R-15)
└── rspec/{matchers,test_subject,sidekiq_helpers,active_job_helpers}.rb
                                        # be_rolling_back; drain on rolling_back; register rollback worker;
                                        #   PendingJob#worker_class alias (R-16)

gui/src/lib/reactors.ts                              # STATUS_GROUPS.running += rolling_back
gui/src/components/StatusBadge.tsx                   # amber + undo icon for rolling_back
gui/src/components/{LiveView,ReactorClassInstances}.tsx  # rolling_back filter option
gui/src/components/ReactorDetail.tsx                 # rolling_back colour
gui/src/components/StepInspector.tsx                 # rollback progress while rolling_back
lib/ruby_reactor/web/public/                         # rebuilt bundle

spec/
├── support/{map_rollback_fixtures,queue_probe}.rb           # new helpers
├── ruby_reactor/executor/context_lock_save_order_spec.rb    # new: R-13 regression
├── ruby_reactor/executor/resume_rollback_spec.rb            # new: hand-off + resume (stub construct)
├── ruby_reactor/rollback/distributed_map_rollback_spec.rb   # new: US1 incl. oracle, back pressure, undo,
│                                                            #   cancel guard, log shape, inline mode (T041)
├── ruby_reactor/rollback/map_rollback_recovery_spec.rb      # new: fault injection, contention requeue, sweepers
├── ruby_reactor/rspec/be_rolling_back_spec.rb               # new
├── map/map_owner_resume_spec.rb                             # new: R-03 at root level
├── map/map_legacy_payload_spec.rb                           # new: fail_fast payloads (FR-023)
├── map/map_compose_fan_out_spec.rb                          # new: US2 incl. rollback through the root
├── map/map_atomic_spec.rb                              # new: US4
├── ruby_reactor/rollback/map_rollback_spec.rb               # updated: both paths, chunked inline, nested map
├── ruby_reactor/rollback/map_scale_spec.rb                  # updated: one element per job
├── ruby_reactor/map/{sweeper,dispatcher}_spec.rb            # updated: rollback pass, owner lock, rollback batches
├── ruby_reactor/storage/redis_adapter_spec.rb               # updated: metadata, owner signal, rollback records
├── ruby_reactor/sweeper_spec.rb                             # updated: rolling_back
├── map/map_batch_size_spec.rb                               # updated: default 50, metadata
├── map/map_recovery_spec.rb                                 # updated: re-dispatch keeps batch_size/atomic
└── map/{fail_fast→atomic_inline, map_fail_fast→map_atomic_async, map_retry, map_async_retry}_spec.rb

demo_app/
├── app/reactors/distributed_refund_demo_reactor.rb          # one reactor per file (Constitution VI.1)
├── app/reactors/distributed_refund_element_reactor.rb       #   + its charge step class
├── app/reactors/inline_refund_benchmark_reactor.rb          # same element, fan_out false (SC-002 baseline)
├── app/reactors/composed_fan_out_demo_reactor.rb
├── app/reactors/composed_fan_out_child_reactor.rb
├── app/reactors/composed_fan_out_item_reactor.rb
├── app/reactors/default_batch_fan_out_demo_reactor.rb
├── app/reactors/ar_map_reactor_not_fail.rb                  # fail_fast false → atomic false
├── lib/tasks/demo_reactors.rake   # demo:distributed_map_rollback, :composed_fan_out, :default_batch_size,
│                                  #   :map_execution_undo (in demo:all), :map_rollback_benchmark
└── spec/reactors/{distributed_refund,composed_fan_out,default_batch_fan_out}_demo_reactor_spec.rb

README.md, documentation/*.md, demo_app/documentation/data_pipelines.md, CHANGELOG.md,
specs/future_improvements.md   # per R-17
.specify/memory/constitution.md  # amended to 1.3.1 during analysis remediation (C5): worker path
```

**Structure Decision**: single gem project, existing `lib/ruby_reactor` layout. No new directories
under `lib/`. The new rollback specs sit next to 008's in `spec/ruby_reactor/rollback/`, and the
map DSL/dispatch specs in `spec/map/`.

## Delivery Order

The stories are independently testable. tasks.md is the authoritative order. The owner-resume
mechanism is foundational, because a failed fan-out map's rollback must run through the executor
(not the collector) before US1 can hand it off:

1. **Foundation** (blocks every story):
   - map metadata owner ids, `batch_size`, `atomic` (R-10);
   - `Map::DEFAULT_BATCH_SIZE`;
   - save before releasing the context lock (R-13), with its regression spec;
   - `StepConfig#rollback_arguments` (R-14);
   - `normalize_arguments` (R-11 internals);
   - **owner resume + adopt at root level (R-03)**: the collector rewrite and `MapStep#run`
     re-entry, deleting `resume_parent_execution`.
2. **US1: distributed rollback**:
   - a. `RollbackHandedOff`, `Rescuable` exclusion, the `rollback` context field, `rolling_back`
     status, executor rescue plus `resume_rollback`, `Worker` branch. Spec: a stub construct that
     hands off once, resumed by `Worker`.
   - b. `Map::ElementRollback`, with per-entry checkpoints (R-07).
   - c. Storage rollback records and dispatcher rollback batches; router methods and workers.
   - d. `MapStep#compensate` / `#undo`, both distributed and inline chunked. Oracle and
     back-pressure specs.
   - e. `Reactor#undo` lock, hand-off and the `cancel` guard (R-12).
   - f. Handshake-gated owner signal and contention requeue (R-05, R-07).
   - g. Recovery: the sweepers (S-5) and fault-injection specs.
   - h. Observability: logs, API field, every GUI status surface, matcher.
3. **US2: composed child**:
   - store the owner tree before dispatch;
   - compose specs (happy, interrupt, nested, rollback through the root, manual undo from the root);
   - child `undo_all` hand-off (S-3; needs US1 for the distributed variant).
4. **US3: default batch size**:
   - the fallback in `MapStep` and `Dispatcher`;
   - specs for 500, 20 and explicit elements.
5. **US4: `atomic`**:
   - the DSL, the warning, the both-declared error;
   - migrate internal specs and the demo;
   - a legacy payload spec.
6. **Demo, docs, CHANGELOG** per story, closing with the Docker acceptance run and the SC-002
   benchmark.

## Complexity Tracking

| Addition | Why needed | Simpler alternative rejected because |
| --- | --- | --- |
| Resumable rollback (`RollbackHandedOff`, context `rollback` state, `rolling_back`, `Executor#resume_rollback`) | FR-001 and FR-004: element rollbacks run in other jobs, and the steps before the map must wait for them without holding a worker. | **Waiting in place** holds a worker for the whole rollback, hits job timeouts, and turns a shutdown into `aborted`. **A sentinel return value** needs plumbing through six call sites. **Snooze-polling** reloads the parent blob on every poll. The undo stack already gives the resume cursor, so the addition is the signal plus about five persisted fields (R-04). |
| Owner resume + adopt-on-re-entry (collector signals the owner; `MapStep#run` adopts) | FR-013 to FR-015 (the composed-child hang), and the same resume path US1 needs. | **Collector writes the root** breaks the single-writer rule. **Special-casing composed children** leaves two completion paths and the collector's failure-branch write. This change deletes more than it adds (R-03). |
| Map rollback records (6 keys, including `handed_off`) | Per-position idempotent outcomes, atomic batch claims, an owner signal that is exactly-once and never early (the handshake), and naming unavailable indexes at bounded memory. | **Reusing the forward results hash** would mix forward and rollback outcomes for the same index, and the forward slots are still read by the `ResultEnumerator` of a map that completed. **Relying on the `async:` lock alone** to order the owner resume fails in inline job mode, where the lock is skipped and the owner would run nested on a stale blob. |
| One new `Sidekiq::Testing.inline!` spec (T041), a deviation from Constitution III | The subject is inline-mode support itself: R-05's claim that a map rollback settling synchronously never hands off and never enqueues a nested owner resume. It is a spec edge case (Edge Cases, "Inline job-testing mode"). | **Fake mode plus drain** cannot express it: jobs never run inside dispatch there, so the path under test never executes. It is scoped to one example. The existing `inline!` specs gain no new `inline!` blocks. |
