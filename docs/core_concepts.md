# Core Concepts

Understanding RubyReactor's core concepts is essential for building reliable sequential business processes.

## Reactor

A Reactor is the main execution unit that orchestrates steps in a specific order.

```ruby
class OrderProcessingReactor < RubyReactor::Reactor
  # Reactor definition
end
```

**Key Characteristics:**
- **Sequential Execution**: Steps run one after another in dependency order
- **Error Handling**: Automatic rollback on failures
- **Compensation**: Undo operations for failed steps
- **Result Aggregation**: Collects results from all steps

## Steps

Steps are the individual units of work within a reactor. Each step has a name and implementation.

### Inline Step Definition

```ruby
step :validate_order do
  run do |order_id|
    # Step implementation
    order = Order.find(order_id)
    raise "Order not found" unless order
    Success({ order: order })
  end
end
```

### Step Classes

For complex steps with compensation and undo logic, or for better testability and reusability, you can define steps as separate classes that include the `RubyReactor::Step` module. This is the preferred approach for steps that require sophisticated error handling or have significant business logic.

```ruby
class ReserveInventoryStep
  include RubyReactor::Step

  def self.run(arguments, context)
    order = arguments[:order]
    # Business logic for inventory reservation
    reservation_id = InventoryService.reserve(order[:items])
    Success({
      reservation_id: reservation_id,
      reserved_items: order[:items].size
    })
  end

  def self.compensate(error, arguments, context)
    # Cleanup logic for failed reservations
    puts "Cleaning up inventory reservation due to: #{error.message}"
    # Release any partial reservations
    Success("Inventory reservation cleaned up")
  end

  def self.undo(result, arguments, context)
    # Rollback logic for successful reservations during reactor failure
    reservation_id = result[:reservation_id]
    InventoryService.release(reservation_id)
    Success("Inventory reservation released")
  end
end
```

To use a step class in a reactor, reference it by class:

```ruby
class OrderProcessingReactor < RubyReactor::Reactor
  step :reserve_inventory, ReserveInventoryStep do
    argument :order, result(:validate_order)
  end
end
```

**Benefits of Step Classes:**
- **Reusability**: Step classes can be shared across multiple reactors
- **Testability**: Easier to unit test individual step logic in isolation
- **Organization**: Complex business logic is better organized in dedicated classes
- **Maintainability**: Compensation and undo logic is clearly separated
- **Readability**: Reactor definitions remain focused on orchestration

**Step Class Methods:**
- **`run(arguments, context)`**: The main business logic. Returns `Success(result)` or `Failure(error)`
- **`compensate(error, arguments, context)`**: Cleanup for the current failing step. Called when the step fails
- **`undo(result, arguments, context)`**: Rollback for previously successful steps. Called during reactor failure rollback

**Step Components:**
- **Name**: Unique identifier (symbol)
- **Implementation**: The `run` block containing business logic
- **Dependencies**: Other steps that must complete first
- **Compensation**: Undo logic for rollback scenarios

## Context

Context holds the execution state throughout the reactor lifecycle.

```ruby
context = RubyReactor::Context.new(order_id: 123, customer_id: 456)
```

**Context Contents:**
- **Inputs**: Original parameters passed to `Reactor.run()`
- **Intermediate Results**: Outputs from completed steps
- **Completed Steps**: Set of successfully finished step names
- **Step Results**: Final outputs from each step
- **Execution Metadata**: Job IDs, timestamps, reactor class info

## Dependencies

Steps can depend on other steps, creating a directed acyclic graph (DAG) of execution.

```ruby
step :validate_order do
  run { validate_order_logic }
end

step :process_payment do
  argument :order, result(:validate_order)
  run do |args, _context|
    process_payment_for_order(args[:order])
  end
end

step :send_confirmation do
  argument :payment_result, result(:process_payment)
  run do |args, _context|
    payment_result = args[:payment_result]
    send_confirmation_email(payment_result[:order], payment_result[:payment_id])
  end
end
```

**Dependency Resolution:**
- Topological sorting ensures correct execution order
- Future feature: Parallel execution of independent steps (when available)
- Validation prevents circular dependencies

## Results

Every reactor execution returns a comprehensive result object.
<!-- 
# TODO

This is not true, update to use instance and what is stored
```ruby
result = OrderProcessingReactor.run(order_id: 123)

# Overall status
result.success?        # => true/false
result.failure?        # => true/false

# Step outputs
result.step_results    # => { validate_order: {...}, process_payment: {...} }
result.intermediate_results  # => Hash of all step outputs

# Execution tracking
result.completed_steps # => #<Set: {:validate_order, :process_payment}>
result.inputs          # => { order_id: 123 }

# Error information
result.error           # => Exception object if failed
``` -->

## Error Handling

RubyReactor provides sophisticated error handling with automatic compensation.

### Step Failures

When a step fails, execution stops and compensation begins:

```ruby
step :process_payment do
  run do
    # This might fail
    PaymentService.charge(amount, token)
  end

  compensate do |payment_id: nil, **|
    # Undo the payment if it was created
    PaymentService.refund(payment_id) if payment_id
  end
end
```

### Compensation Order

Compensation runs in reverse order of successful steps:

```mermaid
graph TD
  A[Step A succeeds] --> B[Step B succeeds]
  B --> C[Step C fails]
  C --> D[Compensate C]
  D --> E[Undo B]
  E --> F[Undo A]
```

### Error Types

- **StepExecutionError**: Business logic failures
- **DependencyError**: Missing required dependencies
- **ValidationError**: Input validation failures
- **CompensationError**: Compensation logic failures

## Execution Models

### Synchronous Execution

```ruby
result = Reactor.run(inputs)
# Blocks until completion
# Returns Result object immediately
```

**Characteristics:**
- Blocking execution in current thread
- Immediate results
- Simple error handling
- Limited scalability

### Asynchronous Execution

<!-- TODO: review this part -->

```ruby
async_result = Reactor.run(inputs)
# Returns immediately
# Check status later

case async_result.status
when :success
  result = async_result.result
when :failed
  error = async_result.error
end
```

**Characteristics:**
- Non-blocking execution
- Background processing with Sidekiq
- Retry capabilities
- Better scalability

## Step Arguments

Steps receive arguments through keyword arguments, with automatic dependency injection.

```ruby
step :validate_order do
  run do |order_id:, customer_id:|
    # Direct access to reactor inputs
    order = Order.find_by(id: order_id, customer_id: customer_id)
    Success({ order: order })
  end
end

step :process_payment do
  argument :order_data, result(:validate_order)

  run do |args, _context|
    # Access results from previous steps
    order = args[:order_data][:order]
    payment = PaymentService.charge(order.total, order.card_token)
    Success({ payment_id: payment.id })
  end
end
```

**Argument Resolution:**
1. **Step Results**: Outputs from completed dependent steps
2. **Reactor Inputs**: Original inputs passed to `run()`
3. **Intermediate Results**: Accumulated outputs from all steps

## Undo

Undo provides transactional rollback for previously successful steps when a later step fails.

### When Undo Runs

Unlike compensation which only runs for the failing step, undo is triggered during the **backwalk** phase when rolling back the entire reactor execution. When a step fails:

1. **Compensation** runs for the failing step itself
2. **Undo** runs for all previously successful steps in reverse order

### Basic Undo

```ruby
step :reserve_inventory do
  run do |items:|
    reservation_id = InventoryService.reserve(items)
    Success({ reservation_id: reservation_id })
  end

  undo do |reservation_result, arguments, context|
    # Undo receives the step's result, arguments, and full context
    reservation_id = reservation_result[:reservation_id]
    InventoryService.release(reservation_id)
    Success("Inventory reservation released")
  end
end
```

### Undo Context

Undo blocks receive three parameters:
- **Result**: The successful result from the step's `run` block
- **Arguments**: The resolved arguments passed to the step
- **Context**: The full execution context with all intermediate results

```ruby
step :complex_operation do
  run do |input:|
    # Complex operation that modifies external state
    record = create_record(input)
    notification = send_notification(record)
    Success({ record_id: record.id, notification_id: notification.id })
  end

  undo do |result, arguments, context|
    # Clean up in reverse order of creation
    notification_id = result[:notification_id]
    record_id = result[:record_id]

    delete_notification(notification_id) if notification_id
    delete_record(record_id) if record_id

    Success("Complex operation fully undone")
  end
end
```

### Undo vs Compensation

- **Compensation**: Handles cleanup for the currently failing step
- **Undo**: Handles rollback of all previously successful steps during reactor failure

Both mechanisms work together to ensure transactional semantics across complex business processes.

## Compensation

Compensation provides cleanup logic for steps that fail during execution. Unlike undo which handles rollback of successful steps, compensation is specific to the failing step itself.

### When Compensation Runs

Compensation runs immediately when a step fails, before the broader rollback process begins. It allows the failing step to clean up any partial state changes it may have made.

### Basic Compensation

```ruby
step :reserve_inventory do
  run do |items:|
    reservation_id = InventoryService.reserve(items)
    Success({ reservation_id: reservation_id })
  end

  compensate do |error, arguments, context|
    # Clean up partial reservations if the step failed
    # Note: This step didn't succeed, so we don't have a result to undo
    # Instead, we work with the error and arguments
    puts "Cleaning up after reservation failure: #{error.message}"
    # Any cleanup logic specific to this step's failure
  end
end
```

### Compensation Context

Compensation blocks receive three parameters:
- **Error**: The exception that caused the step to fail
- **Arguments**: The resolved arguments that were passed to the step
- **Context**: The full execution context

```ruby
step :process_payment do
  run do |order:, payment_method:|
    # Payment processing logic that might fail
    PaymentService.charge(order.total, payment_method)
  end

  compensate do |error, arguments, context|
    # Handle payment processing failure
    order = arguments[:order]
    payment_method = arguments[:payment_method]

    # Log the failure for audit purposes
    AuditService.log_payment_failure(order.id, error.message)

    # Send notification about payment failure
    NotificationService.send_payment_failed_email(order.customer_email, order.id)
  end
end
```

### Compensation vs Undo

- **Compensation**: Cleanup logic for the currently failing step only
- **Undo**: Rollback logic for previously successful steps during reactor failure

The distinction ensures that failing steps can handle their own cleanup while successful steps can be properly rolled back.

## Validation

Input validation ensures data integrity before execution.

### Built-in Validation

```ruby
class OrderReactor < RubyReactor::Reactor
  input :order_id do
    required(:order_id).filled(:integer, gt?: 0)
  end
end
```

### Custom Validators

```ruby
class OrderReactor < RubyReactor::Reactor
  input :order do
    required(:order).hash do
      required(:id).filled(:integer, gt?: 0)
      required(:total).filled(:decimal, gt?: 0)
      required(:items).filled(:array, min_size?: 1)
    end
  end
end
```

## Dependency Graph

RubyReactor builds a dependency graph to determine execution order.

### Graph Construction

```ruby
# Explicit dependencies
step :a do; end
step :b do; argument :a_result, result(:a); end
step :c do; argument :a_result, result(:a); end
step :d do; argument :b_result, result(:b); argument :c_result, result(:c); end

# Execution order: a → [b,c] → d
```

### Cycle Detection

```ruby
# This would raise DependencyError
step :a do; argument :b_result, result(:b); end
step :b do; argument :a_result, result(:a); end  # Circular dependency!
```

## Execution Flow

### Normal Execution

```mermaid
graph TD
    A[Reactor.run] --> B[Validate Inputs]
    B --> C[Build Dependency Graph]
    C --> D[Execute Steps in Order]
    D --> E{All Steps<br/>Complete?}
    E -->|No| F[Execute Next Step]
    F --> G{Step<br/>Success?}
    G -->|Yes| H[Store Result]
    H --> E
    G -->|No| I[Run Compensation]
    I --> J[Return Failure Result]
    E -->|Yes| K[Aggregate Results]
    K --> L[Return Success Result]
```

1. **Input Validation**: Validate reactor inputs
2. **Graph Building**: Construct dependency graph
3. **Step Execution**: Execute steps in dependency order
4. **Result Aggregation**: Collect all step outputs
5. **Return Result**: Return comprehensive result object

### Error Execution

```mermaid
graph TD
    A[Step Execution] --> B{Step<br/>Fails?}
    B -->|No| C[Continue to Next Step]
    B -->|Yes| D[Stop Execution]
    D --> E[Run Compensation<br/>for Failing Step]
    E --> F[Run Undo for<br/>Successful Steps<br/>in Reverse Order]
    F --> G[Aggregate Error Details]
    G --> H[Return Failure Result]
```

1. **Step Failure**: A step raises an exception
2. **Stop Execution**: Halt remaining steps
3. **Compensation**: Run compensation block for the failing step
4. **Undo**: Run undo blocks for all previously successful steps in reverse order
5. **Rollback**: Return failure result with error details

## Threading Model

### Synchronous
- Single-threaded execution
- Blocking operations halt the entire process
- Simple debugging and monitoring

### Asynchronous
- Multi-threaded execution via Sidekiq
- Non-blocking retry mechanisms
- Complex monitoring and debugging

## Best Practices

### Step Design

1. **Single Responsibility**: Each step should do one thing well
2. **Idempotency**: Design steps to be safely retryable when possible
3. **Error Handling**: Use appropriate exception types
4. **Resource Management**: Clean up resources in compensation blocks

### Dependency Management

1. **Minimize Dependencies**: Keep the dependency graph simple
2. **Clear Naming**: Use descriptive step names
3. **Logical Grouping**: Group related steps together

### Error Handling

1. **Specific Exceptions**: Use custom exception classes
2. **Compensation Logic**: Always provide compensation for failing steps
3. **Undo Logic**: Always provide undo for steps that modify external state
4. **Logging**: Log important events and errors
5. **Monitoring**: Track success/failure rates

### Performance

1. **Efficient Steps**: Keep individual steps fast
2. **Async for Slow Ops**: Use async for I/O bound operations
3. **Resource Limits**: Set appropriate timeouts and limits
4. **Caching**: Cache expensive operations when safe