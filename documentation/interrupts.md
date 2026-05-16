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

    run do |args, _ctx|
      Success(ReportProcessor.call(args[:webhook_payload]))
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

## Common Use Cases

### Human Approvals

```ruby
interrupt :wait_for_approval do
  wait_for :submit_request
  correlation_id { |ctx| "approval-#{ctx.input(:request_id)}" }
end

step :process_decision do
  argument :decision, result(:wait_for_approval)
  run do |args, _ctx|
    if args[:decision][:approved]
      Success("Approved")
    else
      Failure("Rejected")
    end
  end
end
```

### Webhooks

Use `correlation_id` to map an external resource ID (like a Payment Intent ID) back to the reactor waiting for confirmation.

### Scheduled Follow-ups

Using `timeout` with `strategy: :active` to wake up a reactor after a delay if no external event occurs (e.g., expiring a reservation).
