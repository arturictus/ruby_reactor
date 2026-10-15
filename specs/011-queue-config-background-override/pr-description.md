# PR: Per-Reactor/Step Queues (011)

## Summary

`queue :name` on a reactor class, a step class, or inside a `step` / `async_step` block picks the
queue that unit's jobs use; an undeclared unit uses its container's queue, then the global
`queue_name`. "Option 1" from the feature input — every declaration honoured — is built from two
protocols the gem already had:

- **Placement**: one resolver (`RubyReactor::Queues`); every router method takes `queue:`, and each
  job carries its own queue as an argument; every dispatch of a run's Worker goes through
  `Queues.enqueue_run`, which records `{queue, since}` next to the run (sweepers and other
  non-owners re-dispatch there; the dashboard shows "waiting on `<queue>` since T"). Runs with no
  declarations enqueue exactly what they did before.
- **Forward hop = a park on another queue** (`Error::QueueHop`): every executor on the stack parks
  its holds (a reactor lock is leased for `context_ttl` across the wait), the root saves under the
  run's lock, and the Worker enqueues the continuation on the target queue.
- **Rollback hop = 009's rollback hand-off aimed at a queue** (`RollbackHandedOff.new(queue:)`); a
  manual `undo` of a run whose reactor tree declares a queue is handed to a worker the same way.
- **Consistency first**: a hop inside a map element and a hop under `with_ordered_lock` are rejected
  at `validate_definition!` instead of running weaker.
- **Static freeze**: `queue` is a private class method, so `MyReactor.queue(:x)` raises
  `Can not modify static configurations in the runtime`.

## Spec revisions (research R-17)

- FR-015 and the map-element edge case: a unit inside a map element on another queue is rejected at
  definition time (a waiting fan-out element is re-dispatched from the start; an inline element
  re-runs with its map).
- A run without a recorded queue goes to its reactor's effective queue.
- A `with_ordered_lock` reactor whose tree could hop is rejected.
- Context table ("Today" — Sidekiq step/map jobs ignored `queue_name`) and Assumptions (the
  `background` hand-off still releases reactor holds; hops keep them).

## Migration notes (R-13)

1. Custom `config.async_router` implementations receive `queue:` (and `snooze_count:` on
   `perform_in`) once a queue is declared somewhere.
2. On Sidekiq, `async_step` and map jobs now use `config.queue_name` (they used Sidekiq's own
   `default`), and the reactor worker reads it at enqueue time. Nothing moves with the default
   `queue_name`.
3. A reactor `with_lock` held by a run waiting on a hop is held for up to `context_ttl`.
4. `Reactor.undo(id)` of a run whose reactor tree declares a queue returns before the undo runs
   (`rolling_back` until a worker ends it `cancelled`).

## Tests

Baseline (T004), before any change (`7357a035`), on its own Redis DB:
**1611 examples, 0 failures** (`slow` excluded).

After (T074): see below.

New specs: `spec/ruby_reactor/queues/` (declaration, resolution, enqueue_run, Worker, US1 reactor
queue, backend placement, compose hops, crash windows forward and rollback, rollback hops, manual
undo hand-off, maps, child re-dispatches, step queues, definition rejections, waiting runs), router
queues, the dispatch record, the lock lease, the RSpec additions, the API, and the GUI
(`ReactorDetail`, `stepBackground`). `rubocop`: no offenses.

Existing specs touched: `sweeper_spec` and `step_sweeper_spec` gained recorded-queue examples; the
two mock-based Worker specs gained `allow` stubs for the new collaborators (no expectation changed).

## Demo (Constitution VI)

`QueueDemoReactor` (`:demo_orders`) composes `StripeDepositReactor` (`:demo_stripe`) and dispatches
`QueueEmailStep` (`:demo_emails`); `demo:queues` (in `demo:all`) runs a success, a failure with
rollback hops, and a handed-off manual undo; `demo_app/spec/reactors/queue_demo_reactor_spec.rb`
uses only the shipped matchers; `demo-sidekiq` consumes the demo queues.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
