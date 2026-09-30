# Contract: Public API Surface

What users of the gem see change. Internal classes are listed only where a custom setup (router,
worker registration, dashboards) touches them.

## Map DSL

```ruby
map :charge_orders, ChargeOrderReactor do
  source result(:orders)
  argument :order, element(:charge_orders)

  fan_out batch_size: 200   # batch_size optional; 50 when omitted
  atomic               # default; `atomic false` returns per-element outcomes
  collect { |results| ... }
end
```

| Declaration | Behavior | Errors / warnings |
| --- | --- | --- |
| `atomic` / `atomic true` | Default. Any element failure fails the map, no new element starts, and every completed element is rolled back. | — |
| `atomic false` | The map completes with every element's outcome (a `ResultEnumerator` of `Success` / `Failure`). Failed elements roll themselves back; succeeded ones are kept. | — |
| `fail_fast(x)` | Same as `atomic(x)`. | One line on stderr per call site: `[RubyReactor] DEPRECATION: <file:line> <Reactor> map :<name> declares fail_fast. Use atomic (same meaning). Removal no earlier than the next MAJOR.` |
| `fail_fast` and `atomic` on one map | — | `RubyReactor::Error::ValidationError` at class definition: "map :<name> declares both fail_fast and atomic; declare only atomic". |
| `fan_out` (no `batch_size`) | No throw enqueues more than 50 element jobs; the next throw fires when the previous throw's last element finishes. | — |
| `fan_out batch_size: n` | As today; `n` must be a positive Integer. | `ValidationError` as today. |
| `batch_size n` on an inline map | No effect, as today. | — |

## Rollback behavior (observable)

| Situation | Before | After |
| --- | --- | --- |
| A fan-out map fails (atomic), or a later step fails, or `Reactor.undo` reaches a completed fan-out map | Every completed element is undone serially, in one process, with all element states loaded at once. | One background job per started element; only completed elements undo anything, the others report `not_needed`. No throw enqueues more than `batch_size`. The run is `rolling_back` until every element has reported, then the steps before the map are undone and the run ends `failed` (or `cancelled` for `undo`). |
| An inline map is rolled back | In process, all element states loaded at once. | In process, element states read 100 at a time, highest index first. |
| The final `Failure` | Carries `rollback_failures` with `map_step` / `element_index`. | Identical shape and content. The oracle is the same run with an inline map. |
| A worker dies mid-element-rollback | Not applicable (inline). | The element resumes after its last recorded undo. The undo that was cut off may run again, so undos must stay idempotent, as the docs already require. |

## Statuses

| Status | New? | Terminal? | Meaning |
| --- | --- | --- | --- |
| `rolling_back` | **new** | no | A rollback handed off at a fan-out map and is waiting for element rollback jobs. |

Dashboards and code that filter status strings see this one new value.

## `Reactor.undo(id)` / `Reactor#undo` / `Reactor.cancel`

| Case | Behavior |
| --- | --- |
| No fan-out map on the undo path | As today: undone in the caller's process, then `cancel(reason: "Undo triggered")`. |
| A completed fan-out map on the undo path | The steps after the map are undone in the caller's process. Element rollbacks are dispatched, the run becomes `rolling_back`, and the call returns. A worker finishes the rollback and applies `cancelled`. |
| The run's `async:` lock is held (a live run or rollback) | Raises `RubyReactor::Lock::AcquisitionError` after waiting up to 5 s. The caller retries. |
| The run is already `rolling_back` | Raises `RubyReactor::Error::ValidationError`: "rollback already in progress" (FR-027). |
| `Reactor.cancel(id:, reason:)` on a `rolling_back` run | Raises `RubyReactor::Error::ValidationError`: "rollback in progress; cannot cancel" (FR-027). Cancel on any other status behaves as today. |

## Composition

A `compose`d child (at any depth) whose steps include a `fan_out` map now works:

- the top-level run is resumed when the map settles, and finishes;
- rollback travels through the top-level run.

Nothing to declare.

## Background workers and routers

Both shipped routers gain two methods, and each adapter gains one worker class:

| Adapter | Router methods | Worker class |
| --- | --- | --- |
| Sidekiq | `perform_map_element_rollback_async(**args)`, `perform_map_element_rollback_in(delay, **args)` | `RubyReactor::Adapters::Sidekiq::MapElementRollbackWorker` |
| ActiveJob | `perform_map_element_rollback_async(**args)`, `perform_map_element_rollback_in(delay, **args)` | `RubyReactor::Adapters::ActiveJob::MapElementRollbackWorker` |

`perform_map_element_rollback_in` is the requeue a job uses when the element's lock is contended
(R-07).

Args (JSON-safe):

- `map_id`, `position`, `element_context_id`, `reactor_class_info`;
- `parent_reactor_class_name`, `step_name`, `batch_size`;
- `owner_context_id`, `owner_reactor_class_name`;
- `attempt`: 0 on dispatch, incremented on each contended-lock requeue.

The worker runs on the same queue as `MapElementWorker`.

`MapCollectorWorker` keeps its class and arguments. A collector job enqueued before the upgrade is
handled by the new body: it signals the owner instead of resuming the parent.

## Dashboard API

`GET /api/reactors/:id`: a hydrated map reference whose map has rollback records gains:

```json
{ "rollback": { "total": 1000, "settled": 350, "outstanding": 650, "failed": 2 } }
```

`outstanding = total - settled`. The records outlive the run by the durability TTL, so the field is
present after the rollback finishes too; clients decide from the run's status.

GUI:

- `rolling_back` appears in amber with an undo icon everywhere statuses are shown or filtered: the
  status badge, the "running" status group, and the live and per-class filters.
- The step inspector shows "Rolling back 350/1000 (650 outstanding, 2 failed)" **only while the
  run is `rolling_back`**.

## Structured logs

key=value, one line each, through `RubyReactor.configuration.logger`:

```text
event=ruby_reactor.map.rollback.started   reactor=<owner class> context_id=<owner id> map_step=<step> total=<n> batch_size=<b>
event=ruby_reactor.map.rollback.element   reactor=<owner class> context_id=<owner id> map_step=<step> index=<i> outcome=<outcome> failures=<count>
event=ruby_reactor.map.rollback.completed reactor=<owner class> context_id=<owner id> map_step=<step> total=<n> failed=<count>
```

## RSpec test surface

| Addition | Use |
| --- | --- |
| `be_rolling_back` matcher | `expect(subject).to be_rolling_back`, for a run handed off at a fan-out map and not drained yet. |
| `PendingJob#worker_class` on the ActiveJob helper | Alias of `job_class`, so `pending_async_jobs.first.worker_class` works on both backends for step-wise draining. |

`drain_async_jobs` drains `MapElementRollbackWorker` like any other adapter worker. There is no API
change.
