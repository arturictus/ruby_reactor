# Research: Per-Reactor/Step Queues

**Feature**: [spec.md](spec.md) | **Plan**: [plan.md](plan.md) | **Date**: 2026-10-15

Each decision names the code it rests on. Line numbers are as of `7357a035`.

## Findings that shape the design

What the code does today, where it differs from what the spec assumes:

- **F-1 Sidekiq jobs do not all use `queue_name`.** `Adapters::Sidekiq::Worker` and
  `SweeperWorker` read `queue_name` once, when the class loads (`adapters/sidekiq/worker.rb:17`). A
  Rails initializer that sets it after `require` is ignored. `StepWorker`, `MapElementWorker`,
  `MapCollectorWorker` and `MapElementRollbackWorker` set no queue, so they run on Sidekiq's own
  `"default"`. The ActiveJob classes resolve `queue_name` per job (`queue_as { ... }`) and are
  right.
- **F-2 The `background` hand-off releases the reactor's own `with_lock`/`with_semaphore`.**
  `Executor#execute`'s `ensure` calls `release_locks unless @parked` (`executor.rb:180`). A
  `DispatchResult` is not a park, so the worker gets the lock again (`acquire_exclusive_lock`), and
  another run can take it in between. Only a **park** keeps the holds (`park_held_primitives!`,
  `executor.rb:798`), and only until the lock's TTL runs out, because the extender stops between
  deliveries. FR-012 says a hop keeps the hand-off's guarantees, including lock continuity. The
  hand-off does not have that guarantee today, so hops get it from the park path (R-05).
- **F-3 A park is already a "persist, requeue, stop" protocol.** Every executor on the stack parks
  its own holds and re-raises (`Error::ExecutionParked`). The root saves before it releases the run
  lock. `Worker#perform_locked` requeues once, at the top, while it still holds `async:<id>`
  (`worker.rb:189-203`). A forward hop is the same thing with a different queue and no delay.
- **F-4 Rollback already knows how to stop and resume in another job.** 009's
  `Error::RollbackHandedOff`:
  - unwinds a rollback without popping the undo entry it stopped at;
  - is recorded per level (`record_rollback_handoff`);
  - is saved as `rolling_back` and resumed by `resume_rollback`/`finish_rollback`, at any compose
    depth (`executor.rb:348-411, 967-1021`).

  A rollback hop is that hand-off, aimed at a queue instead of a map handshake.
- **F-5 Map elements cannot hop safely.**
  - **Inline:** a park re-runs the whole map step with fresh element contexts, so finished elements
    repeat (`executor.rb:605-613`, 005 R-01).
  - **Fan-out:** `Map::Sweeper` re-dispatches every missing index whose element lock is free
    **fresh**, from its inputs (`map/sweeper.rb:96-105`). An element waiting in a queue looks
    exactly like a lost one, so its completed steps would run again. Element rollback jobs
    (`MapElementRollbackWorker`) have no hop protocol either.
- **F-6 Nobody owns a run while its job waits in a queue.** The sweeper re-enqueues any
  `running`/`rolling_back` run whose `async:` lock is free, every sweep (`sweeper.rb:52-56`). That
  includes runs whose job is only waiting in a busy queue. The duplicates serialize on the lock and
  are harmless. Known, not changed (R-10).
- **F-7 Ordered locks rely on a heartbeat.** A nonce is poison-passed after `poison_pill_timeout`
  without a restamp, and nothing restamps it between deliveries (locks_and_semaphores.md, "Liveness
  heartbeat").

## R-01 Declaring a queue, and freezing it (FR-001, FR-002, FR-004)

**Decision**:

- `queue <name>` is a **private** class method on reactor classes (through
  `Dsl::Reactor::ClassMethods`) and on `RubyReactor::Step` subclasses. It stays callable where
  `self` is the class: a `class` body, a `Class.new(RubyReactor::Reactor) { ... }` block, and
  `self.queue` inside the body.
- `StepBuilder#queue(name)` declares it on a `step`/`async_step` block. A block declaration wins
  over the step class's declaration (FR-002). Coordination declarations reject a conflict instead,
  but the spec asks for block-wins here.
- Readers are public: `Reactor.declared_queue` and `Step.declared_queue` return the class's own
  declaration, else the superclass's (a subclass inherits), else nil. `StepConfig#queue` returns
  the block's declaration, else `impl.declared_queue`.
- Any call with an explicit receiver, such as `MyReactor.queue(:x)` or `MyReactor.queue`, goes
  through `method_missing`, because the method is private. It raises
  `Error::StaticConfigurationError` with the message `Can not modify static configurations in the
  runtime`, and changes nothing. One small module (`Dsl::StaticQueue`), extended by both class
  families, holds the writer, the reader and the `method_missing` / `respond_to_missing?`.
- Validation when `queue` is called:
  - the name must be a non-empty Symbol or String, else `Error::ValidationError` naming the class;
  - a second call with the same value does nothing (class bodies can be evaluated twice);
  - a second call with a different value raises `Error::ValidationError`, as `background` does.
- Names are stored as Strings, which is how both backends compare them.
- `compose` and `map` blocks get a `queue` stub that raises `Error::ValidationError`, naming the
  child reactor class as the place to declare it (spec Assumptions; same idiom as the `async` and
  `retries` stubs in `compose_builder.rb`).

**Rationale**:

- Ruby has no "class body finished" hook that covers both `class ... end` and `Class.new { }`.
  Privacy draws the line the spec wants, at no runtime cost: the DSL form uses an implicit
  receiver, and the runtime form uses an explicit one.
- Verified on Ruby 3.4: a private singleton method called with an explicit receiver reaches
  `method_missing`.

**Alternatives considered**:

- *`TracePoint(:end)` sealing.* A global hook that does not fire for `Class.new` blocks.
- *Seal on first run (`validate_definition!`).* `MyReactor.queue(:x)` called in an initializer,
  before the first run, would be accepted, and the spec says it raises.
- *Privacy plus a seal.* Only adds protection against `send(:queue, ...)` and
  `class_eval { queue ... }`, which reopen the class on purpose.
  `# ponytail: send/class_eval bypass the freeze; add a first-run seal if someone needs it.`

## R-02 Resolving the effective queue (FR-005, FR-006)

**Decision**: one module, `RubyReactor::Queues` (`lib/ruby_reactor/queues.rb`), holds the
resolution rules. Nothing else resolves a queue.

| Function | Answer |
| --- | --- |
| `of_context(ctx)` | `ctx.reactor_class.declared_queue`, else `of_context(ctx.parent_context)` when linked (composed child, inline map element), else `ctx.private_data["inherited_queue"]` (an `async_reactor` child, a fan-out element), else `configuration.queue_name`, read at call time |
| `node_queue(step_config, ctx)`, the queue whose job runs this graph node | plain `step`: `step_config.queue \|\| of_context(ctx)`. `compose`: `child.declared_queue \|\| of_context(ctx)`. Inline `map`: `element.declared_queue \|\| of_context(ctx)`. `async_step`, `async_reactor`, fan-out `map` and `interrupt`: `of_context(ctx)`, because they dispatch or pause from the container's job |
| `dispatch_queue(step_config, ctx)`, the queue of a dispatched unit's own jobs | `async_step`: `step_config.queue \|\| of_context(ctx)`. `async_reactor`: `child.declared_queue \|\| of_context(ctx)`. Fan-out map elements: `element.declared_queue \|\| of_context(ctx)` |
| `current(ctx)` | The queue of the job executing this context tree: a transient attribute on the root context, set by `Worker`, `StepWorker` and `Map::ElementExecutor`. Nil in the calling process |

- When an `async_reactor` child or a fan-out element is dispatched, its job lineage records the
  container's queue as `inherited_queue`. Otherwise an undeclared child would fall back to the
  global queue instead of its container's (spec Assumptions: "an undeclared unit inherits its
  container's queue").
- The compose and map child classes are read from the step's static `arguments`
  (`composed_reactor_class`, `mapped_reactor_class`), as `MapStep#element_class` already does.

**FR-006**: a queue never causes work to leave the calling process. Hops only happen when
`current(ctx)` is set, which is only inside a job.

## R-03 Enqueueing on a queue, on both backends (FR-007)

**Decision**:

- Every router method gains a `queue:` keyword argument. The router resolves `nil` to
  `configuration.queue_name` **at enqueue time**, and enqueues with:
  - Sidekiq: `klass.set(queue: q).perform_async/perform_in(...)`;
  - ActiveJob: `klass.set(queue: q, wait: d).perform_later(...)`.
- **Each job carries its queue:**
  - the root `Worker` takes a 4th positional argument, `perform(context_id, class_name,
    snooze_count = 0, queue = nil)`;
  - the hash payloads (`StepWorker`, `MapElementWorker`, `MapElementRollbackWorker`,
    `MapCollectorWorker`) carry a `"queue"` key.

  The worker uses the argument, or `queue_name` when it is absent. Sidekiq has no API to read the
  current job's queue inside `perform`, so the argument is the only reliable answer on both
  backends. A duplicate redelivered on another queue must still know where it actually is.
- **Payloads stay identical when no queue is declared.** Callers pass `queue:` (and the job
  argument) only when the resolved queue differs from `queue_name` (`Queues.kwargs(q)`). So a run
  with no declarations enqueues the same arguments as today (FR-024, SC-002). The exact-argument
  expectations in `spec/ruby_reactor/adapters/sidekiq/worker_spec.rb` and the sweeper specs keep
  passing unchanged.
- `Worker#handle_snooze` keeps `self.class.perform_in(...)` when the job has no queue argument.
  With one, it goes through `router.perform_in(..., queue:, snooze_count:)`, the backend boundary.
  A Sidekiq `Setter` has `perform_in`, but an ActiveJob `ConfiguredJob` does not.
- F-1 is fixed as a side effect: the router always names the queue. In the default configuration
  (`queue_name = :default`) nothing moves.
  - On Sidekiq with any other `queue_name`, step and map jobs now land on that queue instead of
    `"default"`.
  - A `queue_name` set after `require` now reaches the reactor Worker too.
  - CHANGELOG lists this under Bug Fixes.

**Alternatives considered**:

- *Read the actual queue in the job*: ActiveJob's `queue_name` works, Sidekiq's doesn't without a
  server middleware the gem would have to install.
- *Always pass `queue:`*: changes every payload and breaks custom routers and the spec doubles that
  match exact arguments (SC-002).
- *One worker class per queue*: generated classes, and a dynamic `queue` is not needed.

## R-04 The run's dispatch record (FR-008, FR-020)

**Decision**: a run keeps a small record next to its context, at
`reactor:<Class>:context:<id>:dispatch`. It is a hash with `queue` and `since`, and carries the
`context_ttl` TTL.

- **Write.** Every dispatch of the root `Worker` goes through one helper,
  `Queues.enqueue_run(context_id, class_name, queue: nil, delay: nil)`:
  1. it resolves the queue: the given one, else the record's `queue`, else the root reactor's
     effective queue;
  2. it writes `{queue, since: now}`;
  3. then it calls the router.
- **Callers of `enqueue_run`**:
  - owners: `Reactor#run` (`all:`), the `background` hand-off, `Reactor#continue`'s hand-offs,
    the retry requeue, `Worker` snoozes and hops, and `Reactor#undo`'s hand-off;
  - non-owners: `Sweeper`, `Map::Collector`, the owner signal of the map rollback (in both
    `Map::ElementRollback` and `Executor#hand_off_rollback!`), and `AsyncReactorStep`.
- **Pickup.** A `Worker` clears `since` (keeping `queue`) right after it loads the run, but only
  when its own job queue equals the record's `queue`, so a stray duplicate on another queue never
  hides a pending dispatch.
- **Read.** Non-owners re-dispatch to the record's `queue`. The dashboard and API report "waiting
  on `queue` since `since`" while `since` is set and the status is `running` or `rolling_back`.
- **Other dispatched units**:
  - an `async_step`'s Step Result Record gains `"queue"`: the dispatch queue, and its sweeper's
    target. Its `dispatched_at` is already the "since";
  - a fan-out map's metadata gains `"queue"` (the element jobs) and `"owner_queue"` (the
    collector);
  - the rollback metadata gains `"queue"`.

**Rationale**:

- The context blob has a single writer, its owning execution (010 J-5). The sweeper, the collector
  and `continue`'s busy hand-off all dispatch a run they do not own, so the queue and the waiting
  time cannot live in the blob.
- The record is advisory for **placement**. Correctness comes from the job's own queue argument
  and the hop check (R-05): a run dispatched to a stale queue hops on arrival.
- A crash between writing the record and enqueueing leaves "waiting since T" with no job. The
  sweeper re-enqueues it, because the run lock is free.
- **Fallback.** With no record, a run goes to its reactor's effective queue. That is the global
  `queue_name` for a reactor with no declaration, which covers every run persisted before this
  feature. The spec's edge case named the global queue; it now names the reactor's effective
  queue, so a deploy that adds a declaration does not cost those runs an extra hop.

**Alternatives considered**:

- *A `queue` field in the blob*: non-owners cannot write it.
- *Deleting the record at pickup*: then a non-owner, such as the collector, no longer knows which
  queue the run last used.

## R-05 Forward hop = a park on another queue (FR-009–FR-013, FR-016)

**Decision**:

1. **The check.** `StepExecutor#execute_step` checks before `:start_step`, and only when
   `Queues.current(ctx)` is set and the node is not already completed. The node is exempt while it
   is in progress: a `compose` whose child context exists is already running, and its own steps
   decide. Otherwise, when `node_queue != current`:
   - pin `ctx.current_step` to the node;
   - append a trace entry `{type: :queue_hop, at:, from:, to:, direction: :forward}`;
   - fire `:before_async_enqueue` on the root (OpenTelemetry propagation, before the save);
   - raise `Error::QueueHop.new(queue:, step:)`, a subclass of `Error::ExecutionParked`.
2. **Unwind.** Every executor on the stack follows the park contract: it parks its holds and
   re-raises. The root saves while it still holds `async:<id>`. Composed and nested children need
   no new code.
3. **Lock lease.** For a `QueueHop`, `park_held_primitives!` also extends each parked reactor
   `with_lock` to `context_ttl` (`Lock#detach(lease:)` runs `lock_extend`). A queue wait can be
   longer than the lock's normal TTL. On arrival `reattach` restores the normal TTL and the
   extender. Semaphore tokens never expire, so they need nothing.
4. **The Worker.** `Worker#perform_locked` rescues `Error::QueueHop` before its park branch:
   - **dedupe:** if the dispatch record already shows a pending dispatch (`since` set) to that
     queue, return;
   - else `Queues.enqueue_run(id, class, queue: target)` and log
     `event=ruby_reactor.queue.hop direction=forward`.

   The job enqueues while still holding the run lock (released in `perform`'s `ensure`), so the
   new job waits up to `CONTEXT_LOCK_WAIT` and then snoozes. A hop is never counted against
   `lock_snooze_max_attempts`.
5. **Resume.** The new job loads the run, re-adopts the parked holds, and
   `execute_current_step_and_continue` runs the pinned node first, the same deterministic order as
   before. A hop back (FR-010) is the same check failing at the next node.

**Rationale**: every FR-012 guarantee comes from code that already works for parks:

- persist before enqueue (the root's `ensure` save);
- one owner (`async:` lock then load, 010 R-02);
- holds kept across the gap (`park_held_primitives!`, plus the lease);
- the rate limit is not charged twice (the `rate_limit_charged` marker, `executor.rb:551`);
- no re-run of completed steps (the per-step checkpoint).

Recovery is the existing sweeper (FR-013), aimed at the recorded queue (R-04, R-10).

**Crash windows** (SC-004, [contracts/hop-protocol.md](contracts/hop-protocol.md) §3):

| Window | Outcome |
| --- | --- |
| After the save, before the enqueue | The record names the target or is stale, and the lock lapses. The sweeper re-enqueues to the record's queue. A stale queue hops on arrival |
| After the enqueue, before the old job stops | The old job may be redelivered: it takes the lock, loads the newer state, sees the node is not its queue, and dedupes |
| Duplicate delivery of the hop job | Serialized by the lock. The second loads the later state and runs only what is left, or hops or dedupes |

**Alternatives considered**:

- *Hop as a new kind of `background` hand-off.* That releases the holds (F-2) and violates FR-012.
- *A dedicated hop executor path.* It duplicates the park contract at every compose level.
- *Running steps in place and only placing future jobs* (Option 2). Rejected by the spec.

## R-06 Where the first job goes (FR-007, FR-011, US1)

**Decision**: a hand-off targets the queue of the first node the worker will run, so a run never
pays an empty job just to hop:

| Hand-off | Queue |
| --- | --- |
| `background before: :x` | `node_queue(x)` |
| `background after: :x` | `node_queue` of the first ready node after `:x`, in the graph's own deterministic order, else `of_context` |
| `background all: true` | The root reactor's effective queue (US1-AS4: validation runs there) |
| `continue` with `resume: :background`, or a busy hand-off | `enqueue_run` with no queue: the record's queue (where the run last ran, US2-AS8), else the reactor's effective queue |

A composed child's own `background` point, reached in the calling process, uses the same formula on
the child's context.

**Rationale**: FR-011 counts hops as queue changes between units. A hand-off to the reactor's queue
followed by an immediate hop would add a job that runs nothing.

## R-07 Rollback hop = a 009 rollback hand-off aimed at a queue (FR-014, FR-017)

**Decision**:

- **`Error::RollbackHandedOff` gains `queue:`.** `map_id` stays for the map handshake, and exactly
  one of the two is set.
- **The check.** `CompensationManager#rollback_completed_steps` peeks at the top entry before
  undoing it. It raises `RollbackHandedOff.new(queue:)` when all of these hold:
  - `Queues.current(ctx)` is set;
  - `node_queue(entry) != current`;
  - the entry is not a composite in progress, meaning a `compose` whose child context already
    carries a `rollback` state.

  It appends a `{type: :queue_hop, direction: :rollback}` trace entry first. The entry is not
  popped: it stays the resume cursor, as for a map hand-off.
- **No check before `compensate`.** The failing step's `compensate` runs in the job that saw the
  failure. `handle_step_failure` compensates before `rollback_completed_steps` starts.
- **The hand-off.** It follows 009 unchanged: `record_rollback_handoff` records `trigger`, `step`,
  `compensated: true` and `failures` at each level, and the root saves `rolling_back`. Then
  `hand_off_rollback!` branches. For a queue, it calls `Queues.enqueue_run(id, class, queue:)` and
  logs `event=ruby_reactor.queue.hop direction=rollback`, with no handshake. The `rolling_back`
  Worker resumes through `resume_rollback` → `finish_rollback`, which keeps popping and keeps
  checking.
- **In progress.** A compose's undo that already handed off inside its child resumes where it
  stopped: the root does not hop for the compose entry, and the child's entries hop for
  themselves. Without this the run would loop between the child's queue and the inner entry's
  queue.
- Runs that never left the calling process roll back there, with no hops (`current` is nil).

**Rationale**: FR-017's "persisted before each hop" and "no undo runs twice" are 009's invariants:
an entry leaves the stack only after its undo returned, and the hand-off saves the stack. The only
new code is the check and the enqueue branch.

**Alternatives considered**: *a separate rollback-hop state machine* (duplicates 009); *undoing
everything in the failing job* (FR-014 says no).

## R-08 Manual undo of a run with queue declarations (FR-018)

**Decision**: `Reactor#undo` keeps its lock → reload → guard sequence. Then:

- **The reactor's tracked tree declares a queue** (`Queues.declares_any?(reactor_class)`,
  memoized): the reactor itself, any plain step, and recursively any `compose`/`map` child. Then
  `undo`:
  1. sets the same `rollback` state as today (`trigger: "undo"`, and `failure_reason` when given);
  2. marks the run `rolling_back` and saves;
  3. calls `Queues.enqueue_run(id, class, queue: node_queue(undo_stack.last))`, or the root's
     effective queue when the stack is empty;
  4. returns `:handed_off`.

  `Reactor.undo(id)` already returns early on `:handed_off`. The Worker finishes through
  `finish_undo` (`cancelled`, or `failed` with the reason), hopping per R-07.
- **The tree declares no queue**: today's in-caller undo, unchanged (FR-024).

**Rationale**:

- It reuses the hand-off `undo` already has for fan-out maps (009 R-12). The `rolling_back` guards
  on `undo`, `cancel` and `continue` already reject the second call (US2-AS11).
- A static check is simpler than walking a run's undo stacks and nested contexts. It errs only
  toward handing off a run whose declared units never ran, and that run still ends `cancelled`,
  through one job on its effective queue.

**Alternative considered**: undo in the caller until the first declared entry, then hand off. That
splits one undo across two places, while the spec asks for one hand-off at the start.

## R-09 Configurations rejected at definition time (FR-019)

**Decision**: `validate_definition!` (before the first run, or at boot or in CI) raises
`Error::ValidationError` naming the reactor, the unit and the reason for:

1. **A hop inside a map element.** A map, fan-out or inline, whose element reactor contains a
   hop-bearing unit with a different queue. Hop-bearing units are plain `step`s, `compose`s and
   nested `map`s, searched recursively through `compose`. "Different" means a declaration other
   than the element reactor's own, or any declaration when the element reactor has none.
   `async_step` and `async_reactor` inside an element are allowed, because they dispatch their own
   jobs. **Why:** F-5. An inline element repeats finished elements when its map step re-runs. A
   fan-out element that waits in a queue is re-dispatched fresh by `Map::Sweeper`, repeating its
   completed steps. Element rollback jobs cannot hop. The element reactor's own queue is still
   honoured: element jobs, retries and rollback jobs run on it (US2-AS7), and an inline map hops
   into and out of it as a whole.
2. **A hop in a `with_ordered_lock` reactor.** A hop-bearing unit anywhere in its tree, through
   `compose`, whose node queue can differ from the reactor's own. **Why:** F-7. Nothing restamps the
   nonce while the run waits in a queue, so `poison_pill_timeout` would let a successor pass a
   live run, a silent ordering violation.

Checked and safe, so not rejected:

- reactor and composed-child `with_lock` (leased, R-05);
- `with_semaphore` (tokens do not expire);
- `with_rate_limit` (charged once);
- `with_period` (marked on success);
- step-level coordination: a hop happens before a step starts, and `compose`/`map` cannot declare
  step-level coordination;
- `async_step` and `async_reactor` (dispatch, not hop).

**Spec impact**: FR-015's second sentence and the fan-out element edge case change from "the
element's job hops" to "rejected at definition time", the route FR-019 and the last edge case give
for exactly this ("found while planning").

**Alternative considered**: *elements adopt the root model.* A per-index resume record, lock-then-load
from storage, a `Map::Sweeper` that resumes instead of re-dispatching fresh, plus a hop protocol
for element rollback jobs. That doubles 009's element surface for a configuration no story needs
(US2-AS7 only needs the element's own queue). Recorded in `specs/future_improvements.md`.

## R-10 Recovery onto the recorded queue (FR-013)

**Decision**:

| Sweeper | Re-dispatches to |
| --- | --- |
| `Sweeper` | `Queues.enqueue_run(id, class)`: the record's queue |
| `StepSweeper` | `record["queue"]`, passed through `perform_step_async`/`perform_step_in(queue:)` |
| `Map::Sweeper` | Missing elements → `meta["queue"]`; collector retrigger → `meta["owner_queue"]`; rollback positions → the rollback metadata's `queue` |

Each sweeper logs `event=ruby_reactor.queue.waiting queue= since=` when it re-dispatches a run that
recorded a pending dispatch, which gives FR-020 its structured log for recovery.

**Known, not changed** (F-6): a run waiting in a queue nobody consumes is re-enqueued on every
sweep, and the duplicates exit once a worker appears. Recorded in `specs/future_improvements.md`
("sweeper grace for pending dispatches") with the trade-off: telling a pending job from a lost one
would mean asking the queue backend.

## R-11 Observability (FR-020, Constitution IV)

**Decision**:

- `Context#append_execution_trace` also stamps `queue: Queues.current(root)` when it is set. Every
  `:run`, `:undo`, `:compensate` and `:contention_park` entry written in a job names its queue.
  Caller-process entries stay as today.
- `:queue_hop` trace entries (R-05, R-07) record the path a run took.
- Log lines, key=value:
  - `ruby_reactor.queue.hop` with `reactor`, `execution_id`, `step`, `from`, `to`, `direction`;
  - `ruby_reactor.queue.waiting`, from the sweepers;
  - the existing `background.handoff`, `async_step.dispatched` and `async_reactor` dispatch lines
    gain `queue=`.
- API (`web/api.rb`):
  - the reactor detail gains `waiting_on: {queue, since}` from the dispatch record;
  - each async-step and async-reactor reference gains `queue`;
  - trace entries already pass through.
- GUI: `ReactorDetail.tsx` shows a "Waiting on `<queue>` since `<time>`" line, and
  `StepInspector.tsx` shows each step's queue. `gui/src/lib/reactors.ts` gets the types. Rebuild
  into `lib/ruby_reactor/web/public`.
- A hop raises no `:failed_*` event. The hopping step never fires `:start_step` in the source job,
  and the run emits `:snooze_reactor`, as a park does.

## R-12 RSpec surface (FR-021, Constitution VI)

**Decision**: added to `lib/ruby_reactor/rspec/`:

- `have_run_step(:x).on_queue(:q)`: a chain on the existing matcher. It reads the `queue` of the
  step's `:run` trace entry. For an `async_step` it reads its Step Result Record's `queue`.
- `have_undone_step(:x)`, with `.on_queue(:q)`: from the `:undo` trace entries. Needed for the demo's
  rollback path (US2-AS6).
- `have_hopped_queues(*queues)`: the ordered `to` queues of the run's `:queue_hop` entries, with an
  optional `.during_rollback` chain.
- `PendingJob#queue` (`pending_async_jobs`) for job-placement assertions. `drain_async_jobs`
  already drains every queue.

## R-13 Compatibility and versioning (FR-024, Constitution V)

**Decision**: MINOR, 0.9.0. CHANGELOG:

- **Features**: `queue` on reactors, steps and step blocks; hops; manual undo hand-off for runs
  with queue declarations; `waiting_on`; the matchers.
- **Bug Fixes**: F-1.
- **Migration notes**:
  - custom `async_router` implementations receive `queue:` once a queue is declared;
  - Sidekiq users whose `queue_name` is not `default` see step and map jobs move to it;
  - a reactor-level `with_lock` held by a run waiting on a hop is held for up to `context_ttl`.

With no declarations, the job arguments, job counts and queues are unchanged in the default
configuration.

## R-14 Demo (FR-023, Constitution VI)

**Decision**:

- **Reactors**, in `demo_app/app/reactors/`, one per file, all class-based:
  - `QueueDemoReactor`: `queue :demo_orders`, `background after: :reserve`, `step :reserve`,
    `compose :deposit, StripeDepositReactor`, `step :confirm`, `async_step :email, QueueEmailStep`;
    a `fail_at_confirm` input drives the rollback path;
  - `StripeDepositReactor`: `queue :demo_stripe`, two steps with `undo`;
  - `QueueEmailStep`: `queue :demo_emails`.
- **Rake**: `demo:queues` prints each step's queue, the hops, the undo queues of the failing run,
  and a manual `undo` hand-off.
- **Spec**: `demo_app/spec/reactors/queue_demo_reactor_spec.rb` uses only the shipped matchers,
  including R-12's.
- **Docker**: the `demo-sidekiq` service command becomes
  `bundle exec sidekiq -q default -q demo_orders -q demo_stripe -q demo_emails`. Without that, the
  demo's queues have no consumer.

## R-15 Documentation (Constitution Development Workflow)

- **README.md**: "Configuration" (`queue_name` is the default, `queue` per unit), "Background
  Execution" (a `queue` example and the hop cost), "Async Steps & Reactors", "Map & Parallel
  Execution" (the element-queue rule), "Durability & Recovery" (recorded queue, waiting runs),
  "Testing" (the matchers).
- **documentation/background_and_async.md**: a new "Queues" section covering declaration,
  resolution, hops (with the job-count rule), rollback and manual undo hops, waiting runs, the
  backend notes and the rejected configurations.
- **documentation/composition.md**: a composed child's queue, and hops in and out.
- **documentation/data_pipelines.md**, and `demo_app/documentation/data_pipelines.md` if it
  mirrors it: element queues, and the no-hop-inside-element rule.
- **documentation/locks_and_semaphores.md**: the lock lease across hops, the ordered-lock
  rejection, and correcting "Owner identity" for the hand-off (F-2).
- **documentation/testing.md**: `on_queue`, `have_undone_step`, `have_hopped_queues`,
  `PendingJob#queue`.
- **documentation/getting_started.md**: one line on `queue`.
- **CHANGELOG.md**: R-13.
- **specs/future_improvements.md**: hops inside map elements (R-09), sweeper grace (R-10), and
  holds across the initial hand-off (F-2).

## R-16 Testing approach (Constitution III, SC-001–SC-008)

- Real Redis (`redis://localhost:6780`). Sidekiq fake mode plus `drain_async_jobs`, and every
  dispatch group also runs on the ActiveJob `:test` adapter (`for_each_async_backend`), for SC-001
  "both backends".
- Job placement: Sidekiq `Sidekiq::Queues[name]`, and ActiveJob `enqueued_jobs[:queue]`, through
  `PendingJob#queue`.
- **Crash windows** (SC-004), with no stubbing of reactor internals:
  - **before the enqueue:** the router raises once, from a router double that delegates;
  - **after the enqueue:** `PendingJob#perform!` replays the old job's arguments;
  - **duplicate delivery:** the same job is performed twice;
  - **rollback boundaries:** the same three windows during a rollback.

  Each then runs `Sweeper.run_once` and drains, and asserts completion or full rollback, each
  undo once, and no concurrent advance (the lock).
- **Freeze** (SC-008): explicit-receiver calls raise for reactor and step classes, and for
  anonymous classes after their block.
- **FR-019**: one spec per rejection. **FR-024**: the existing suite, unchanged, plus a payload
  equality check for an undeclared reactor.

## R-17 Spec revisions made by this plan

- **FR-015**, second sentence, and the fan-out element edge case: rejected at definition time (R-09).
- **Edge case**: a run without a recorded queue goes to its reactor's effective queue (R-04).
- **Edge cases**: a `with_ordered_lock` reactor whose tree can hop is rejected (R-09).
- **Context table, "Today"**: corrected for F-1.
- **Assumptions**: the caller-to-worker hand-off keeps today's release of reactor-level holds (F-2),
  and hops keep them (R-05).
