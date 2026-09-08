# Getting Started with RubyReactor

This guide will help you get started with RubyReactor, from installation to your first reactor.

## Installation

Add RubyReactor to your Gemfile:

```ruby
gem 'ruby_reactor'
```

Or install directly:

```bash
gem install ruby_reactor
```

## Your First Reactor

Let's create a simple order processing reactor:

```ruby
require 'ruby_reactor'

class OrderProcessingReactor < RubyReactor::Reactor
  step :validate_order do
    validate_args do
      required(:order_id).filled(:string)
    end

    run do |order_id|
      # Validate the order exists and is in correct state
      order = Order.find(order_id)
      raise "Order not found" unless order
      raise "Order already processed" if order.processed?

      Success({ order: order })
    end
  end

  step :process_payment do
    run do |order:, **|
      # Process payment for the order
      payment_result = PaymentService.charge(order.total, order.customer.card_token)
      raise "Payment failed" unless payment_result.success?

      Success({ payment_id: payment_result.id })
    end
  end

  step :update_inventory do
    run do |order:, **|
      # Update inventory for each item
      order.items.each do |item|
        InventoryService.decrement(item.product_id, item.quantity)
      end

      Success({ inventory_updated: true })
    end
  end

  step :send_confirmation do
    run do |order:, payment_id:, **|
      # Send confirmation email
      email_result = EmailService.send_confirmation(
        order.customer.email,
        order_id: order.id,
        payment_id: payment_id
      )

      Success({ confirmation_sent: email_result.success? })
    end
  end
end
```

## Executing a Reactor

### Synchronous Execution

```ruby
# Run the reactor synchronously
result = OrderProcessingReactor.run(order_id: 123)

if result.success?
  puts "Order processed successfully!"
  puts "Results: #{result.step_results}"
else
  puts "Order processing failed: #{result.error}"
end
```

### Asynchronous Execution

For async execution, you need Sidekiq configured. Mark the reactor as async:

```ruby
class OrderProcessingReactor < RubyReactor::Reactor
  async true  # Enable full reactor async

  # ... steps defined above
end

# Run asynchronously
async_result = OrderProcessingReactor.run(order_id: 123)
# Returns immediately with DispatchResult
# Check status later with async_result.status
```

## Understanding Results

RubyReactor returns detailed execution results:

```ruby
result = OrderProcessingReactor.run(order_id: 123)

# Check overall success
result.success?  # => true/false

# Access step results
result.step_results[:validate_order]  # => { order: #<Order> }
result.step_results[:process_payment] # => { payment_id: "pay_123" }

# Access intermediate results
result.intermediate_results  # => Hash of all step outputs

# Check completed steps
result.completed_steps  # => Set of completed step names

# Error information (if failed)
result.error  # => Exception that caused failure
```

## Step Dependencies

Steps can depend on each other using the `argument` method with `result()`:

```ruby
class ComplexReactor < RubyReactor::Reactor
  step :validate_order do
    run { validate_order_logic }
  end

  step :check_inventory do
    argument :order, result(:validate_order)

    run do |args, _context|
      check_inventory_for_order(args[:order])
    end
  end

  step :process_payment do
    argument :order, result(:check_inventory)

    run do |args, _context|
      process_payment_for_order(args[:order])
    end
  end
end
```

## Error Handling and Compensation

RubyReactor automatically handles errors and provides compensation:

```ruby
class OrderProcessingReactor < RubyReactor::Reactor
  step :validate_order do
    run { validate_order_logic }
  end

  step :process_payment do
    run { process_payment_logic }

    undo do |payment_id:, **|
      # Undo the payment if something fails later
      PaymentService.refund(payment_id)
    end
  end

  step :update_inventory do
    run { update_inventory_logic }

    compensate do |order:, **|
      # Restore inventory if something fails later
      order.items.each do |item|
        InventoryService.increment(item.product_id, item.quantity)
      end
    end
  end
end
```

If `update_inventory` fails, RubyReactor will:
1. Run the `update_inventory` compensate block
2. Run the `process_payment` undo block
3. Return a failure result

## Configuration

### Sidekiq Setup (for Async)

Add to your Sidekiq configuration:

```ruby
# config/sidekiq.rb
require 'ruby_reactor/worker'

# Configure RubyReactor
RubyReactor.configure do |config|
  config.sidekiq_queue = :default
  config.sidekiq_retry_count = 3
  config.logger = Logger.new('log/ruby_reactor.log')
end
```


## Next Steps

- Learn about [async reactors](async_reactors.md)
- Configure [retry policies](retry_configuration.md)
- See [examples](examples/) for more patterns
- Check the [API reference](api_reference.md) for detailed documentation