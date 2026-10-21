# Implementation Plan: Per-Reactor/Step Queues

**Branch**: `queue_config_and_background_override` | **Date**: 2026-10-15 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `specs/011-queue-config-background-override/spec.md`

## Summary

`queue <name>` on reactor classes, step classes and `step`/`async_step` blocks picks the queue a
unit's jobs use, falling back to the container's queue, then to the global `queue_name`. "Option 1"
is built from three mechanisms the gem already has:

1. **Placement** (US1, US3; R-02–R-04, R-06):
   - one resolver, `RubyReactor::Queues`, decides every queue;
   - every router method takes `queue:`, and each job carries its own queue as an argument;
   - every root-Worker dispatch goes through `Queues.enqueue_run`, which writes a small per-run
     dispatch record (`queue`, `since`). Sweepers and other non-owners re-dispatch to that queue,
     and the dashboard shows "waiting on `<queue>` since T".

   With no declaration the payloads are identical to today's.
2. **Forward hop = park** (US2, US3; R-05):
   - in a job, a node whose queue differs from the job's raises `Error::QueueHop`, a kind of
     `ExecutionParked`;
   - every executor on the stack parks its holds, as for contention. Reactor locks are leased for
     `context_ttl`;
   - the root saves while holding the run lock, and the Worker enqueues the continuation on the
     target queue. A hop back is the same check at the next node.
3. **Rollback hop = 009's rollback hand-off aimed at a queue** (US2, US3; R-07, R-08):
   - `RollbackHandedOff` gains `queue:`;
   - `rollback_completed_steps` raises it before undoing an entry that belongs elsewhere, and the
     `rolling_back` Worker continues on that queue;
   - a manual `undo` of a run whose tree declares a queue hands off the same way.

**Consistency first** (FR-019, R-09). Two configurations are rejected at `validate_definition!`
rather than weakened:

- a hop inside a map element, because elements re-run from the start when waiting or re-run;
- a hop under `with_ordered_lock`, because nothing keeps the nonce alive while the run waits.

Plus the static freeze (R-01): `queue` is private, so `MyReactor.queue(:x)` reaches
`method_missing` and raises `Can not modify static configurations in the runtime`.

## Technical Context

**Language/Version**: Ruby >= 3.0 (verified on 3.4.8)

**Primary Dependencies**:

- Sidekiq 7.3 (`set(queue:)`) and ActiveJob 7.2 (`set(queue:, wait:)`) adapters, Redis 5,
  dry-validation.
- Optional OpenTelemetry middleware.
- GUI: React/Vite (`gui/`), built into `lib/ruby_reactor/web/public`.

No new dependencies.

**Storage**: Redis through `Storage::RedisAdapter` (see [data-model.md](data-model.md)).

- New key: `reactor:<Class>:context:<id>:dispatch`, a hash `{queue, since}` with TTL `context_ttl`.
- New fields:
  - Step Result Record: `queue`;
  - map metadata: `queue` and `owner_queue`;
  - map rollback metadata: `queue`;
  - context `private_data["inherited_queue"]`;
  - trace entries: `queue`, plus a new `:queue_hop` entry.
- No migration. A run without a record goes to its reactor's effective queue.

**Testing**: RSpec against real Redis (`redis://localhost:6780`). Sidekiq fake mode plus
`drain_async_jobs`. Each dispatch group runs on both backends (`for_each_async_backend`).

- **Crash windows** (SC-004): a delegating router double that raises once, and replayed or duplicate
  jobs through `PendingJob#perform!`, followed by `Sweeper.run_once`.
- **No `inline!`**, and no stubbing of reactor internals.
- **Demo specs**: the shipped matchers only, plus R-12's `on_queue`, `have_undone_step` and
  `have_hopped_queues`.

**Target Platform**: Ruby gem (MRI), Sidekiq/ActiveJob workers, Rails demo app in Docker.

**Project Type**: Library (gem) with a bundled dashboard.

**Performance Goals**:

- **No declarations**: zero extra jobs. Two Redis writes per root-Worker dispatch (the record, and
  the pickup clear), and no change to the blob size.
- **Per hop**: one record `HSET`, one enqueue, and one `PEXPIRE` per reactor `with_lock`. The save
  is the park's, which already exists. This is the "one extra job per queue change" the spec
  accepts.
- **Resolution**: a constant-depth walk up the context chain per node. `declares_any?` is memoized.

**Constraints**:

- **Single writer**: non-owners never write the blob. The dispatch record is separate (010 J-5).
- **Persist before enqueue**, and **lock, then load** (010), for every hop and hand-off.
- **No hop in the calling process** (FR-006). No hop inside a map element, and none under an
  ordered lock (R-09).
- With no declarations, payloads, job counts and queues equal today's (FR-024, SC-002).
- Existing outcomes are unchanged for:
  - the `background` hand-off's release of reactor holds (F-2, documented, not changed);
  - snooze caps;
  - 009 map rollback hand-offs.

**Scale/Scope**:

- About 30 library files touched. New: `queues.rb`, `dsl/static_queue.rb`, `error/queue_hop.rb`,
  `error/static_configuration_error.rb`.
- About 12 new spec files, and about 6 updated.
- Demo: 3 reactor/step files, 1 rake task, 1 spec, and the `docker-compose.yml` Sidekiq queue list.
- 8 documentation files, plus the README, CHANGELOG and `future_improvements.md`.
- GUI: `ReactorDetail.tsx`, `StepInspector.tsx`, `lib/reactors.ts`, and the rebuilt bundle.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Status | Note |
| --- | --- | --- |
| I. Gem-First Design | PASS | Everything is in `lib/`, behind the DSL (`queue`) and the existing `Reactor` API. Queue placement lives in the routers (the adapter boundary), on both Sidekiq and ActiveJob. The backend-agnostic `Worker`, `StepWorker` and `Map::*` call the router, never a backend. No host coupling. |
| II. Saga Pattern Integrity | PASS (strengthened) | A hop never splits a step. The failing step compensates where it failed, and every undo runs once, on its unit's queue, through 009's hand-off (H-6). A manual undo of a run with queues hands off with the same `rolling_back` guards. The configurations that could repeat a completed step, or let an ordered run be passed, are rejected at definition time (R-09), not run weaker. Reactor holds survive hops (H-3), which today's hand-off does not do (F-2). |
| III. Test-First with Real Infrastructure | PASS | Every story's specs are written first and fail first, against real Redis, on both backends. Crash windows are simulated at the router boundary and by replaying jobs, never by stubbing executors. No new `inline!` spec. |
| IV. Observability by Default | PASS | Trace entries carry their `queue`, and `:queue_hop` entries record the path. Key=value logs: `ruby_reactor.queue.hop`, `ruby_reactor.queue.waiting`, and `queue=` on the existing dispatch lines. API `waiting_on` and per-step queue on the dashboard. `:before_async_enqueue` is fired before each hop's save, so OpenTelemetry context crosses it. |
| V. Simplicity & SemVer | PASS with notes | Two existing protocols are reused (park and rollback hand-off), and one resolver is added. Additions are justified in Complexity Tracking. MINOR, 0.9.0 (R-13). CHANGELOG migration notes: custom routers receive `queue:` once a queue is declared; Sidekiq step and map jobs move to the configured `queue_name` (F-1 fix); reactor locks are leased across hop waits. No new config knobs. |
| VI. Demo-App Proof of Feature | PASS (planned) | Class-based steps throughout (R-14). `QueueDemoReactor` (`queue :demo_orders`, `background after:`, compose `StripeDepositReactor` on `:demo_stripe`, `async_step` `QueueEmailStep` on `:demo_emails`, a failing variant for rollback hops, and a manual undo). Rake `demo:queues`, in `demo:all`. A spec using the shipped matchers. `docker-compose.yml`'s `demo-sidekiq` consumes the demo queues. |

- [x] Documentation impact identified (research R-15):
  - **README.md**: "Configuration", "Background Execution", "Async Steps & Reactors", "Map &
    Parallel Execution", "Durability & Recovery", "Testing".
  - **documentation/**:
    - `background_and_async.md`: a new "Queues" section;
    - `composition.md`;
    - `data_pipelines.md`, and `demo_app/documentation/data_pipelines.md` if it mirrors it;
    - `locks_and_semaphores.md`: the lease, the ordered-lock rejection, and the "Owner identity"
      correction (F-2);
    - `testing.md`;
    - `getting_started.md`.
  - **CHANGELOG.md**: Features, Bug Fixes, migration notes.
  - **specs/future_improvements.md**: hops inside map elements, sweeper grace for pending
    dispatches, and holds across the initial hand-off.
  - Carried into tasks.md as a required documentation task per user story.

**Post-design re-check (after Phase 1)**: PASS.

- New public surface:
  - one DSL method on three hosts, and one reader;
  - one error class;
  - two definition-time rejections;
  - one router keyword argument;
  - one API field, and two log events;
  - three RSpec matchers or chains, and `PendingJob#queue`.
- New internals:
  - one resolver module;
  - one park subclass, and one keyword argument on `RollbackHandedOff`;
  - one storage record, and a lease option on `Lock#detach`.
- The spec was revised for what the design found (R-17; see spec Status): FR-015, two edge cases,
  the Context table, and Assumptions.

## Project Structure

### Documentation (this feature)

```text
specs/011-queue-config-background-override/
├── plan.md                    # This file
├── research.md                # Phase 0: findings F-1..F-7, decisions R-01..R-17
├── data-model.md              # Phase 1: declarations, resolution, dispatch record, payloads, transitions
├── quickstart.md              # Phase 1: validation guide
├── contracts/
│   ├── api-surface.md         # DSL, rejections, runtime behavior, router contract, API, logs, RSpec
│   └── hop-protocol.md        # Invariants H-1..H-10, sequences P-1..P-5, crash windows
├── checklists/requirements.md
└── tasks.md                   # Phase 2 (/speckit-tasks)
```

### Source Code (repository root)

```text
lib/ruby_reactor/
├── queues.rb                          # new: of_context, node_queue, dispatch_queue, current, kwargs,
│                                      #   enqueue_run (record, then router), declares_any?,
│                                      #   validate_definition checks (R-02, R-04, R-09)
├── dsl/static_queue.rb                # new: private `queue`, `declared_queue`, method_missing →
│                                      #   StaticConfigurationError (R-01)
├── error/queue_hop.rb                 # new: QueueHop < ExecutionParked (queue, step)
├── error/static_configuration_error.rb # new
├── error/rollback_handed_off.rb       # + queue: (exactly one of map_id / queue)
├── dsl/reactor.rb                     # extend StaticQueue; validate_definition! → Queues checks (R-09)
├── step.rb                            # extend StaticQueue
├── dsl/step_builder.rb                # StepBuilder#queue; StepConfig#queue (block wins over the class)
├── dsl/compose_builder.rb, dsl/map_builder.rb   # `queue` stub → ValidationError
├── context.rb                         # current_queue (transient); append_execution_trace stamps queue
├── lock.rb                            # detach(lease:)
├── executor.rb                        # park_held_primitives!(lease) for QueueHop; hand_off_rollback!
│                                      #   queue branch → enqueue_run
├── executor/step_executor.rb          # hop check in execute_step (R-05); hand-off target queue (R-06)
├── executor/compensation_manager.rb   # rollback hop check in rollback_completed_steps (R-07)
├── executor/retry_manager.rb          # requeue via enqueue_run / perform_map_element_in(queue:)
├── executor/async_step_dispatch.rb    # dispatch_queue; record "queue"; perform_step_async(queue:)
├── step/async_reactor_step.rb         # inherited_queue on the child; enqueue_run(queue:)
├── step/map_step.rb                   # metadata queue/owner_queue; collector queue
├── map/{dispatcher,element_executor,collector,element_rollback,sweeper}.rb  # queue plumbing,
│                                      #   current_queue from the payload, owner via enqueue_run
├── worker.rb                          # 4th arg queue → current_queue; pickup clears since; rescue
│                                      #   QueueHop (dedupe, enqueue_run); snooze keeps the queue
├── step_worker.rb                     # "queue" → current_queue; perform_step_in(queue:)
├── sweeper.rb, step_sweeper.rb        # recorded queue; queue.waiting log
├── reactor.rb                         # run(all:) / continue hand-offs via enqueue_run; undo hand-off
│                                      #   when declares_any? (R-08)
├── storage/redis_adapter.rb           # store/retrieve/clear run dispatch record
├── adapters/{sidekiq,active_job}/router.rb   # queue: on every method; set(queue:); job args
├── adapters/{sidekiq,active_job}/*_worker.rb # accept the queue arg
├── web/api.rb                         # waiting_on; queue on async references
└── rspec/{matchers,sidekiq_helpers,active_job_helpers}.rb  # on_queue, have_undone_step,
                                       #   have_hopped_queues, PendingJob#queue

gui/src/components/ReactorDetail.tsx, StepInspector.tsx; gui/src/lib/reactors.ts
lib/ruby_reactor/web/public/                 # rebuilt bundle

spec/ruby_reactor/queues/
├── declaration_spec.rb                # R-01, SC-008
├── reactor_queue_spec.rb              # US1
├── backend_placement_spec.rb          # FR-007 on both backends, F-1, FR-024 payload equality
├── compose_hop_spec.rb                # US2-AS1..3, P-2, the lock lease
├── hop_crash_windows_spec.rb          # SC-004, forward
├── rollback_hop_spec.rb               # US2-AS6, AS10, US3-AS9
├── manual_undo_handoff_spec.rb        # US2-AS11, FR-018
├── map_queue_spec.rb                  # US2-AS7, FR-015
├── definition_rejections_spec.rb      # R-09
├── step_queue_spec.rb                 # US3
└── waiting_on_spec.rb                 # FR-020, SC-007
spec/ruby_reactor/web/api_waiting_on_spec.rb
spec/ruby_reactor/rspec/queue_matchers_spec.rb
spec/ruby_reactor/{sweeper,step_sweeper}_spec.rb, spec/ruby_reactor/map/sweeper_spec.rb  # updated
spec/ruby_reactor/adapters/{sidekiq,active_job}/router_spec.rb                           # updated

demo_app/
├── app/reactors/queue_demo_reactor.rb        # queue :demo_orders; background; compose; async_step
├── app/reactors/stripe_deposit_reactor.rb    # queue :demo_stripe; two undoable steps
├── app/reactors/queue_email_step.rb          # RubyReactor::Step, queue :demo_emails
├── lib/tasks/demo_reactors.rake              # demo:queues (in demo:all)
└── spec/reactors/queue_demo_reactor_spec.rb
docker-compose.yml                            # demo-sidekiq: -q default -q demo_orders -q demo_stripe -q demo_emails

README.md, documentation/*.md, CHANGELOG.md, specs/future_improvements.md   # per R-15
```

**Structure Decision**: single gem project, existing `lib/ruby_reactor` layout. Queue specs go in a
new `spec/ruby_reactor/queues/` folder. Router, sweeper and API specs are updated in place.

## Delivery Order

The stories are independently testable. tasks.md is the authoritative order.

1. **Foundation** (blocks everything):
   - the declaration DSL, the freeze and `StepConfig#queue` (R-01);
   - the `Queues` resolver (R-02);
   - router `queue:`, and the job argument → `current_queue` (R-03);
   - the dispatch record and `enqueue_run` (R-04);
   - trace stamping (R-11).
2. **US1 (P1)**:
   - the hand-off target (R-06), the retry, snooze and sweeper on the recorded queue (R-10);
   - the F-1 fix;
   - payload equality for undeclared runs.

   This is the MVP.
3. **US3, part 1 (P3, independent of hops)**: the `async_step` and `async_reactor` dispatch
   queues, the Step Result Record `queue`, and the StepSweeper.
4. **Hop foundation** (blocks US2 and US3 part 2):
   - `QueueHop`, the check in `execute_step`, and the Worker rescue with dedupe (R-05);
   - the lock lease;
   - the R-09 rejections.
5. **US2 (P2)**:
   - compose hops and the crash windows;
   - rollback hops (R-07);
   - the manual undo hand-off (R-08);
   - map element and collector queues;
   - interrupt resume and retry inside the child.
6. **US3, part 2**: a plain step's queue (hop, retry and undo on its queue).
7. **Observability**: the API `waiting_on`, the GUI, and the `queue.waiting` logs (R-11).
8. **RSpec surface, demo, docs and CHANGELOG** per story. Close with the Docker acceptance run of
   `demo:queues`.

## Complexity Tracking

| Addition | Why needed | Simpler alternative rejected because |
| --- | --- | --- |
| Run dispatch record (`…:dispatch`, a separate key) | FR-008 and FR-013: non-owners (the sweeper, the collector, a busy resume, the map-rollback signal) must re-dispatch to the run's queue. FR-020: "waiting on X since T", including after a recovery | **A field in the blob**: non-owners must not write the blob (010 J-5). **No record**: every recovery lands on the global queue and hops, and the dashboard cannot say what the run waits on |
| Queue as a job argument | H-7: a duplicate redelivered on the wrong queue must hop, not run a step there (SC-001). Sidekiq offers no way to read the current job's queue inside `perform` | **Trusting the record**: a stale duplicate would run units on the wrong worker pool. **A Sidekiq server middleware**: host coupling, and Sidekiq only |
| Lock lease (`detach(lease: context_ttl)`) on hop | FR-012: a reactor `with_lock` must not pass to another run while this run waits in a queue, and the wait is unbounded (the spec's "waits indefinitely") | **The park's TTL-bounded hold**: it lapses after `ttl` (60s by default), and the lock silently passes. **Rejecting `with_lock` reactors with hops**: needlessly drops a common, safe configuration |
| Two definition-time rejections (R-09) | FR-019: a map element cannot hop without repeating completed steps (F-5), and an ordered lock cannot survive an unbounded wait (F-7) | **Making element hops safe** (a per-index resume record, a resuming `Map::Sweeper`, a hop protocol for element rollback jobs): doubles 009's element surface for a configuration no story needs. **Running the unit on the element's queue silently**: forbidden by FR-019 |
| Private `queue` + `method_missing` freeze | FR-004 and SC-008: runtime class-level calls raise, while class bodies and `Class.new` blocks declare | **A seal on first run**: accepts runtime calls made before the first run. **`TracePoint(:end)`**: global, and misses `Class.new` blocks |
