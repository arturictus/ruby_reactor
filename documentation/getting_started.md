# Getting Started with RubyReactor

This guide walks you through installation, configuration, and your first reactor.

## Installation

Add RubyReactor to your Gemfile:

```ruby
gem 'ruby_reactor'
```

Or install directly:

```bash
gem install ruby_reactor
```

## Configuration

RubyReactor uses Redis for state persistence and Sidekiq for async execution. Configure both before running any reactors:

```ruby
RubyReactor.configure do |config|
  # Redis configuration for state persistence
  config.storage.adapter = :redis
  config.storage.redis_url = ENV.fetch("REDIS_URL", "redis://localhost:6379/0")
  config.storage.redis_options = { timeout: 1 }

  # Sidekiq configuration for async execution
  config.sidekiq_queue = :default
  config.sidekiq_retry_count = 3

  # Logger
  config.logger = Logger.new($stdout)
end
```

## Your First Reactor

Reactors are subclasses of `RubyReactor::Reactor`. Declare `input`s, wire up `step`s (class-based or inline), and optionally a `returns` step. The example below uses **class steps** for business logic and keeps `send_confirmation` inline as a simple one-liner.

```ruby
require 'ruby_reactor'

class ValidateOrderStep
  include RubyReactor::Step

  def self.run(arguments, _context)
    order = Order.find_by(id: arguments[:order_id])
    return Failure("Order not found") unless order
    return Failure("Order already processed") if order.processed?

    Success(order: order)
  end
end

class ProcessPaymentStep
  include RubyReactor::Step

  def self.run(arguments, _context)
    order = arguments[:order]
    payment = PaymentService.charge(order.total, order.customer.card_token)
    payment.success? ? Success(payment_id: payment.id) : Failure("Payment failed")
  end
end

class UpdateInventoryStep
  include RubyReactor::Step

  def self.run(arguments, _context)
    arguments[:order].items.each do |item|
      InventoryService.decrement(item.product_id, item.quantity)
    end
    Success(inventory_updated: true)
  end
end

class OrderProcessingReactor < RubyReactor::Reactor
  input :order_id do
    required(:order_id).filled(:integer, gt?: 0)
  end

  step :validate_order, ValidateOrderStep do
    argument :order_id, input(:order_id)
  end

  step :process_payment, ProcessPaymentStep do
    argument :order, result(:validate_order, :order)
  end

  step :update_inventory, UpdateInventoryStep do
    argument :order, result(:validate_order, :order)
  end

  # Inline block — fine for trivial steps
  step :send_confirmation do
    argument :order, result(:validate_order, :order)
    argument :payment_id, result(:process_payment, :payment_id)

    run do |args, _context|
      EmailService.send_confirmation(args[:order].customer.email, order: args[:order])
      Success(confirmation_sent: true)
    end
  end

  returns :send_confirmation
end
```

Class steps are the recommended default because they improve **testability** (test `run`/`compensate`/`undo` without the full reactor), **composability** (reuse steps across reactors), and **readability** (reactor files stay orchestration-only as workflows grow). See [Core Concepts — Step Classes](core_concepts.md#step-classes-preferred) for compensation, undo, and the full API.

### Run blocks always receive `(arguments, context)`

Every step's `run` block receives two positional arguments: the resolved arguments hash and the execution context. Use `argument :name, source` to declare which value goes into `args[:name]`.

## Executing a Reactor

### Synchronous Execution

```ruby
result = OrderProcessingReactor.run(order_id: 123)

if result.success?
  puts "Order processed: #{result.value}"
else
  puts "Order processing failed: #{result.error}"
end
```

`Reactor.run` returns one of:

- `RubyReactor::Success` — `result.success?` is `true`, `result.value` holds the step output for `returns` (or the full `intermediate_results` hash if no `returns` is set).
- `RubyReactor::Failure` — `result.failure?` is `true`. Useful readers: `result.error`, `result.step_name`, `result.exception_class`, `result.backtrace`, `result.step_arguments`.
- `RubyReactor::AsyncResult` — returned when the reactor (or a step) is async. Holds `job_id`, `execution_id`, and any `intermediate_results` available at handoff.
- `RubyReactor::InterruptResult` — returned when an `interrupt` step pauses execution. Use `result.execution_id` and `result.correlation_id` to resume later.

### Asynchronous Execution

For async execution, configure Sidekiq and either mark the reactor `async true` or mark individual steps async:

```ruby
class OrderProcessingReactor < RubyReactor::Reactor
  async true  # Entire reactor runs in a Sidekiq worker

  # ... steps defined above
end

async_result = OrderProcessingReactor.run(order_id: 123)
async_result.execution_id # => UUID for looking up state later
```

To inspect a running execution, reload it from storage:

```ruby
reactor = OrderProcessingReactor.find(async_result.execution_id)
reactor.context.status      # => "running" | "completed" | "failed" | "paused"
reactor.result              # Success / Failure / InterruptResult
```

See [Async Reactors](async_reactors.md) for the full async model.

## Inspecting the Context

Step outputs are stored on the context, not the result object. After a sync execution you can reach them via the reactor instance:

```ruby
reactor = OrderProcessingReactor.new
reactor.run(order_id: 123)

reactor.context.intermediate_results[:validate_order]   # => { order: <Order> }
reactor.context.intermediate_results[:process_payment]  # => { payment_id: "pay_123" }
reactor.context.status                                  # => "completed"
reactor.execution_trace                                 # => [{ type: :run, step: :validate_order, ... }, ...]
```

For black-box assertions in tests, use the `test_reactor` helper described in [Testing with RSpec](testing.md).

## Step Dependencies

Steps depend on each other through `argument :name, result(:other_step)`. The dependency graph topologically sorts steps; circular dependencies raise `RubyReactor::Error::DependencyError`:

```ruby
class ValidateOrderStep
  include RubyReactor::Step

  def self.run(arguments, _context)
    Success(order: validate_order_logic(arguments))
  end
end

class CheckInventoryStep
  include RubyReactor::Step

  def self.run(arguments, _context)
    check_inventory_for_order(arguments[:order])
  end
end

class ProcessPaymentStep
  include RubyReactor::Step

  def self.run(arguments, _context)
    process_payment_for_order(arguments[:order])
  end
end

class ComplexReactor < RubyReactor::Reactor
  step :validate_order, ValidateOrderStep do
    argument :order_id, input(:order_id)
  end

  step :check_inventory, CheckInventoryStep do
    argument :order, result(:validate_order, :order)
  end

  step :process_payment, ProcessPaymentStep do
    argument :order, result(:check_inventory, :order)
  end
end
```

You can also declare order without data flow using `wait_for :step_name`.

## Error Handling and Compensation

When a step fails (returns `Failure(...)` or raises), the reactor:

1. Runs the **`compensate`** block of the failing step (signature: `|error, arguments, context|`).
2. Walks back through previously successful steps and runs each one's **`undo`** block in reverse order (signature: `|result, arguments, context|`).
3. Returns a `Failure`.

```ruby
class ProcessPaymentStep
  include RubyReactor::Step

  def self.run(arguments, _context)
    PaymentService.charge(arguments[:order])
  end

  def self.undo(result, _arguments, _context)
    # Runs if a later step fails
    PaymentService.refund(result[:payment_id])
    Success()
  end
end

class UpdateInventoryStep
  include RubyReactor::Step

  def self.run(arguments, _context)
    InventoryService.decrement_all(arguments[:order].items)
  end

  def self.compensate(_error, arguments, _context)
    # Runs only if THIS step fails
    arguments[:order].items.each { |i| InventoryService.increment(i.product_id, i.quantity) }
    Success()
  end
end

class OrderProcessingReactor < RubyReactor::Reactor
  step :process_payment, ProcessPaymentStep do
    argument :order, result(:validate_order, :order)
  end

  step :update_inventory, UpdateInventoryStep do
    argument :order, result(:validate_order, :order)
  end
end
```

If `update_inventory` fails: its `compensate` runs, then `process_payment`'s `undo` runs.

See [Core Concepts](core_concepts.md#compensation) for the full compensation/undo model.

## Next Steps

- [Core Concepts](core_concepts.md) — Reactors, class-based steps, Context, Results
- [Async Reactors](async_reactors.md) — Full and step-level async execution
- [Retry Configuration](retry_configuration.md) — Backoff strategies and retry policies
- [Interrupts](interrupts.md) — Pause/resume workflows
- [Composition](composition.md) — Build complex flows from smaller reactors
- [Data Pipelines](data_pipelines.md) — Map over collections in parallel
- [Testing with RSpec](testing.md) — `test_reactor`, mocks, matchers
- [Examples](examples/) — End-to-end workflows
