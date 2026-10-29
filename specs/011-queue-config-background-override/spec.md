# Feature Specification: Per-Reactor/Step Queues

**Feature Branch**: `queue_config_and_background_override`

**Created**: 2026-10-11

**Status**: Draft — revised by `/speckit-plan` (2026-10-15, research R-17): FR-015, the map-element
and pre-feature-run edge cases, a new ordered-lock edge case, the Context table's "Today" queue row
and Assumptions.

**Input**: User description: `specs/queue_config_background_override.md` — "Select the `queue` a
reactor (and a step) executes in, so teams manage worker resources the way they already do with
Sidekiq and ActiveJob (`queue :my_specific_queue` on the reactor, `queue :emails` on a step class,
falling back to the global `queue_name`). When `compose`, `async_step` and `map` combine units that
declare different queues, prefer 'Option 1': every queue declaration is respected, even if that splits
what used to be a single background job into several dispatches — but reliability guarantees come
first." The input's "Override background" section (per-run `background` override) is deferred to its
own feature; the work done on it is kept in `specs/background_override.md`.

## Context

What happens today, and what this feature changes:

| Area | Today | After this feature |
| --- | --- | --- |
| Which queue a job uses | Every job (reactor hand-off, `async_step`, map element, collector, retry, park, sweeper) is meant to go to the single global `queue_name`. (On Sidekiq the step and map job classes actually use Sidekiq's own `default` queue, and the reactor worker reads `queue_name` once at load; fixed here, research F-1.) | Each job goes to the **effective queue** of the unit it runs: its own declaration, else the enclosing unit's, else the global `queue_name`. |
| Reactor declaring a queue | Not possible. | `queue :name` in the reactor class body. |
| Step declaring a queue | Not possible. | `queue :name` on a step class (or in a `step`/`async_step` definition block). |
| Composed child / map elements declaring another queue | The child's `background` is ignored once the parent is in a worker; the child runs in the parent's job, on the global queue. | The run moves to the child's queue for the child's work and back to the parent's queue afterwards ("Option 1"). Each move is a **queue hop**: persist, then hand the run to a job on the next queue. |
| Plain `step` whose class declares a queue | Not possible. | The run hops to the step's queue for that step (keeping its compensation and undo) and back. |
| Rollback after hops | Runs in the job that saw the failure, on the global queue. | Each completed unit is undone on its own effective queue; rollback hops with the same guarantees as forward hops. A manual `undo` of such a run hands off to a worker and hops the same way. |
| Re-dispatches of the same run (retry, park, interrupt resume, sweeper recovery) | Global queue. | The queue of the unit being re-dispatched, recorded with the run. |
| Class-level `queue` called at runtime | Not possible. | Raises `Can not modify static configurations in the runtime`; queue declarations are fixed for the life of the process. |

Terms used below:

- **Unit**: something that executes as part of a run — a step (plain or `async_step`), a composed
  child, a map (its elements), an `async_reactor` child.
- **Consistency first**: the library's distributed guarantees — persist before enqueue, exactly one
  job advancing a run, lock/rate-limit continuity, no side effect repeated because of a dispatch, full
  rollback on failure — outrank queue placement. Hops are the preferred behavior *only* where they
  keep every one of those guarantees (FR-019).
- **Effective queue**: the queue a unit's jobs use (resolution in FR-005).
- **Queue hop**: the run, already executing in a worker, reaches a unit whose effective queue differs
  from the queue of the current job; the current job persists the run and dispatches its continuation
  to a job on the other queue, then stops.

## Clarifications

### Session 2026-10-11

Two answers from this session (the per-run override API and fan-out maps under `run_in_process!`)
moved with the deferred override to `specs/background_override.md`.

- Q: Where does a manual `undo`/`cancel` (called from a controller or admin action) undo units that
  ran on declared queues? → A: It hands off to a worker and hops to each unit's queue, like failure
  rollback — accepted because it reuses the existing manual-undo hand-off (lock, reload, mark
  `rolling_back`, persist, enqueue; sweeper recovers lost `rolling_back` runs; worker applies the
  terminal status), so no guarantee is weakened. Runs with no queue declarations keep today's
  in-caller undo.
- Q: What happens to a run waiting on a queue no worker consumes (e.g. `:stripe` declared, no worker
  listening)? → A: It waits indefinitely and is never failed for queue lag; the run records and shows
  "waiting on `:stripe` since T" (dashboard, API, structured log) so the stall is visible.

### Session 2026-10-12

- Q: Ship the per-run background override (`run_in_process!`, `override_background`) in this
  feature? → A: No — deferred to its own feature; all work so far is kept in
  `specs/background_override.md`. This spec covers queues only.
- Q: Does the static configuration freeze ship with queues? → A: Yes, for `queue`: a class-level
  `queue` call on a reactor or step class outside its class definition raises `Can not modify static
  configurations in the runtime` (FR-004). The same freeze for `background` ships with the deferred
  override, together with its per-run alternative.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Run a reactor's background work on its own queue (Priority: P1)

A developer declares `queue :my_specific_queue` and `background after: :first` on `MyReactor`. The
global configuration says `queue_name = :default`. Running `MyReactor` executes `:first` in the
calling process and hands the rest to a job on `:my_specific_queue`. Every later job of the same run —
a step retry with backoff, a park on lock contention, recovery of a lost job by the sweeper, a
background resume after an interrupt — also lands on `:my_specific_queue`. A reactor without a `queue`
declaration keeps using `:default`, exactly as today.

**Why this priority**: This is the core ask and the MVP: teams can isolate a reactor's worker capacity
the same way they isolate any Sidekiq/ActiveJob worker. Every other queue story builds on the queue
being recorded and honored for one reactor.

**Independent Test**: Declare a queue on a reactor with `background`, run it under each supported
queue backend, and verify every job the run produces (first hand-off, retry requeue, park, sweeper
re-enqueue, background resume) is on the declared queue; verify an undeclared reactor's jobs are on
the global queue.

**Acceptance Scenarios**:

1. **Given** `queue_name = :default` and `MyReactor` declaring `queue :my_specific_queue` and
   `background after: :first`, **When** `MyReactor.run` is called, **Then** `:first` runs in the
   calling process and exactly one job is enqueued, on `:my_specific_queue`.
2. **Given** the same reactor, **When** a step after the hand-off fails with retries and backoff,
   **Then** each retry job is on `:my_specific_queue`.
3. **Given** the same reactor's job is lost after the run was persisted, **When** the sweeper
   recovers it, **Then** the recovery job is on `:my_specific_queue`.
4. **Given** a reactor declaring a queue and `background all: true`, **When** it runs, **Then** the
   whole run, including input validation, executes in a job on the declared queue.
5. **Given** a reactor with no `queue` declaration, **When** it runs with `background`, **Then** its
   jobs are on the global `queue_name` and the job count is identical to today's.
6. **Given** a reactor declaring a queue but no `background`, **When** it runs, **Then** it runs fully
   in the calling process and no job is enqueued because of the queue declaration.
7. **Given** a loaded reactor class, **When** code outside its class definition calls
   `MyReactor.queue(:x)` (or `StepClass.queue(:x)` on a step class), **Then** it raises `Can not
   modify static configurations in the runtime`, and the class's queue — and every other run in the
   process — is unchanged.

---

### User Story 2 - Composed children and maps run on their own queues (Priority: P2)

`StripeBankDeposit` declares `queue :stripe`. `MyReactor` declares `queue :my_specific_queue`,
`background after: :first`, and composes `StripeBankDeposit` as `:bank_deposit` between `:second` and
`:third`. After the hand-off, `:second` runs on `:my_specific_queue`, `:bank_deposit` (all of the
child's steps) runs on `:stripe`, and `:third` runs on `:my_specific_queue` again. A fan-out `map`
whose element reactor declares a queue runs each element job on that queue, while the collector that
resumes the owner runs on the owner's queue. Because the run now crosses jobs mid-flight, every queue
hop keeps the guarantees the existing caller-to-worker hand-off gives: the run is persisted before the
next job is enqueued, exactly one job owns the run at any time, a lost hop is recovered onto the right
queue, and a failure anywhere rolls the whole run back.

**Why this priority**: This is what makes the queue declaration trustworthy when reactors are
combined ("Option 1"). It is the riskiest slice, so it builds on Story 1's recorded queue and lands
after the simpler stories.

**Independent Test**: Run the `MyReactor`/`StripeBankDeposit` example and record the queue every step
executed on; inject a crash at each hop boundary (after persisting, before enqueueing; after
enqueueing, before the old job stops) and verify the run still completes once, or rolls back fully,
with no step executed twice concurrently.

**Acceptance Scenarios**:

1. **Given** the example above, **When** `MyReactor` runs to completion, **Then** `:second` and
   `:third` executed on `:my_specific_queue`, both `StripeBankDeposit` steps executed on `:stripe`,
   and the run made exactly two hops (into `:stripe`, back to `:my_specific_queue`).
2. **Given** a composed child with no `queue` declaration, **When** the parent reaches it, **Then**
   the child runs on the parent's effective queue and no hop occurs.
3. **Given** consecutive units with the same effective queue, **When** they execute, **Then** they
   share one job (no hop between them).
4. **Given** a crash after the run is persisted at a hop but before the next job is enqueued, **When**
   the sweeper runs, **Then** the run is re-dispatched to the queue it was hopping to and completes;
   no completed step re-runs its side effect.
5. **Given** a duplicate delivery of a hop job, **When** both copies start, **Then** only one advances
   the run; the other exits without executing any step.
6. **Given** `:third` fails after `:bank_deposit` completed on `:stripe`, **When** the run rolls back,
   **Then** `:third`'s compensation runs where `:third` failed (`:my_specific_queue`), the run hops to
   `:stripe` to undo `StripeBankDeposit`'s steps, hops back to `:my_specific_queue` to undo `:second`
   and `:first`, and ends `failed`; every undo runs exactly once.
7. **Given** a fan-out `map` whose element reactor declares `queue :deposits`, **When** the map fans
   out, **Then** every element job (and element retry/rollback job) is on `:deposits`, and the job
   that resumes the owner is on the owner's effective queue.
8. **Given** an interrupt inside a child on `:stripe` with `resume: :background`, **When** the run is
   resumed, **Then** the resume job is on `:stripe`.
9. **Given** a step with retries and backoff inside a child on `:stripe`, **When** it is requeued,
   **Then** the retry job is on `:stripe`.
10. **Given** a crash at a rollback hop boundary, **When** the sweeper recovers the run, **Then** the
    rollback resumes on the recorded queue from the first unit not yet undone; no completed undo runs
    again and the run still ends `failed`.
11. **Given** a run paused (or aborted) after `:bank_deposit` completed on `:stripe`, **When** an admin
    calls `MyReactor.undo(id)` from a controller, **Then** the call returns a handed-off result with
    the run `rolling_back`; the undo of `StripeBankDeposit`'s steps runs on `:stripe`, the rest on
    `:my_specific_queue`, and the run ends `cancelled`; a second `undo`, a `cancel` or a resume
    attempted meanwhile is rejected.

---

### User Story 3 - Steps declare their own queue (Priority: P3)

`Email` is a step class declaring `queue :emails`; `MyReactor` uses it as `async_step :email, Email`.
The email work is dispatched to a job on `:emails` while the reactor continues on its own queue. An
`async_step` defined inline can declare `queue :emails` in its definition block. `AnotherStep`
declares `queue :another_one` and is used as a plain `step` (`step :another, AnotherStep`): once the
run is in a worker, it hops to `:another_one` to run `:another`, then hops back for the next step on
the reactor's queue. `:another` stays a full saga step — its compensation and undo run as for any
step, on `:another_one`.

**Why this priority**: Completes the per-step story and depends on Story 1's resolution rules
(`async_step`) and Story 2's hop machinery (plain `step`).

**Independent Test**: Define an `async_step` and a plain `step` whose classes declare queues, run the
reactor, and verify the `async_step` job (and its retry/park/sweeper jobs) lands on its queue while
the parent continues, and that the plain step executes on its queue between two hops; fail a later
step and verify the plain step's undo runs on its queue.

**Acceptance Scenarios**:

1. **Given** `async_step :email, Email` with `Email` declaring `queue :emails`, **When** the reactor
   reaches `:email`, **Then** the step job is on `:emails` and the parent keeps executing on its own
   queue.
2. **Given** an `async_step` defined with a block declaring `queue :priority_emails` and a step class
   declaring `queue :emails`, **When** dispatched, **Then** the job is on `:priority_emails` (block
   wins).
3. **Given** an `async_step` with no queue declaration anywhere, **When** dispatched, **Then** its job
   is on the declaring reactor's effective queue.
4. **Given** the `async_step` job is lost, **When** the step sweeper recovers it, **Then** the
   recovery job is on the step's queue.
5. **Given** `async_reactor :child, ChildReactor` with `ChildReactor` declaring a queue, **When**
   dispatched, **Then** the child's jobs are on the child's queue.
6. **Given** `step :another, AnotherStep` with `AnotherStep` declaring `queue :another_one`, reached
   after the hand-off, **When** the run executes it, **Then** `:another` executes on `:another_one`
   and the next step on the reactor's queue executes on that queue (two hops).
7. **Given** the same step is reached before the `background` point, **When** the run executes it,
   **Then** it runs in the calling process; no job is created because of its queue (FR-006).
8. **Given** `:another` has retries with backoff and fails once, **When** it is requeued, **Then** the
   retry job is on `:another_one`.
9. **Given** a step after `:another` fails, **When** the run rolls back, **Then** `:another`'s undo
   runs on `:another_one`.

---

### Edge Cases

- A queue declaration never moves work out of the calling process by itself: steps reached before the
  `background` point (or in a reactor without `background`) run in the caller regardless of their
  queue. Queues only choose *which* queue a job uses.
- A unit declares `queue` twice with the same value: no-op (class bodies can be re-evaluated). With a
  different value: definition-time validation error, as with `background`.
- An invalid queue name (nil, empty, not a symbol or string): definition-time validation error naming
  the reactor or step.
- A reactor subclass inherits its parent's `queue` unless it declares its own.
- A `Class.new(RubyReactor::Reactor) { queue :x }` (anonymous class, test fixtures): its block is
  the class definition, so declarations inside it are allowed; `queue` calls on the class after the
  block returns raise (FR-004).
- Three-level compose (root → middle → child) with three different queues: one hop into each deeper
  queue and one hop back out of each, in execution order.
- A DAG where ready steps on different queues could run in either order: the order is the same
  deterministic order used today; hops follow it (no reordering to save hops).
- A run persisted before this feature (no recorded queue) is re-dispatched to its reactor's effective
  queue — the global `queue_name` for a reactor with no declaration — and hops from there if needed.
- A queue declaration changed in a deploy while runs are in flight: re-dispatches of an in-flight
  unit use the queue recorded with the run; units not yet started resolve from the current
  definition.
- A queue with no worker consuming it: the run waits indefinitely and is never failed or rolled back
  because of queue lag (a timer-driven failure would race the late job); it stays `running` and shows
  "waiting on `<queue>` since T" (FR-020). The existing bounded waits on `result(:name)` readers still
  report their timeout. Starting workers per queue is the operator's job.
- A rollback that must undo a step that ran in the calling process (before the `background` point):
  the undo runs on that step's effective queue — the run never returns to the caller.
- A run that never left the calling process (no `background`, or a failure before the hand-off
  point) rolls back entirely in the caller, with no hops, as today. A later manual undo of such a
  run follows FR-018.
- A map element (fan-out or inline) whose reactor composes a child (or uses a plain step or nested
  map) on another queue: rejected at definition time (FR-015, FR-019) — a waiting fan-out element
  is re-dispatched from the start by the map sweeper, and an inline element re-runs with its map
  step, so a hop there would repeat completed steps.
- A reactor declaring `with_ordered_lock` whose tree could hop: rejected at definition time
  (FR-019) — nothing keeps its ordered-lock position alive while the run waits in a queue, so a
  successor could pass it.
- Enqueueing the continuation of a hop fails (queue backend unavailable): the run is already
  persisted, so the current job fails or retries without advancing the run, and the sweeper recovers
  it; no step after the hop point runs in the wrong job.
- A configuration in which a hop cannot keep every guarantee (found while planning or testing): the
  configuration is rejected at definition time with an error naming the unit and the reason — the
  unit is never silently run on a different queue, and the guarantee is never weakened (FR-019).

## Requirements *(mandatory)*

### Functional Requirements

**Declaring queues**

- **FR-001**: A reactor class MUST be able to declare the queue its jobs use with `queue <name>`.
- **FR-002**: A step class MUST be able to declare `queue <name>`; a step definition block (`step` or
  `async_step`) MUST also accept `queue <name>`, which takes precedence over the step class's
  declaration.
- **FR-003**: The global `queue_name` configuration MUST remain the default for any unit with no
  declaration in its chain; the deprecated `sidekiq_queue` alias MUST keep working.
- **FR-004**: Queue declarations MUST be fixed for the life of the process. A `queue` call on a
  reactor class or a step class made outside that class's definition MUST raise `Can not modify
  static configurations in the runtime` and MUST leave the class's declarations unchanged. A class
  body evaluated again with the same declarations (code reload, a spec re-opening a fixture class)
  MUST keep working.

**Resolving the effective queue**

- **FR-005**: The effective queue of a unit MUST resolve as: its own declaration (step block, then
  step class, or the reactor class for a composed/mapped/async child), else the effective queue of
  the unit that contains it, else the global `queue_name`.
- **FR-006**: A queue declaration MUST NOT by itself cause work to leave the calling process; only
  `background`, `async_step`, `async_reactor` and fan-out maps create jobs.
- **FR-007**: Every job a run creates MUST be enqueued on the effective queue of the unit it executes,
  on both supported queue backends (Sidekiq and ActiveJob). This covers the first hand-off, queue
  hops, step retries with backoff, parks on contention, map element/collector/rollback jobs,
  `async_step` and `async_reactor` dispatches, background interrupt resumes, and sweeper recovery.
- **FR-008**: The queue a unit is executing on (or hopping to) MUST be recorded with the run's
  persisted state, so that every re-dispatch of that unit, including recovery after a crash, targets
  the same queue without re-resolving it from class definitions.

**Queue hops ("Option 1")**

- **FR-009**: When a run executing in a worker reaches a unit whose effective queue differs from the
  current job's queue, the system MUST hop: persist the run, then dispatch its continuation to a job
  on the unit's queue, then stop the current job without executing further steps.
- **FR-010**: After a unit on another queue completes, the next unit of the enclosing reactor MUST
  run on the enclosing reactor's effective queue (hop back), so that every unit's work executes on
  its own effective queue.
- **FR-011**: Consecutive units with the same effective queue MUST share a job; the number of hops in
  a run MUST equal the number of queue changes along its execution order.
- **FR-012**: A hop MUST preserve every guarantee of the existing caller-to-worker hand-off: the run
  is persisted before the continuation is enqueued; exactly one job advances the run at a time
  (duplicate or racing deliveries exit without executing steps); locks, semaphores, ordered locks and
  rate limits held by the run are neither released to another run nor charged twice across the hop;
  completed steps never re-run their side effects because of a hop.
- **FR-013**: A run lost at any point of a hop (after persisting, before enqueueing; after enqueueing,
  before the old job stops) MUST be recovered by the existing sweeper onto the recorded queue.
- **FR-014**: A failure anywhere in a run that hopped MUST roll back every completed unit of the run
  exactly as it would without hops (saga integrity). The failing step's compensation MUST run where
  it failed; each completed unit's undo MUST run on that unit's effective queue, hopping between
  queues in rollback order.
- **FR-015**: Inline (non-fan-out) map elements MUST follow the same rule as a composed child: the
  map runs on the element reactor's effective queue, hopping in and out as needed. Inside a map
  element (inline or fan-out) every unit MUST run on the element reactor's effective queue: a plain
  step, compose or nested map inside the element reactor that declares a different queue MUST be
  rejected at definition time (FR-019), because an element cannot hop without repeating completed
  steps (research R-09). `async_step` and `async_reactor` inside an element keep their own queues.
- **FR-016**: A plain `step` whose effective queue differs from the current job's queue MUST be
  executed through a hop (FR-009–FR-013) and MUST keep its full saga behavior (retries,
  compensation, undo), each on its own queue.
- **FR-017**: Rollback hops MUST meet FR-012 and FR-013: rollback progress is persisted before each
  hop, no undo or compensation runs twice because of a hop, and a rollback lost at any hop boundary
  is recovered onto the recorded queue and resumes from the first unit not yet undone.
- **FR-018**: A manual undo (`Reactor.undo(id)`, `#undo`, including `undo(failure:)`) of a run in
  which any completed unit has a declared queue MUST hand off through the existing undo hand-off
  path: the caller takes the run lock, reloads the run, marks it `rolling_back`, persists it, and
  dispatches the rollback to a job on the effective queue of the first unit to undo, then returns a
  handed-off result. The rollback then hops per FR-014/FR-017, and the worker applies the terminal
  status (`cancelled`, or `failed` with the given failure). While `rolling_back`, another undo,
  `cancel` or resume of the run MUST be rejected, as today. A run with no queue declarations MUST keep
  today's in-caller manual undo (FR-024).

**Consistency first**

- **FR-019**: Where respecting a queue declaration and preserving a distributed guarantee conflict,
  the guarantee MUST win. The system MUST NOT perform a hop that weakens persistence-before-enqueue,
  single ownership of the run, lock/semaphore/ordered-lock/rate-limit continuity, at-most-once
  side effects per completed step, or full rollback. Each such case MUST be resolved either by making
  the hop safe or by rejecting the configuration at definition time with an explanatory error —
  never by silently running the unit on another queue.

**Observability, test surface, docs**

- **FR-020**: The execution trace and the web dashboard MUST show, per executed step and per
  dispatched unit, the queue it ran on; each hop MUST be logged as a structured event naming the
  reactor, the unit, the source queue and the destination queue. While a run waits for a job on a
  queue (after a hand-off, hop, retry, park or recovery), its status MUST stay `running` (or
  `rolling_back`) and the dashboard, the API and the logs MUST show the queue it is waiting on and
  since when.
- **FR-021**: The built-in RSpec surface MUST let a spec assert which queue a step or unit executed
  on, without hand-rolled scaffolding (extend the shared helpers and matchers if needed).
- **FR-022**: `README.md`, the relevant `documentation/` files and `CHANGELOG.md` MUST describe queue
  declaration, resolution and hops (including their cost: one extra job per queue change).
- **FR-023**: `demo_app` MUST include an example reactor, rake task and spec demonstrating a reactor
  on its own queue composing a child on another queue and an `async_step` on a third queue, per
  Constitution Principle VI.

**Compatibility**

- **FR-024**: Reactors and steps with no `queue` declaration MUST behave exactly as today: same jobs, same
  queue, same job count.

### Key Entities

- **Queue declaration**: the `queue <name>` stated on a reactor class, a step class, or a
  `step`/`async_step` definition block.
- **Effective queue**: the queue a unit's jobs use, resolved per FR-005 and recorded with the run per
  FR-008.
- **Static configuration**: class-level declarations (`queue`, ...) — set only while the class is
  defined, fixed for the life of the process (FR-004).
- **Queue hop**: the persisted hand-over of a running run from a job on one queue to a job on another
  (FR-009–FR-013).

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: In the acceptance runs, 100% of jobs created by a run (first hand-off, hops, retries,
  parks, map jobs, async dispatches, interrupt resumes, sweeper recoveries) are on the effective queue
  of the unit they execute, on both queue backends.
- **SC-002**: The existing test suite passes unchanged, and for reactors without queue declarations
  the number of jobs per run and their queue are identical to the previous release.
- **SC-003**: For the composed example (`MyReactor` + `StripeBankDeposit`), every step is observed on
  its expected queue, and the number of jobs equals one hand-off plus one per queue change (here: 3).
- **SC-004**: With a crash injected at each hop boundary — forward and rollback — 100% of runs either
  complete or roll back fully; no step, compensation or undo executes twice and no two jobs advance
  the same run concurrently.
- **SC-005**: A developer can move a reactor to a dedicated queue by adding one line to the class, with
  the documentation describing it.
- **SC-006**: In the rollback acceptance runs (failure rollback and manual `undo`), every undo
  executes on its unit's effective queue (100%) and the run ends `failed` (or `cancelled`) with every
  completed unit undone.
- **SC-007**: For 100% of runs waiting on a queue, an operator can tell from the dashboard or API alone
  which queue the run is waiting on and for how long; no run is failed because of queue lag.
- **SC-008**: 100% of class-level `queue` calls made at runtime raise, and no runtime call can change
  which queue any run uses.

## Assumptions

- "Option 1" (hop) is the chosen semantics everywhere — composed children, maps, plain steps and
  rollback — at the cost of extra jobs. Consistency outranks it: the guarantees in FR-012–FR-014,
  FR-017 and FR-019 are the gate, and a hop that cannot meet them is rejected, not weakened.
- An undeclared unit inherits its container's queue (not the global default), so composing an
  undeclared reactor never causes a hop.
- Hop cost is accepted and documented: one extra job per queue change, forward and during rollback.
- The queue name is static per class or definition block. Queues computed from inputs, a per-run
  queue override on an instance, and `queue` on `compose`/`map` blocks are out of scope until a real
  use case needs them; the child reactor class's declaration covers those call sites. A class-level
  `MyReactor.queue(:x)` at runtime is not an override — it raises (FR-004). The same freeze for
  `background` ships with the deferred background override (`specs/background_override.md`).
- Queue priorities, weights and worker/process configuration are the queue backend's concern; the
  gem only chooses the queue name.
- The existing sweepers are the recovery mechanism for hops; no new recovery process is introduced.
- The caller-to-worker `background` hand-off keeps today's behavior for reactor-level `with_lock` /
  `with_semaphore` (released at the hand-off, re-acquired by the worker). Hops are stronger: they
  keep those holds across the wait (research F-2, R-05).
