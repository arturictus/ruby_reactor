# API Reference

Complete API reference for RubyReactor classes and methods.

## Reactor Class

### Class Methods

#### `async(async_flag = true)`

Enables full reactor async execution.

```ruby
class MyReactor < RubyReactor::Reactor
  async true  # Enable async execution
end
```

#### `async?`

Returns whether the reactor is configured for async execution.

```ruby
MyReactor.async?  # => true/false
```

#### `retry_defaults(options)`

Sets default retry configuration for all steps.

```ruby
retry_defaults(
  max_attempts: 3,
  backoff: :exponential,
  base_delay: 2.seconds
)
```

#### `run(inputs)`

Executes the reactor with given inputs.

```ruby
# Synchronous execution
result = MyReactor.run(order_id: 123)

# Asynchronous execution
async_result = MyReactor.run(order_id: 123)
```

### Instance Methods

#### `async?`

Returns whether this reactor instance is async.

```ruby
reactor = MyReactor.new
reactor.async?  # => true/false
```

## StepBuilder Class

### Methods

#### `run(&block)`

Defines the step implementation. The block must return a `RubyReactor::Success` or `RubyReactor::Failure` object.

```ruby
step :validate_order do
  run do |order_id:|
    # Step logic here
    order = Order.find(order_id)
    if order
      Success({ order: order })
    else
      Failure("Order not found")
    end
  end
end
```

#### `compensate(&block)`

Defines compensation logic for the step.

```ruby
step :process_payment do
  run do
    # Payment logic
  end

  compensate do |payment_id:|
    # Refund logic
    PaymentService.refund(payment_id)
  end
end
```

#### `depends_on(*step_names)`

Specifies step dependencies.

```ruby
step :process_payment do
  depends_on :validate_order, :check_inventory
  run { payment_logic }
end
```

#### `async(async_flag = true)`

Marks step as async (step-level async).

```ruby
step :send_email, async: true do
  run { email_logic }
end
```

#### `retry(options)`

Configures retry behavior for the step.

```ruby
step :call_api do
  retry max_attempts: 3, backoff: :exponential, base_delay: 1.second
  run { api_call }
end
```

#### `idempotent(idempotent_flag = true)`

Marks the step as idempotent.

```ruby
step :send_notification do
  idempotent true
  run { send_email }
end
```

## StepConfig Class

### Attributes

#### `name`

The step name (symbol).

```ruby
config.name  # => :validate_order
```

#### `async?`

Whether the step is async.

```ruby
config.async?  # => true/false
```

#### `retry_config`

Retry configuration hash.

```ruby
config.retry_config
# => { max_attempts: 3, backoff: :exponential, base_delay: 1.second, idempotent: false }
```

### Methods

#### `retryable?`

Returns whether the step can be retried.

```ruby
config.retryable?  # => true/false
```

#### `idempotent?`

Returns whether the step is idempotent.

```ruby
config.idempotent?  # => true/false
```

## Context Class

### Class Methods

#### `new(inputs)`

Creates a new execution context.

```ruby
context = RubyReactor::Context.new(order_id: 123, customer_id: 456)
```

#### `deserialize_from_retry(json_data)`

Deserializes context from JSON for retry resumption.

```ruby
context = Context.deserialize_from_retry(json_string)
```

### Instance Methods

#### `inputs`

Original inputs passed to reactor.

```ruby
context.inputs  # => { order_id: 123 }
```

#### `intermediate_results`

Results from completed steps.

```ruby
context.intermediate_results
# => { validate_order: { order: #<Order> }, process_payment: { payment_id: "pay_123" } }
```

#### `completed_steps`

Set of completed step names.

```ruby
context.completed_steps  # => #<Set: {:validate_order, :process_payment}>
```

#### `step_results`

Final results from all steps.

```ruby
context.step_results  # => { validate_order: {...}, process_payment: {...} }
```

#### `retry_context`

Retry execution state.

```ruby
context.retry_context  # => #<RetryContext>
```

#### `execution_metadata`

Execution metadata (job_id, timestamps, etc.).

```ruby
context.execution_metadata
# => { job_id: "job_123", started_at: 2025-10-16 10:00:00 UTC, reactor_class: OrderReactor }
```

#### `serialize_for_retry`

Serializes context for retry storage.

```ruby
json_data = context.serialize_for_retry
```

## RetryContext Class

### Attributes

#### `step_attempts`

Hash of attempt counts per step.

```ruby
context.step_attempts  # => { validate_order: 1, process_payment: 2 }
```

#### `current_step`

Currently executing step name.

```ruby
context.current_step  # => :process_payment
```

#### `failure_reason`

Last failure exception.

```ruby
context.failure_reason  # => #<PaymentError>
```

#### `next_retry_at`

Next retry scheduled time.

```ruby
context.next_retry_at  # => 2025-10-16 10:05:00 UTC
```

### Methods

#### `retry_attempt_for_step(step_name)`

Gets attempt count for a step.

```ruby
context.retry_attempt_for_step(:process_payment)  # => 2
```

#### `increment_attempt_for_step(step_name)`

Increments attempt count for a step.

```ruby
context.increment_attempt_for_step(:process_payment)
```

#### `can_retry_step?(step_config)`

Checks if a step can be retried.

```ruby
context.can_retry_step?(step_config)  # => true/false
```

## Result Class

### Methods

#### `success?`

Returns whether execution succeeded.

```ruby
result.success?  # => true/false
```

#### `failure?`

Returns whether execution failed.

```ruby
result.failure?  # => true/false
```

#### `error`

Failure exception (if any).

```ruby
result.error  # => #<StepExecutionError>
```

#### `step_results`

Results from each step.

```ruby
result.step_results[:validate_order]  # => { order: #<Order> }
```

#### `intermediate_results`

All intermediate step outputs.

```ruby
result.intermediate_results  # => Hash of all step results
```

#### `completed_steps`

Set of completed step names.

```ruby
result.completed_steps  # => #<Set: {:validate_order, :process_payment}>
```

#### `inputs`

Original inputs.

```ruby
result.inputs  # => { order_id: 123 }
```

## AsyncResult Class

### Methods

#### `status`

Current execution status.

```ruby
async_result.status
# => :pending, :running, :success, :failed
```

#### `result`

Final result (when status is :success).

```ruby
async_result.result  # => #<Result>
```

#### `error`

Failure exception (when status is :failed).

```ruby
async_result.error  # => #<StepExecutionError>
```

#### `job_id`

Sidekiq job ID.

```ruby
async_result.job_id  # => "job_12345"
```

#### `completed?`

Whether execution is complete.

```ruby
async_result.completed?  # => true/false
```

#### `successful?`

Whether execution succeeded.

```ruby
async_result.successful?  # => true/false
```

#### `failed?`

Whether execution failed.

```ruby
async_result.failed?  # => true/false
```

## Executor Class

### Methods

#### `execute(context)`

Executes a reactor with given context.

```ruby
executor = RubyReactor::Executor.new(reactor_class, inputs)
result = executor.execute(context)
```

#### `resume_execution(context)`

Resumes execution from a failed step.

```ruby
executor.resume_execution(context)
```

#### `execute_step_with_retry(step_config, context)`

Executes a step with retry logic.

```ruby
result = executor.execute_step_with_retry(step_config, context)
```

#### `calculate_backoff_delay(retry_config, attempt)`

Calculates backoff delay for retry attempts.

```ruby
delay = executor.calculate_backoff_delay(retry_config, attempt_number)
```

## RubyReactor::RetryQueuedResult Class

Represents a result that has been queued for retry.

```ruby
# Returned when a step fails but will be retried
result = executor.execute_step_with_retry(step_config, context)
if result.is_a?(RubyReactor::RetryQueuedResult)
  # Job has been queued for retry
end
```

## Configuration

### RubyReactor Configuration

RubyReactor uses a singleton configuration class for global settings.

```ruby
# Configure using the main module
RubyReactor.configure do |config|
  config.sidekiq_queue = :default
  config.sidekiq_retry_count = 3
  config.logger = Logger.new('log/ruby_reactor.log')
end

# Access the configuration instance
config = RubyReactor.configuration
puts config.sidekiq_queue        # => :default
puts config.sidekiq_retry_count  # => 3
puts config.logger               # => #<Logger:0x...>
```

### Configuration Methods

#### `RubyReactor.configure(&block)`

Configures the RubyReactor settings.

```ruby
RubyReactor.configure do |config|
  config.sidekiq_queue = :my_queue
  config.sidekiq_retry_count = 3
end
```

#### `RubyReactor.configuration`

Returns the configuration instance.

```ruby
config = RubyReactor.configuration
config.sidekiq_queue = :high_priority
```

#### `sidekiq_queue`

Gets or sets the Sidekiq queue name. Default: `:default`

#### `sidekiq_retry_count`

Gets or sets the Sidekiq retry count. Default: `3`

#### `logger`

Gets or sets the logger instance. Default: `Logger.new($stderr)`

### Environment Variables

```bash
# Redis connection
REDIS_URL=redis://localhost:6379/0

# Redis namespace
REDIS_NAMESPACE=ruby_reactor

# Sidekiq settings
SIDEKIQ_CONCURRENCY=25
SIDEKIQ_TIMEOUT=300
```

## Error Classes

### Base Errors

- `RubyReactor::Error` - Base error class
- `RubyReactor::StepExecutionError` - Step execution failure
- `RubyReactor::DependencyError` - Dependency resolution failure
- `RubyReactor::ValidationError` - Input validation failure
- `RubyReactor::CompensationError` - Compensation execution failure
- `RubyReactor::ContextTooLargeError` - Context size exceeds limits
- `RubyReactor::DeserializationError` - Context deserialization failure
- `RubyReactor::SchemaVersionError` - Schema version mismatch

### Step-Specific Errors

- `RubyReactor::InputValidationError` - Step input validation failure
- `RubyReactor::StepFailureError` - Generic step failure
- `RubyReactor::UndoError` - Compensation failure

## Constants

### Backoff Strategies

```ruby
RubyReactor::BackoffStrategies::EXPONENTIAL = :exponential
RubyReactor::BackoffStrategies::LINEAR = :linear
RubyReactor::BackoffStrategies::FIXED = :fixed
```

### Default Values

```ruby
RubyReactor::DEFAULT_MAX_ATTEMPTS = 1
RubyReactor::DEFAULT_BACKOFF = :exponential
RubyReactor::DEFAULT_BASE_DELAY = 1.second
RubyReactor::DEFAULT_IDEMPOTENT = false
```

## Utility Classes

### ContextSerializer

Handles complex object serialization for context persistence.

```ruby
# Serialize complex objects
serialized = ContextSerializer.serialize_complex_object(object)

# Deserialize complex objects
deserialized = ContextSerializer.deserialize_complex_object(data)
```

### DependencyGraph

Manages step dependencies and execution order.

```ruby
graph = RubyReactor::DependencyGraph.new(step_configs)
execution_order = graph.topological_sort
ready_steps = graph.get_ready_steps(completed_steps)
```

## Type Definitions

### RetryConfig

```ruby
RetryConfig = {
  max_attempts: Integer,    # Maximum retry attempts
  backoff: Symbol,          # :exponential, :linear, :fixed
  base_delay: Numeric,      # Base delay in seconds
  idempotent: Boolean       # Whether step is idempotent
}
```

### StepResult

```ruby
StepResult = {
  success: Boolean,         # Whether step succeeded
  result: Hash,            # Step output data
  error: Exception,        # Failure exception (if any)
  attempts: Integer,       # Number of attempts made
  duration: Float          # Execution duration in seconds
}
```

### ExecutionMetadata

```ruby
ExecutionMetadata = {
  job_id: String,          # Sidekiq job ID
  started_at: Time,        # Execution start time
  completed_at: Time,      # Execution completion time
  reactor_class: Class,    # Reactor class
  async: Boolean,          # Whether execution is async
  retry_count: Integer     # Total retry attempts
}
```

## Performance Metrics

### Execution Metrics

- `execution_duration` - Total execution time
- `step_count` - Number of steps executed
- `retry_count` - Total retry attempts
- `compensation_count` - Number of compensations executed

### Resource Metrics

- `context_size` - Serialized context size in bytes
- `memory_usage` - Peak memory usage
- `redis_operations` - Number of Redis operations
- `database_queries` - Number of database queries

## Testing Helpers

### TestReactor

Helper class for testing reactors.

```ruby
test_reactor = RubyReactor::TestReactor.new(MyReactor)

# Mock step implementations
test_reactor.mock_step(:validate_order) { { order: mock_order } }
test_reactor.mock_step(:process_payment) { raise "Payment failed" }

# Execute with mocks
result = test_reactor.run(order_id: 123)
```

### AsyncTestHelper

Helper for testing async reactors.

```ruby
helper = RubyReactor::AsyncTestHelper.new

# Drain async jobs for testing
helper.drain_jobs

# Check job status
job_status = helper.job_status(job_id)
```

## Integration Points

### Sidekiq Integration

RubyReactor integrates with Sidekiq for background processing:

```ruby
# Worker class
class RubyReactorWorker
  include Sidekiq::Worker

  def perform(serialized_context)
    context = Context.deserialize_from_retry(serialized_context)
    executor = Executor.new(context.reactor_class, context.inputs)
    executor.resume_execution(context)
  end
end
```

### Rails Integration

RubyReactor works seamlessly with Rails applications:

```ruby
# config/initializers/ruby_reactor.rb
RubyReactor.configure do |config|
  config.sidekiq_queue = :default
  config.sidekiq_retry_count = 3
  config.logger = Rails.logger  # Use Rails logger
end

# In controllers
def create_order
  async_result = OrderProcessingReactor.run(order_params)

  render json: { job_id: async_result.job_id }, status: :accepted
end

def order_status
  async_result = RubyReactor::AsyncResult.find(params[:job_id])

  render json: {
    status: async_result.status,
    result: async_result.result&.step_results
  }
end
```

### Monitoring Integration

RubyReactor provides hooks for monitoring integration:

```ruby
# Custom monitoring
RubyReactor::Monitoring.subscribe('step_completed') do |event|
  Metrics.increment("reactor.step_completed", tags: { step: event.step_name })
end

RubyReactor::Monitoring.subscribe('execution_failed') do |event|
  Alerts.notify("Reactor execution failed: #{event.error.message}")
end
```</content>
<parameter name="filePath">/Users/artur.panach/dev/republic/ruby_reactor/docs/api_reference.md