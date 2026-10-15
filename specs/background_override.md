# Per-Run Background Override (deferred)

**Status**: Deferred. Split out of `specs/011-queue-config-background-override` on 2026-10-12, so that
spec covers only per-reactor/step queues. This file keeps everything decided so far. Start the feature
with `/speckit-specify specs/background_override.md`.

## Original input

Taken verbatim from `specs/queue_config_background_override.md` (section "Override background"):

> Imagine this scenario
>
> ```ruby
> class MyWorker
>   include Sidekiq::Worker
>
>   def perform(params)
>     MyReactor.run(params)
>   end
> end
> ```
>
> Or
>
> ```ruby
> class KafkaConsumer
>   def consume(elem)
>     MyReactor.run(params)
>     mark_consumed(elem)
>   end
> end
> ```
>
> There are cases where the background declaration have to be skipped or modified.
> Here is an approach that we can investigate an or evaluate
>
> ```ruby
> class KafkaConsumer
>   def consume(elem)
>     MyReactor.brackground(false).run(params)
>     mark_consumed(elem)
>   end
> end
> ```
>
> or
>
> ```ruby
> class KafkaConsumer
>   def consume(elem)
>     result = MyReactor.brackground(after: :confirm_order).run(params)
>     if result.success?
>       mark_consumed(elem)
>     else
>       # we will have to retry this event at least in this example
>     end
>   end
> end
> ```
>
> Because it's not the same executing the request in a controller that we need to return some kind
> operation registered given the http constraints than starting the execution from a background
> process like the sidekiq process

## Context

| Area | Today | After this feature |
| --- | --- | --- |
| `background` from a worker or consumer | Always honored. A run started from a Sidekiq job or a Kafka consumer still hands off and returns a dispatch result. | The caller can disable the hand-off with `run_in_process!`, or move it with `override_background(after:/before:/all:)`. Either applies to one reactor **instance** and that instance's run only. |
| Class-level `background` called at runtime | `background` re-declares on the class, or raises if a different point is declared. Either way it changes every later run in the process. | Raises `Can not modify static configurations in the runtime`. Declarations stay fixed for the life of the process. (`queue` already raises; that ships with 011, FR-004 there.) |

## Clarifications already resolved (session 2026-10-11, during 011)

- Q: The class-level DSL `background` and a per-run `MyReactor.background(...)` override would share
  one method. How is the per-run override expressed? → A: Only on a new reactor instance, never on
  the class. `MyReactor.new.run_in_process!.run(params)` disables the hand-off, and
  `MyReactor.new.override_background(after: :confirm_order).run(params)` moves it. Any class-level
  `background` or `queue` call at runtime raises `Can not modify static configurations in the
  runtime`, for example `MyReactor.background(false).run`. Static declarations never change for the
  life of the process.
  - User's reasoning: changing a declaration at runtime would be a huge bug with unpredictable
    results, such as controller timeouts and unexpected responses. They rejected
    `with_background(...)` because it reads too much like `background`, which would confuse a
    developer or an LLM.
- Q: A fan-out `map` always resumes its owner in a worker. What does `run_in_process!` do with one?
  → A: It runs the map inline. Elements execute one after another in the calling process, so `run`
  returns the final result. `async_step` and `async_reactor` still dispatch because they are
  independent units.
  - Known ceiling: wall-clock time grows with the collection. Memory does not change, because the
    source is already loaded in both modes.
  - The user is concerned about huge maps. The upgrade path is "dispatch and wait"; see Assumptions.

## User Story - Skip or move the background hand-off for one run

A developer calls `MyReactor` from a Sidekiq job and from a Kafka consumer. Both are already
background processes, so handing off again only adds latency and hides the outcome. The Kafka
consumer must also know whether the run succeeded before it marks the message consumed.

The developer has two options, each acting on one instance and its run:

- `MyReactor.new.run_in_process!.run(params)` runs the whole reactor in the current process and
  returns the final result.
- `MyReactor.new.override_background(after: :confirm_order).run(params)` keeps only the steps up to
  `:confirm_order` in the current process.

The same reactor, called from a controller with plain `MyReactor.run(params)`, still hands off as its
class declares.

Trying the override on the class, as in `MyReactor.background(false).run`, raises `Can not modify
static configurations in the runtime`, just as a runtime `queue` call already does after 011. A runtime change to the class would silently alter every other
caller in the process: a controller could suddenly block until it times out, or get an unexpected
response.

**Why**: This is independent of queues and useful right away. Today a reactor that declares
`background` cannot return a synchronous outcome unless someone edits the class, and editing the
class breaks every other caller.

**Independent Test**:
- Run a reactor that declares `background after: :first` three ways: plain, with `run_in_process!`,
  and with `override_background(after: <later step>)`. For each, verify the hand-off point, the
  returned result type and the job count.
- Run them concurrently and verify none affects the others.
- Call `background` on the class at runtime and verify it raises and the class is unchanged.

**Acceptance Scenarios**:

1. **Given** `MyReactor` declares `background after: :first`, **When** the caller runs
   `MyReactor.new.run_in_process!.run(params)`, **Then** every step runs in the current process, no
   reactor hand-off job is enqueued, and the call returns the run's final `Success` or `Failure`.
2. **Given** the same reactor, **When** the caller runs
   `MyReactor.new.override_background(after: :confirm_order).run(params)`, **Then** steps up to and
   including `:confirm_order` run in the current process and the rest is handed off. The call returns
   the hand-off result, or a `Failure` if a step up to `:confirm_order` failed, so the caller can
   retry the event.
3. **Given** a reactor that declares no `background`, **When** the caller runs an instance with
   `override_background(before: :x)`, **Then** the run hands off before `:x` as if the class declared
   it.
4. **Given** an `override_background` naming an unknown step, an interrupt step, or more than one of
   `after:`/`before:`/`all:`, **When** it is called, **Then** it raises the same validation error the
   class-level declaration would, before any step runs and before anything is persisted.
5. **Given** two threads run the same reactor class at the same time, one instance with
   `run_in_process!` and one plain, **When** both finish, **Then** each behaved according to its own
   instance and the class's declaration is unchanged.
6. **Given** a reactor declaring `background all: true` whose steps retry with backoff, **When** an
   instance runs with `run_in_process!`, **Then** retries happen in the current process, exactly as
   for the same reactor without a `background` declaration, and no retry job is enqueued.
7. **Given** a `run_in_process!` run that composes a child declaring its own `background`, **When**
   the run reaches the child, **Then** the child also runs in the current process.
8. **Given** a loaded reactor class, **When** code outside its class definition calls
   `MyReactor.background(false)` or `MyReactor.background(after: :x)`, **Then** it raises `Can not
   modify static configurations in the runtime`, naming `run_in_process!` / `override_background` as
   the per-run alternative. The class's declarations, and every other run in the process, are
   unchanged. (Runtime `queue` calls already raise since 011.)
9. **Given** one instance, **When** both `run_in_process!` and `override_background(...)` are called
   on it, or either is called after the instance's run started, **Then** it raises before changing
   anything.
10. **Given** a reactor with a fan-out `map`, **When** an instance runs with `run_in_process!`,
    **Then** the map's elements execute one after another in the current process with no element or
    collector job, the steps after the map also run in the current process, and `run` returns the
    final `Success` or `Failure`.

## Edge Cases

- `async_step` and `async_reactor` units in a `run_in_process!` run are still dispatched, on their own
  effective queues. They are independent units, as they are today inside a worker. A `result(:name)`
  reader waits for them as it does today, and fire-and-forget units may still be running when `run`
  returns. Fan-out maps run inline instead, because the run cannot finish without them (FR-001).
- A `run_in_process!` run with a very large fan-out map runs its elements one after another, so the
  call takes as long as all elements combined. Callers with a processing deadline, such as a
  consumer poll interval, must allow for it or use `override_background(before: <map step>)`.
- A queue declaration never moves work out of the calling process. A `run_in_process!` run therefore
  never hops queues: every step runs in the caller, whatever its queue.
- A `run_in_process!` run combined with an interrupt pauses as it does today. Later resumes of that
  run keep the override, so the run never hands off through the reactor's `background`. An
  interrupt's own `resume: :background` still applies.
- An override set on an instance of a reactor whose definition is invalid: the definition error
  wins, as it does for a plain `run`.
- An anonymous class such as `Class.new(RubyReactor::Reactor) { background after: :x }`, used for
  test fixtures: the block is the class definition, so declarations inside it are allowed. Calls on
  the class after the block returns raise (FR-005).
- A run that never left the calling process, such as a `run_in_process!` run, rolls back entirely
  in the caller with no hops, as it does today. A later manual undo of such a run follows 011 FR-018.

## Functional Requirements (draft; formerly 011 FR-019–FR-024)

- **FR-001**: A reactor instance MUST offer `run_in_process!`. It disables the `background`
  declaration of the reactor, of every composed child and of every inline map element, for that
  instance's run only:
  - All of the run's own steps execute in the calling process, and `run` returns the final result.
  - The run behaves like the same reactor without a `background` declaration in every respect,
    including retries, which happen in the current process with no retry job enqueued.
  - Fan-out maps in the run MUST execute inline: elements run one after another in the calling
    process, with no element or collector job.
  - `async_step` and `async_reactor` units MUST still dispatch.
- **FR-002**: A reactor instance MUST offer `override_background(after: :x)`,
  `override_background(before: :x)` and `override_background(all: true)`. Each replaces the class's
  declaration, or adds one where the class has none, for that instance's run only.
  - It MUST be validated with the same rules and error messages as the class-level declaration,
    before any step runs and before anything is persisted.
  - `false` or no argument MUST raise, pointing to `run_in_process!`.
- **FR-003**: Both overrides MUST be set on the instance before its run starts, and both MUST return
  the instance, so that `MyReactor.new.run_in_process!.run(params)` chains. Calling both on one
  instance, or either after its run started, MUST raise without changing anything.
- **FR-004**: An override MUST affect only its instance's run. It MUST NOT modify the reactor class,
  and concurrent runs of the same class (other instances, threads or callers) MUST be unaffected.
- **FR-005**: Static configuration MUST be fixed for the life of the process. 011 (FR-004 there)
  already freezes `queue`; this feature extends the same freeze to `background`.
  - A class-level `background` call on a reactor class made outside that class's definition MUST
    raise `Can not modify static configurations in the runtime`.
  - The error MUST name `run_in_process!` / `override_background` as the per-run alternative, and the
    call MUST leave the class's declarations unchanged.
  - A class body evaluated again with the same declarations, as in a code reload or a spec reopening
    a fixture class, MUST keep working.
- **FR-006**: The override MUST be recorded with the run, so resumes of that run honor it.
- **FR-007**: Through the built-in RSpec surface, a spec MUST be able to run a reactor with
  `run_in_process!` / `override_background` and assert the outcome, without hand-rolled scaffolding.
- **FR-008**: `README.md`, the relevant `documentation/` files and `CHANGELOG.md` MUST describe the
  per-run override and the static-configuration rule.
- **FR-009**: `demo_app` MUST include a `run_in_process!` run of a reactor that declares
  `background`, as a reactor, rake task and spec, per Constitution Principle VI.
- **FR-010**: A run with no override MUST behave exactly as it does today.
- Changes this makes to 011 once both ship:
  - 011 FR-006 says a queue declaration never moves work out of the caller. Its list of what creates
    jobs gains `override_background`.
  - 011's "never left the calling process" edge case gains `run_in_process!` runs.

## Key Entities

- **Background override**: an instance-level, per-run replacement for the reactor's `background`
  declaration. It is either `run_in_process!` (no hand-off) or `override_background(...)` (one
  hand-off point), and it is recorded with the run.
- **Static configuration**: class-level declarations such as `background` and `queue`. They are set
  only while the class is defined and stay fixed for the life of the process.

## Success Criteria (draft; formerly 011 SC-005, SC-006, part of SC-007, SC-009)

- **SC-001**: 100% of `run_in_process!` runs, including runs with fan-out maps, return their final
  `Success` or `Failure` (or a pause) from the same `run` call. A run with no `async_step`/
  `async_reactor` enqueues zero jobs.
- **SC-002**: With 50 concurrent runs of one reactor class, half using `run_in_process!` instances and
  half plain, 100% behave according to their own instance.
- **SC-003**: A developer can run a reactor synchronously from a consumer by changing one call, and
  the documentation describes how.
- **SC-004**: 100% of class-level `background` calls made at runtime raise. No runtime call
  can change how any other run of the class hands off or which queue it uses.

## Assumptions

- `run_in_process!` covers the reactor's `background` hand-off and fan-out maps. An `interrupt ...
  resume: :background` keeps its own dispatch behavior, and so do the independent units
  (`async_step`, `async_reactor`).
- A per-run *queue* override on an instance is out of scope. The override only controls where the
  hand-off happens, not which queue it uses.
- Inline fan-out under `run_in_process!` is a `ponytail:` choice: elements run one after another, so
  its ceiling is wall-clock time on large collections. If a real caller hits it, the upgrade path is
  **dispatch and wait**:
  - Keep the parallel element jobs.
  - The caller holds the run lock and waits for the map to finish, then continues in process. The
    wait is bounded and uses a durable check followed by a signal, like `result(:name)` readers.
  - Meanwhile the collector's usual job to resume the owner hits the held lock and snoozes, then
    exits once the run has finished.
  - If the wait times out, the caller releases the lock and returns a dispatch result, and that
    queued resume job takes over.
  - No new recovery path is needed.

## Open items for planning

- Extending 011's runtime-call detection for `queue` to `background` (FR-005): reuse its mechanism.
- RSpec `test_reactor` support for the overrides (FR-007).
