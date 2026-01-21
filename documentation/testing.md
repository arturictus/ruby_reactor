# Testing with RSpec

RubyReactor provides a comprehensive testing framework designed to make testing reactors intuitive and powerful. The testing utilities include a `TestSubject` class for reactor execution and introspection, along with custom RSpec matchers for expressive assertions.

## Setup

Add the RubyReactor RSpec configuration to your `spec_helper.rb` or `rails_helper.rb`:

```ruby
require 'ruby_reactor/rspec'

RSpec.configure do |config|
  RubyReactor::RSpec.configure(config)
end
```

This will give you access to the `test_reactor` helper method and all custom matchers.

## Basic Usage

### The `test_reactor` Helper

The primary interface for testing reactors is the `test_reactor` helper, which returns a `TestSubject` instance:

```ruby
RSpec.describe MyReactor do
  it "processes successfully" do
    subject = test_reactor(MyReactor, email: "test@example.com")
    
    expect(subject).to be_success
  end
end
```

### TestSubject Configuration

The `test_reactor` helper accepts the following options:

| Option | Type | Description |
|--------|------|-------------|
| `inputs` | Hash | The inputs to pass to the reactor |
| `context` | Hash | Optional context data for the execution |
| `async` | Boolean | Force async (`true`) or sync (`false`) execution |
| `process_jobs` | Boolean | Whether to automatically process Sidekiq jobs (default: `true`) |

```ruby
# Force synchronous execution
subject = test_reactor(MyReactor, { user_id: 1 }, async: false)

# With additional context
subject = test_reactor(MyReactor, { user_id: 1 }, context: { tenant_id: 42 })
```

---

## Execution Control

### Running the Reactor

The `TestSubject` automatically runs the reactor when you access introspection methods. You can also run it explicitly:

```ruby
subject = test_reactor(MyReactor, params)
subject.run  # Explicit execution

# Chaining is supported
subject.run_async(false).run
```

### Async Mode Control

Control whether the reactor runs asynchronously:

```ruby
# Force synchronous execution (useful for step-by-step debugging)
subject = test_reactor(MyReactor, params, async: false)

# Or use the fluent API
subject = test_reactor(MyReactor, params).run_async(false)
```

### Sidekiq Job Processing

By default, `TestSubject` automatically processes Sidekiq jobs in fake mode. This ensures that async steps complete during the test:

```ruby
# Jobs are processed automatically
subject = test_reactor(AsyncReactor, params)
expect(subject).to be_success  # All async steps completed

# Disable automatic job processing
subject = test_reactor(AsyncReactor, params, process_jobs: false)
```

---

## Introspection

### Accessing Results

Once executed, you can inspect the reactor's result:

```ruby
subject = test_reactor(MyReactor, params)

# Check overall status
subject.success?  # => true/false
subject.failure?  # => true/false

# Get the final result object
subject.result  # => Success or Failure

# Get any error that occurred
subject.error  # => error message or nil
```

### Step Results

Access the result of individual steps:

```ruby
subject = test_reactor(OrderReactor, order_id: 123)

# Get a specific step's result
user = subject.step_result(:validate_user)
order = subject.step_result(:fetch_order)
```

### Reactor Instance

Access the underlying reactor instance for advanced introspection:

```ruby
subject = test_reactor(MyReactor, params)

# Access the reactor instance
subject.reactor_instance

# Access context data
subject.reactor_instance.context.execution_trace
subject.reactor_instance.context.intermediate_results
```

---

## Step Mocking

### Basic Step Mocking

Use `mock_step` to intercept and replace step implementations:

```ruby
subject = test_reactor(PaymentReactor, order_id: 123)
  .mock_step(:charge_card) do |args, context|
    # Custom implementation
    Success({ transaction_id: "test-123" })
  end

expect(subject).to be_success
expect(subject.step_result(:charge_card)).to eq({ transaction_id: "test-123" })
```

### Wrapping Original Implementations

The mock block receives a third parameter that allows calling the original implementation:

```ruby
subject = test_reactor(MyReactor, params)
  .mock_step(:some_step) do |args, context, original|
    # Modify args before calling original
    modified_args = args.merge(extra: "value")
    result = original.call(modified_args, context)
    
    # Post-process the result
    result
  end
```

### Simulating Failures

#### Using `failing_at`

The `failing_at` method provides a simple way to simulate step failures:

```ruby
subject = test_reactor(OrderReactor, params)
  .failing_at(:process_payment)

expect(subject).to be_failure
```

#### Raising Exceptions in Mocks

For more control, raise exceptions within mock blocks:

```ruby
subject = test_reactor(PaymentReactor, params)
  .mock_step(:charge_card) do |args, context|
    raise PaymentDeclinedError, "Card was declined"
  end

expect(subject).to be_failure
expect(subject.error).to include("Card was declined")
```

---

## Nested Reactor Testing

### Testing Composed Reactors

When testing reactors that use `compose`, you can mock steps within the composed reactor:

```ruby
# Parent reactor composes ChildReactor at :process_child step
subject = test_reactor(ParentReactor, params)
  .composed(:process_child)
  .mock_step(:inner_step) do |args, context|
    Success("mocked inner result")
  end

expect(subject).to be_success
```

### Traversing Composed Results

After execution, traverse into composed reactor results:

```ruby
subject = test_reactor(ParentReactor, params)
subject.run

# Get the composed reactor's TestSubject
child_subject = subject.composed(:process_child)
expect(child_subject.step_result(:inner_step)).to eq("expected value")
```

### Testing Map Steps

For reactors using `map`, you can access individual element results:

```ruby
subject = test_reactor(BatchProcessor, items: [1, 2, 3])
subject.run

# Access all map element subjects
elements = subject.map_elements(:process_items)
expect(elements.length).to eq(3)

# Access a specific element by index
first_element = subject.map_element(:process_items, index: 0)
expect(first_element).to be_success

# Mock within map elements
subject = test_reactor(BatchProcessor, items: [1, 2, 3])
  .map(:process_items)
  .mock_step(:transform) do |args, context|
    Success(args[:item] * 2)
  end
```

---

## Custom RSpec Matchers

RubyReactor provides expressive matchers for common assertions:

### Success and Failure Matchers

```ruby
# Check if reactor succeeded
expect(subject).to be_success

# Check if reactor failed
expect(subject).to be_failure
```

The `be_success` matcher provides detailed failure messages when a reactor fails:

```ruby
# Example failure output:
# Error: PaymentDeclinedError
# Card was declined
# Step: :charge_card
# File: /app/reactors/payment_reactor.rb:45
#
#     def charge_card
# -->   PaymentGateway.charge(amount, token)
#     end
#
# Backtrace:
# - /app/reactors/payment_reactor.rb:45
# - /app/services/payment_gateway.rb:12
```

### Step Execution Matchers

#### `have_run_step`

Verify that a specific step was executed:

```ruby
expect(subject).to have_run_step(:validate_user)
```

#### With Return Value

```ruby
expect(subject).to have_run_step(:validate_user).returning({ id: 1, name: "Alice" })

# Works with regex for partial matching
expect(subject).to have_run_step(:generate_token).returning(/^token_/)
```

#### With Execution Order

```ruby
expect(subject).to have_run_step(:send_email).after(:create_user)
```

#### Combined Assertions

```ruby
expect(subject).to have_run_step(:process_payment)
  .returning({ status: "completed" })
  .after(:validate_order)
```

### Retry Matchers

#### `have_retried_step`

Verify that a step was retried:

```ruby
expect(subject).to have_retried_step(:flaky_api_call)

# With specific retry count
expect(subject).to have_retried_step(:flaky_api_call).times(3)
```

### Validation Matchers

#### `have_validation_error`

Check for input validation errors:

```ruby
subject = test_reactor(UserReactor, email: "invalid", age: 10)

expect(subject).to be_failure
expect(subject).to have_validation_error(:email)
expect(subject).to have_validation_error(:age)
```

---

## Complete Examples

### Testing a Payment Workflow

```ruby
RSpec.describe PaymentWorkflow do
  describe "successful payment" do
    it "processes payment and creates invoice" do
      subject = test_reactor(PaymentWorkflow, 
        order_id: 123,
        amount: 99.99,
        card_token: "tok_visa"
      )
      
      expect(subject).to be_success
      expect(subject).to have_run_step(:validate_order)
      expect(subject).to have_run_step(:charge_card).after(:validate_order)
      expect(subject).to have_run_step(:create_invoice).after(:charge_card)
      
      expect(subject.step_result(:charge_card)).to include(
        status: "succeeded"
      )
    end
  end
  
  describe "payment failure" do
    it "handles declined cards gracefully" do
      subject = test_reactor(PaymentWorkflow,
        order_id: 123,
        amount: 99.99,
        card_token: "tok_declined"
      ).mock_step(:charge_card) do |args, context|
        Failure("Card declined", code: "card_declined")
      end
      
      expect(subject).to be_failure
      expect(subject.error).to include("Card declined")
    end
  end
  
  describe "with retries" do
    it "retries on transient failures" do
      attempt = 0
      
      subject = test_reactor(PaymentWorkflow, params)
        .mock_step(:charge_card) do |args, context, original|
          attempt += 1
          if attempt < 3
            raise NetworkError, "Connection timeout"
          end
          original.call(args, context)
        end
      
      expect(subject).to be_success
      expect(subject).to have_retried_step(:charge_card).times(2)
    end
  end
end
```

### Testing Composed Reactors

```ruby
RSpec.describe OrderProcessor do
  it "processes order through composed payment reactor" do
    subject = test_reactor(OrderProcessor, order_id: 123)
      .composed(:process_payment)
      .mock_step(:validate_card) do |args, context|
        Success({ valid: true })
      end
    
    expect(subject).to be_success
    
    # Inspect the composed reactor
    payment = subject.composed(:process_payment)
    expect(payment.step_result(:validate_card)).to eq({ valid: true })
  end
end
```

### Testing Map Operations

```ruby
RSpec.describe BatchEmailSender do
  it "sends emails to all recipients" do
    recipients = ["a@example.com", "b@example.com", "c@example.com"]
    
    subject = test_reactor(BatchEmailSender, recipients: recipients)
      .map(:send_emails)
      .mock_step(:deliver) do |args, context|
        Success({ sent_to: args[:recipient] })
      end
    
    expect(subject).to be_success
    
    elements = subject.map_elements(:send_emails)
    expect(elements.length).to eq(3)
    expect(elements).to all(be_success)
  end
  
  it "handles partial failures" do
    recipients = ["good@example.com", "bad@example.com"]
    
    subject = test_reactor(BatchEmailSender, recipients: recipients)
      .map(:send_emails)
      .mock_step(:deliver) do |args, context|
        if args[:recipient].include?("bad")
          Failure("Invalid email")
        else
          Success({ sent_to: args[:recipient] })
        end
      end
    
    # Inspect individual results
    elements = subject.map_elements(:send_emails)
    expect(elements.first).to be_success
    expect(elements.last).to be_failure
  end
end
```

### Testing Input Validation

```ruby
RSpec.describe UserRegistration do
  context "with valid inputs" do
    it "creates the user" do
      subject = test_reactor(UserRegistration,
        email: "valid@example.com",
        password: "secure123",
        age: 25
      )
      
      expect(subject).to be_success
    end
  end
  
  context "with invalid inputs" do
    it "fails with validation errors" do
      subject = test_reactor(UserRegistration,
        email: "",
        password: "x",
        age: 10
      )
      
      expect(subject).to be_failure
      expect(subject).to have_validation_error(:email)
      expect(subject).to have_validation_error(:password)
      expect(subject).to have_validation_error(:age)
    end
  end
end
```

---

## Best Practices

### 1. Isolate External Dependencies

Mock steps that interact with external services:

```ruby
# Good: Mock external service calls
subject = test_reactor(PaymentReactor, params)
  .mock_step(:call_stripe_api) { Success(mock_response) }

# Avoid: Letting tests hit real APIs
```

### 2. Test Compensation Logic

Verify that compensation runs correctly on failure:

```ruby
it "refunds payment when shipping fails" do
  subject = test_reactor(OrderReactor, params)
    .failing_at(:create_shipment)
  
  expect(subject).to be_failure
  # Verify compensation occurred through side effects or mocks
end
```

### 3. Use Descriptive Assertions

Combine matchers for clear, intention-revealing tests:

```ruby
# Good: Clear intent
expect(subject).to have_run_step(:notify_user).after(:create_account)

# Less clear: Manual inspection
trace = subject.reactor_instance.context.execution_trace
expect(trace.any? { |t| t[:step] == :notify_user }).to be true
```

### 4. Force Synchronous Execution for Debugging

When debugging async issues, force synchronous execution:

```ruby
subject = test_reactor(AsyncReactor, params, async: false)
```

### 5. Keep Tests Focused

Test one aspect per test case:

```ruby
# Good: Focused tests
it "validates the order" do
  expect(subject).to have_run_step(:validate_order)
end

it "charges the card after validation" do
  expect(subject).to have_run_step(:charge_card).after(:validate_order)
end

# Avoid: Testing everything in one spec
it "does the entire workflow correctly" do
  # 50 lines of assertions...
end
```

---

## API Reference

### TestSubject Methods

| Method | Description |
|--------|-------------|
| `run` | Execute the reactor (auto-called by introspection methods) |
| `run_async(bool)` | Set async execution mode |
| `mock_step(name, *nested, &block)` | Mock a step's implementation |
| `failing_at(name, *nested)` | Simulate failure at a step |
| `map(step_name)` | Get proxy for mocking map step internals |
| `composed(step_name)` | Get proxy or traverse composed reactor |
| `result` | Get the final result (Success/Failure) |
| `success?` | Check if reactor succeeded |
| `failure?` | Check if reactor failed |
| `step_result(name)` | Get a specific step's result |
| `error` | Get the error message if failed |
| `map_elements(step_name)` | Get all map element subjects |
| `map_element(step_name, index:)` | Get specific map element subject |
| `reactor_instance` | Access the underlying reactor instance |

### RSpec Matchers

| Matcher | Description |
|---------|-------------|
| `be_success` | Assert reactor completed successfully |
| `be_failure` | Assert reactor failed |
| `have_run_step(name)` | Assert step was executed |
| `.returning(value)` | Chain: assert step returned value |
| `.after(step)` | Chain: assert step ran after another |
| `have_retried_step(name)` | Assert step was retried |
| `.times(count)` | Chain: assert retry count |
| `have_validation_error(field)` | Assert input validation error on field |
