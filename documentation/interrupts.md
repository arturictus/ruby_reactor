# Interrupts (Pause & Resume)

RubyReactor introduces the `interrupt` mechanism to support long-running processes that require external input, such as user approvals, webhooks, or asynchronous job completions. Unlike standard steps that execute immediately, an `interrupt` pauses the reactor execution and persists its state, waiting for a signal to resume.

## DSL Usage

Use the `interrupt` keyword to define a pause point in your reactor.

```ruby
class ReportReactor < RubyReactor::Reactor
  step :request_report do
    run do |_args, _ctx|
      response = HTTP.post("https://api.example.com/reports")
      Success(response.fetch(:id))
    end
  end

  interrupt :wait_for_report do
    # Declare dependency: execution must trigger this interrupt only after :request_report succeeds
    wait_for :request_report

    # Optional: deterministic correlation ID for looking up this execution later
    correlation_id do |context|
      "report-#{context.result(:request_report)}"
    end

    # Optional: timeout in seconds
    # Strategies:
    # - :lazy (default) - checked only when resume is attempted
    # - :active - schedules a background job to wake up the reactor and fail it
    timeout 1800, strategy: :active

    # Optional: validate incoming payload immediately using dry-validation
    validate do
      required(:status).filled(:string)
      required(:url).filled(:string)
    end

    # Optional: limit validation attempts (default: 1)
    # If exhausted, the reactor is cancelled and compensated.
    # Use :infinity for unlimited attempts.
    max_attempts 3
  end

  step :process_report do
    # The result of the interrupt step is the payload provided when resuming
    argument :webhook_payload, result(:wait_for_report)

    run do |inputs, _ctx|
      Success(ReportProcessor.call(inputs.webhook_payload))
    end
  end
end
```

### Options

*   **`wait_for`**: declare dependencies similar to `step`.
*   **`correlation_id`**: A block that returns a unique string to identify this execution. This allows you to resume the reactor using a business key (e.g., order ID) instead of the internal execution UUID.
*   **`timeout`**: Set a time limit for the interrupt.
*   **`validate`**: A `dry-validation` schema block to validate the payload provided when resuming.
*   **`max_attempts`**: Limit the number of times `continue` can be called with an invalid payload before the reactor is automatically cancelled and compensated. Defaults to 1. Set to `:infinity` for unlimited retries.

> An `interrupt` step refuses `with_lock`/`with_semaphore`/`with_rate_limit`/`with_period`/`with_ordered_lock` — it raises at class-definition time, since the step's body is split across the pause and a hold would span the gap. Declare coordination on the reactor instead (see [Locks, Semaphores, Rate Limits, Periods & Ordered Locks](locks_and_semaphores.md)).

## Runtime Behavior

When a reactor encounters an `interrupt`:

1.  It executes any dependencies.
2.  It persists the full `Context` (results of previous steps) to the configured storage (e.g., Redis).
3.  It returns an `InterruptResult` and halts execution.

```ruby
execution = ReportReactor.run(company_id: 1)

if execution.paused?
  execution.execution_id  # => "uuid-123"
  execution.correlation_id # => "report-..." (if defined)
  execution.status        # => :paused
end
```

## Resuming Execution

You can resume a paused reactor using its UUID or the defined `correlation_id`.

Only a reactor **paused at an interrupt** takes a resume. A resume that arrives while the reactor is
executing or rolling back (compensating/undoing), or after it finished, was cancelled or was
aborted, raises `RubyReactor::Error::ValidationError` ("Cannot resume: the reactor is running, not
paused at an interrupt") and changes nothing. An accepted resume marks the run `running` before it
executes, so a second resume that arrives meanwhile fails the same way. A resume that cannot take
the reactor's `with_lock` or `with_semaphore` raises its `AcquisitionError`, as `Reactor.run` does,
and leaves the run paused: retry it once the holder is done.

### By UUID

```ruby
ReportReactor.continue(
  id: "uuid-123",
  payload: { status: "completed", url: "..." },
  step_name: :wait_for_report
)
```

### By Correlation ID

```ruby
ReportReactor.continue_by_correlation_id(
  correlation_id: "report-999",
  payload: { status: "completed", url: "..." },
  step_name: :wait_for_report
)
```

### Background Resume

By default, `continue` runs the remaining steps **inline in the calling
process** (your webhook controller, admin action, etc.). Declare
`resume: :background` to hand the remainder to a worker instead:

```ruby
interrupt :wait_for_report, resume: :background do
  wait_for :request_report
  validate_payload do
    required(:status).filled(:string)
  end
end
```

With `resume: :background`, `continue`:

1.  Validates the payload **synchronously in the calling process** — an
    invalid payload is rejected immediately (attempt counting and
    `max_attempts` compensation work exactly as with inline resume), and
    nothing is enqueued.
2.  On a valid payload, stores it, persists the context, enqueues the resume
    via the configured `async_router`, and returns an `DispatchResult`.

The caller never executes post-interrupt steps, so a webhook can acknowledge
instantly even when heavy work follows the interrupt.

### Resuming Method Styles

There are two ways to invoke continuation:

1.  **Strict / Fire-and-Forget (Class Method)**:
    *   `Reactor.continue(...)`
    *   If payload is invalid, it **automatically compensates (undo)** and cancels the reactor.
    *   Best for webhooks where you can't ask the sender to fix the payload.

2.  **Flexible (Instance Method)**:
    *   First find the reactor: `reactor = ReportReactor.find("uuid-123")`
    *   Then call: `result = reactor.continue(payload: ..., step_name: :wait_for_report)`
    *   If payload is invalid, it returns a failure result but **does not** cancel execution.
    *   Allows you to handle the error (e.g., show a form error to a user) and try again.

## Interrupts inside composed reactors

An `interrupt` inside a `compose`d child pauses the **top-level** run, at any depth. The paused
result carries the top-level run's `execution_id`, and the child interrupt's `correlation_id`.

```ruby
class ManagerApprovalReactor < RubyReactor::Reactor
  input :order_id

  step :reserve_stock, ReserveStockStep do
    argument :order_id, input(:order_id)
  end

  interrupt :wait_for_manager do
    wait_for :reserve_stock
    correlation_id { |context| "approval-#{context.inputs[:order_id]}" }
    validate_payload { required(:approved).filled(:bool) }
  end

  step :confirm_reservation, ConfirmReservationStep do
    argument :decision, result(:wait_for_manager)
  end
end

class OrderReactor < RubyReactor::Reactor
  input :order_id

  step :charge_card, ChargeCardStep do
    argument :order_id, input(:order_id)
  end

  compose :approval, ManagerApprovalReactor do
    argument :order_id, input(:order_id)
  end

  step :ship, ShipStep do
    wait_for :approval
  end
end

execution = OrderReactor.run(order_id: 1)
execution.paused?        # => true
execution.execution_id   # => the OrderReactor run's id
OrderReactor.find(execution.execution_id).ready_interrupt_steps
# => [[:approval, :wait_for_manager]]
```

**Resume it by its step path**: the compose step names from the top-level reactor down, then the
interrupt, as an Array (strings work too, so a JSON body can carry it). A bare name always means a
step of the top-level reactor itself.

```ruby
OrderReactor.continue(id: execution.execution_id, payload: { approved: true },
                      step_name: [:approval, :wait_for_manager])

# or by the child interrupt's correlation id, on the top-level class
OrderReactor.continue_by_correlation_id(correlation_id: "approval-1", payload: { approved: true },
                                        step_name: [:approval, :wait_for_manager])
```

The child then runs its remaining steps, and the top-level run carries on from the compose step.
`ready_interrupt_steps` lists everything the paused run can be resumed at: Symbols for the
top-level reactor's own interrupts, paths for nested ones. Two composes deep, the path has three
names (`[:order, :approval, :wait_for_manager]`).

Everything else works as for a top-level interrupt, driven by the child interrupt's declaration:

* **Validation and `max_attempts`**: once the attempts run out, the whole run is rolled back from
  the top level and marked `failed`.
* **`resume: :background`**: the remainder runs in the top-level run's worker.
* **Refusals**: a resume of a run that is not paused, or was cancelled, is refused.
* **Lock contention**: a resume that cannot take the top-level reactor's `with_lock` or
  `with_semaphore` raises its `AcquisitionError` and leaves the run paused, ready to retry. The
  child's own `with_lock`/`with_semaphore` is different: it is taken inside the compose step. A
  resume that finds it contended, inline or with `resume: :background`, fails the compose step,
  and the whole run rolls back and ends `failed`, losing the payload. When an approval must
  survive contention, declare the lock on the top-level reactor instead.
* **Wrong names**: a `continue` that names anything but a pending interrupt raises
  `RubyReactor::Error::ValidationError` listing the pending ones, and changes nothing.

`OrderReactor.undo(id)` on the paused run rolls back what the child completed (`reserve_stock`),
then the top-level steps (`charge_card`), and cancels the run.

The child is never a run of its own: `ManagerApprovalReactor.continue(...)` on the child's id, or
`continue_by_correlation_id` on the child class, raises `ValidationError` ("is a composed child;
continue its root run").

> An `interrupt` inside a `map` element, directly or through a compose there, is not supported:
> nothing would resume one element. The element fails with "interrupt :name is not supported
> inside a map element", and rolls back like any failed element.

In specs, the matchers and test subject take the same path:

```ruby
subject = test_reactor(OrderReactor, { order_id: 1 })
expect(subject).to be_paused_at([:approval, :wait_for_manager])
subject.resume(step: [:approval, :wait_for_manager], payload: { approved: true })
expect(subject).to be_success
```

`be_paused_at(:a, :b)` still means two top-level interrupts; a nested one is always one Array.

## Cancellation & Undo

You can cancel a paused reactor if the operation is no longer needed.

```ruby
# Undo: Runs defined undo/compensate blocks for completed steps in reverse order,
# then marks the execution as cancelled.
ReportReactor.undo("uuid-123")

# Cancel: Stops execution immediately and marks the reactor as cancelled with the provided reason.
# The context is preserved for inspection, but resumption is disabled.
ReportReactor.cancel(id: "uuid-123", reason: "User cancelled")
```

`undo` works the same way on an **aborted** execution. A run in the caller's process that is cut
short by an interruption (a signal such as `Interrupt`, `SystemExit`, `NoMemoryError`, or an
enclosing `Timeout.timeout`) runs no rollback code: the exception reaches the caller unchanged, and
the run is stored with status `aborted` and the steps not yet undone still outstanding. That
includes an interruption inside a composed child or an inline `map` element (`undo` also rolls
back the steps the child or those elements completed) and one that hits a rollback already
running (`undo` finishes it). Any other
exception, a `StandardError` or not (`NotImplementedError`, a custom `Exception` subclass), is the
step's own failure and rolls back like one. No worker or sweeper resumes
it. `ReportReactor.undo(id)` rolls it back and marks it cancelled. A run inside a worker is not
marked: its job is redelivered and resumes from its last checkpoint.

## Common Use Cases

### Human Approvals

```ruby
interrupt :wait_for_approval do
  wait_for :submit_request
  correlation_id { |ctx| "approval-#{ctx.input(:request_id)}" }
end

step :process_decision do
  argument :decision, result(:wait_for_approval)
  run do |inputs, _ctx|
    fail!("Rejected") unless inputs.decision[:approved]

    Success("Approved")
  end
end
```

### Webhooks

Use `correlation_id` to map an external resource ID (like a Payment Intent ID) back to the reactor waiting for confirmation.

### Scheduled Follow-ups

Using `timeout` with `strategy: :active` to wake up a reactor after a delay if no external event occurs (e.g., expiring a reservation).
