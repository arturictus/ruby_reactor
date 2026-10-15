# Contract: Public Surface

**Feature**: [../spec.md](../spec.md) | **Research**: [../research.md](../research.md)

Everything a gem user, a custom router, the dashboard or a spec can observe.

## 1. DSL

```ruby
RubyReactor.configure { |c| c.queue_name = :default }   # unchanged: the global default (FR-003)

class StripeBankDeposit < RubyReactor::Reactor
  queue :stripe                       # this reactor's units default to :stripe
  step :charge, ChargeStep
end

class Email < RubyReactor::Step
  queue :emails                       # this step class's default
  def run = Success()
end

class MyReactor < RubyReactor::Reactor
  queue :my_specific_queue
  background after: :first

  step :first, FirstStep
  step :second, SecondStep
  compose :bank_deposit, StripeBankDeposit      # hops to :stripe and back
  step :third, ThirdStep do
    wait_for :bank_deposit
  end
  async_step :email, Email                      # dispatched to :emails
  async_step :priority_email, Email do
    queue :priority_emails                      # the block wins over Email's :emails
  end
end
```

| Call | Result |
| --- | --- |
| `queue :x` in a class body or a `Class.new(...) { }` block | Declares it |
| `queue :x` again with the same value | No-op |
| `queue :y` after `queue :x` on the same class | `RubyReactor::Error::ValidationError`: "MyReactor already declares `queue :x` and cannot also declare `queue :y`" |
| `queue nil`, `queue ""`, `queue 1` | `ValidationError` naming the class |
| `MyReactor.queue(:x)`, `MyReactor.queue`, `Email.queue(:x)`, or on an anonymous class after its block | `RubyReactor::Error::StaticConfigurationError`, message `Can not modify static configurations in the runtime`. Nothing changes |
| `queue :x` inside a `compose`/`map` block | `ValidationError`: declare `queue` on the child reactor class |
| `MyReactor.declared_queue`, `Email.declared_queue` | `"my_specific_queue"`, `"emails"`, or nil. Inherited from the superclass |
| Subclass of `MyReactor` with no `queue` | `declared_queue == "my_specific_queue"` |

A queue declaration never moves work out of the calling process (FR-006). Only `background`,
`async_step`, `async_reactor` and fan-out `map` create jobs.

## 2. Definition-time rejections (`validate_definition!`, FR-019)

Raised before the first run, or when the app calls `MyReactor.validate_definition!` at boot or in
CI:

- `ValidationError`: "map :deposits in BulkReactor: element reactor DepositReactor runs step
  :notify on queue :emails, but a map element cannot hop queues (an element waiting in a queue is
  re-dispatched from the start). Declare :emails on DepositReactor, or remove the step's queue."
  This covers fan-out and inline maps, and nested `compose`/`map` inside the element.
- `ValidationError`: "OrderedReactor declares with_ordered_lock, and step :charge would hop to
  queue :stripe. A run waiting in a queue cannot keep its ordered-lock position alive. Keep every
  unit on OrderedReactor's queue."

## 3. Runtime behavior

| Situation | Behavior |
| --- | --- |
| `Reactor.run` reaches `background` | One job, on the queue of the first unit the worker runs (R-06). `all: true` uses the reactor's effective queue |
| Worker reaches a unit on another queue | Hop: the run is saved, one job is enqueued on that queue, and this job stops. The result the caller saw is unchanged (a `DispatchResult` from the hand-off) |
| Consecutive units on the same queue | Share one job |
| Failure after hops | The failing step's `compensate` runs where it failed. Each undo runs on its unit's queue, hopping in rollback order. The run ends `failed` |
| `Reactor.undo(id)` / `#undo` / `undo(failure:)` on a run whose reactor tree declares a queue | Returns after the hand-off (`Reactor.undo` returns `nil`; `#undo` returns `:handed_off`). The run is `rolling_back` until a worker ends it `cancelled`, or `failed` with the given failure. Another `undo`, `cancel` or `continue` meanwhile raises `ValidationError` (unchanged) |
| Same, with no queue declared anywhere in the tree | Today's in-caller undo |
| A run waiting on a queue no worker consumes | Stays `running`/`rolling_back` indefinitely. Never failed for queue lag |

## 4. Router contract (custom `async_router` implementations)

Every router method gains a `queue:` keyword argument (default `nil`, meaning
`RubyReactor.configuration.queue_name`, resolved when the job is enqueued). The gem passes it
**only when the target queue differs from `queue_name`**. A custom router keeps working until a
reactor or step declares a queue.

```ruby
perform_async(context_id, reactor_class_name = nil, intermediate_results: {}, queue: nil)
perform_in(delay, context_id, reactor_class_name = nil, intermediate_results: {}, queue: nil, snooze_count: 0)
perform_step_async(root_context_id:, reactor_class_name:, step_context_id:, step_name:, queue: nil)
perform_step_in(delay, ..., contention_attempts: 0, queue: nil)
perform_map_element_async(..., queue: nil, owner_queue: nil)
perform_map_element_in(delay, ..., queue: nil, owner_queue: nil)
perform_map_element_rollback_async(**args, queue: nil)
perform_map_element_rollback_in(delay, **args, queue: nil)
perform_map_collection_async(..., queue: nil)
```

The built-in routers enqueue on that queue (Sidekiq `set(queue:)`, ActiveJob `set(queue:)`), and
add it to the job's arguments so the job knows its own queue. `snooze_count` is the root Worker's
snooze counter, which the snooze path keeps across the queue.

## 5. API (`/ruby_reactor` dashboard JSON)

| Endpoint | Field | Value |
| --- | --- | --- |
| Reactor detail | `waiting_on` | `{ "queue": "stripe", "since": "2026-10-15T10:00:00Z" }` while a dispatch is pending and the status is `running`/`rolling_back`. Otherwise `null` |
| Reactor detail | `execution_trace[].queue` | The queue the entry was written on (absent for calling-process entries) |
| Reactor detail | `execution_trace[]` with `type: "queue_hop"` | `at` (the node path, e.g. `bank_deposit.two`), `from`, `to`, `direction` (`forward`/`rollback`) |
| Reactor detail | async-step and async-reactor references | `queue` |

The GUI shows a "Waiting on `stripe` since 10:00:00" line on the run, and the queue for each step.

## 6. Logs (key=value)

```text
event=ruby_reactor.queue.hop reactor="MyReactor" execution_id="…" step="bank_deposit" from="my_specific_queue" to="stripe" direction="forward"
event=ruby_reactor.queue.hop reactor="MyReactor" execution_id="…" step="bank_deposit" from="my_specific_queue" to="stripe" direction="rollback"
event=ruby_reactor.queue.waiting reactor="MyReactor" execution_id="…" queue="stripe" since="…" source="sweeper"
```

The existing `ruby_reactor.background.handoff`, `ruby_reactor.async_step.dispatched` and
`async_reactor` dispatch lines gain `queue=`.

## 7. Middleware events

No new event. Each hop fires `:before_async_enqueue` on the root context before the save, so
OpenTelemetry context crosses the hop. The job that hops emits `:snooze_reactor`, as a park does.
The hopping step fires `:start_step` only in the job that runs it.

## 8. RSpec additions (`lib/ruby_reactor/rspec/`)

```ruby
expect(subject).to have_run_step(:third).on_queue(:my_specific_queue)
expect(subject).to have_run_step(:email).on_queue(:emails)              # async_step: from its record
expect(subject).to have_undone_step(:second).on_queue(:my_specific_queue)
expect(subject).to have_hopped_queues(:stripe, :my_specific_queue)      # ordered, forward hops
expect(subject).to have_hopped_queues(:stripe, :my_specific_queue).during_rollback
pending_async_jobs.map(&:queue)                                          # => ["my_specific_queue"]
subject.undo(process_jobs: false)                                        # Reactor.undo, then drain unless false
```

`on_queue` composes with the existing chains (`have_run_step(:x).after(:y).on_queue(:q)`).
