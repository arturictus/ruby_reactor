# Data Model: Per-Reactor/Step Queues

**Feature**: [spec.md](spec.md) | **Research**: [research.md](research.md)

What this feature adds, where it lives, who writes it. Queue names are stored as Strings.

## 1. Declarations (class level, static)

| Holder | Field | Writer | Reader | Rules |
| --- | --- | --- | --- | --- |
| Reactor class | `@queue` | private `queue <name>` in the class body or `Class.new` block (R-01) | `declared_queue`: own, else the superclass's, else nil | Non-empty Symbol/String. Same value again: no-op. A different value: `ValidationError`. An explicit-receiver call: `StaticConfigurationError` |
| `RubyReactor::Step` subclass | `@queue` | private `queue <name>` | `declared_queue` (inherits) | Same as the reactor class |
| `StepBuilder` → `StepConfig` | `queue` | `queue <name>` inside a `step`/`async_step` block | `StepConfig#queue`: the block's, else `impl.declared_queue` | The block wins over the class (FR-002) |
| `ComposeBuilder`, `MapBuilder` | — | `queue` raises `ValidationError` ("declare it on the child reactor class") | — | Out of scope (spec Assumptions) |

`Queues.declares_any?(reactor_class)`: true when the reactor, any plain step, or recursively any
`compose`/`map` child has a declaration. Memoized per class. Used by manual undo (R-08).

## 2. Effective queue (computed, never stored on the class)

Resolution order (FR-005, R-02):

```text
of_context(ctx)  = ctx.reactor_class.declared_queue
                || of_context(ctx.parent_context)            # composed child, inline map element
                || ctx.private_data["inherited_queue"]       # async_reactor child, fan-out element
                || configuration.queue_name                  # read at call time

node_queue(step, ctx)     # queue of the job that runs this graph node
  step (plain)            → step.queue || of_context(ctx)
  compose                 → child.declared_queue || of_context(ctx)
  map (inline)            → element.declared_queue || of_context(ctx)
  map (fan-out), async_step, async_reactor, interrupt → of_context(ctx)

dispatch_queue(step, ctx) # queue of a dispatched unit's own jobs
  async_step              → step.queue || of_context(ctx)
  async_reactor           → child.declared_queue || of_context(ctx)
  map (fan-out) elements  → element.declared_queue || of_context(ctx)
```

`Queues.current(ctx)`: the queue of the job executing the tree. It is a transient attribute on the
root context (`current_queue`, not serialized), set from the job's queue argument by `Worker`,
`StepWorker` and `Map::ElementExecutor`. It is nil in the calling process, so no hops happen there
(FR-006).

## 3. Persisted records

### 3.1 Run dispatch record (new)

- **Key**: `reactor:<Class>:context:<id>:dispatch`, a Redis hash with TTL `context_ttl`.
- **Fields**:
  - `queue`: String. The queue the run was last dispatched to.
  - `since`: ISO-8601 time, or empty. Set while a dispatch is pending.

| Event | Write | By |
| --- | --- | --- |
| Any root `Worker` dispatch: hand-off, hop, retry requeue, snooze, resume, undo hand-off, sweeper, collector, map-rollback owner signal, `async_reactor` dispatch | `queue = target`, `since = now`, **then** enqueue | `Queues.enqueue_run` |
| Worker pickup, once the run is loaded, only if the job's queue equals `queue` | `since = ""` | `Worker#perform_locked` |
| Read | Target for non-owner re-dispatch; API `waiting_on` while `since` is set and the status is `running`/`rolling_back` | Sweeper, collector, API |

No record means the root reactor's effective queue (R-04). That is the global `queue_name` for a
reactor with no declaration, and for every run persisted before this feature.

### 3.2 Context blob (existing, extended)

| Field | Change |
| --- | --- |
| `private_data["inherited_queue"]` | New. Set at dispatch on an `async_reactor` child's context to `of_context(parent)`, and on a fan-out element's context from its job's `"queue"` (equal to the container's queue whenever the element reactor declares none) |
| `private_data["parked_primitives"]` | Unchanged shape. A hop parks through it. The lock's TTL was extended to `context_ttl` at park time (§5) |
| `execution_trace[]` entries | Gain `queue` when written inside a job (`append_execution_trace`) |
| `execution_trace[]` `:queue_hop` | New entry type: `{type: :queue_hop, at: <node path>, from:, to:, direction: :forward \| :rollback, timestamp:, background: true, queue: from}`. The node is under `at`, not `step`, so step lookups never match a hop |
| `rollback` | Unchanged keys. A queue hop records `trigger`, `step`, `compensated: true` and `failures` exactly as a 009 hand-off does |
| `status` | `rolling_back` is now also reached by a rollback hop, and by a manual undo hand-off of a run whose tree declares a queue |
| `current_step` | Pinned to the hop's target node (the resume cursor) |

### 3.3 Step Result Record (`async_step`, existing)

| Field | Change |
| --- | --- |
| `"queue"` | New. `dispatch_queue`. `StepSweeper` re-dispatches to it. The API and the `on_queue` matcher read it |

### 3.4 Map metadata (fan-out, existing)

| Record | New field | Use |
| --- | --- | --- |
| Map operation metadata | `"queue"` | Element jobs, element retries and parks, and `Map::Sweeper` re-dispatch |
| Map operation metadata | `"owner_queue"` | The collector job's queue, and `Map::Sweeper` collector retrigger |
| Map rollback metadata | `"queue"` | Element rollback jobs and their requeues |

## 4. Job payloads

New fields are **only present when the queue differs from `queue_name`** (R-03), so payloads with
no declarations are byte-for-byte what they are today.

| Job | Field | Meaning |
| --- | --- | --- |
| `Worker` | 4th positional `queue` | The queue this job was enqueued on. Becomes `current_queue` |
| `StepWorker` | `"queue"` | Same |
| `MapElementWorker` | `"queue"`, `"owner_queue"` | Its queue (also the element context's `inherited_queue`), the collector's queue |
| `MapElementRollbackWorker` | `"queue"` | Its queue |
| `MapCollectorWorker` | `"queue"` | Its queue (the owner's) |

## 5. Primitives and signals

| Entity | Change |
| --- | --- |
| `Lock#detach(lease: nil)` | With `lease`, also `lock_extend(key, owner, lease)`. A hop passes `context_ttl`. `reattach` restores the normal TTL and extender |
| `Error::QueueHop < Error::ExecutionParked` | New. Carries `queue` and `step`. Raised by `StepExecutor`, rescued by `Worker#perform_locked` |
| `Error::RollbackHandedOff` | Gains `queue:`. Exactly one of `map_id` and `queue` is set. `hand_off_rollback!` branches on it |
| `Error::StaticConfigurationError < Error::ValidationError` | New. Message `Can not modify static configurations in the runtime` |

## 6. State transitions

Forward hop (the run stays `running` throughout):

```text
running (job on A) ──node on B──▶ park + save + record{B, now} + enqueue(B) ──▶ running (waiting on B)
running (waiting on B) ──Worker on B picks up──▶ record.since cleared ──▶ running (job on B)
```

Rollback hop:

```text
running (job on A) ──step fails, compensate on A, undo entry on B──▶ rolling_back (waiting on B)
rolling_back (job on B) ──entries on B undone, next entry on A──▶ rolling_back (waiting on A)
rolling_back (job on A) ──stack empty──▶ failed   (or cancelled, for a manual undo)
```

Manual undo, when the tree declares a queue:

```text
paused | aborted | completed | failed ──Reactor#undo (lock, reload)──▶ rolling_back (waiting on node_queue(top))
```

## 7. Validation rules (definition time)

| Rule | When | Error |
| --- | --- | --- |
| Queue name present, a Symbol or String, not empty | `queue` call | `ValidationError` naming the class |
| A second, different value | `queue` call | `ValidationError` naming both values |
| Explicit-receiver `queue` | Any time | `StaticConfigurationError` |
| `queue` in a `compose`/`map` block | Block evaluation | `ValidationError` naming the child class |
| A hop-bearing unit inside a map element with a different queue | `validate_definition!` | `ValidationError` naming the reactor, the map, the unit and the reason (R-09.1) |
| A hop-bearing unit in a `with_ordered_lock` reactor's tree | `validate_definition!` | `ValidationError` (R-09.2) |
