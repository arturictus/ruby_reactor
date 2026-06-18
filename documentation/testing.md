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

> For reactors that use `with_lock`, `with_semaphore`, `with_rate_limit`, `with_period`, or `with_ordered_lock`, see [Testing Coordination Primitives](#testing-coordination-primitives) — it covers the `be_skipped`, `be_locked`, `have_available_tokens`, `have_held_tokens`, `have_rate_limit_count`, `be_period_marked`, `have_ordered_lock_next`, `have_ordered_lock_last_completed`, `have_ordered_lock_in_flight`, and `be_ordered_lock_drained` matchers, plus patterns for testing async snooze and escalation.

> Examples elsewhere in the documentation mix class steps with inline blocks — class steps where the logic matters, inline blocks where a step is trivial. For production code, prefer [class-based steps](core_concepts.md#step-classes) and unit-test them directly — see [Testing Step Classes](#testing-step-classes) below.

## Testing Step Classes

Class steps are plain Ruby classes — test `run`, `compensate`, and `undo` without booting a reactor:

```ruby
RSpec.describe ReserveInventoryStep do
  describe ".run" do
    it "reserves inventory for valid orders" do
      order = { items: [{ product_id: 1, quantity: 2 }] }
      result = described_class.run({ order: order }, nil)

      expect(result).to be_success
      expect(result.value[:reservation_id]).to be_present
    end
  end

  describe ".undo" do
    it "releases a successful reservation" do
      result = described_class.undo({ reservation_id: "res-1" }, {}, nil)

      expect(result).to be_success
    end
  end
end
```

Use direct class-method specs for step business logic. Use `test_reactor` and `mock_step` for integration tests at the reactor level — including [mocking class-based steps](#wrapping-original-implementations), where the mock block receives an `original` callable.

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

### Chaining Multiple Mocks

You can chain multiple `mock_step` calls to mock several steps in a single fluent expression. This is useful when you need to isolate multiple external service calls:

```ruby
RSpec.describe MultipleRequestsReactor do
  subject(:reactor) do
    test_reactor(described_class, request_id: 1)
      .mock_step(:call_service_1) { |args| Success(args[:request_id]) }
      .mock_step(:call_service_2) { |args| Success(args[:request_id]) }
      .mock_step(:call_service_3) { |args| Success(args[:request_id]) }
  end

  it "processes successfully with all mocked services" do
    expect(reactor).to be_success
  end
end
```

Each `mock_step` call returns the `TestSubject`, allowing you to chain as many mocks as needed. The mocks are applied in the order specified, and each mocked step will use the provided block instead of its original implementation.

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

## Testing Interrupts

RubyReactor provides comprehensive test helpers for testing reactors that use the `interrupt` DSL for pause/resume workflows.

### Interrupt State Introspection

#### Checking Paused State

```ruby
subject = test_reactor(ApprovalWorkflow, request_id: 123)

# Check if reactor is paused
subject.paused?  # => true/false

# Get the current interrupt step name
subject.current_step  # => :wait_for_approval (Symbol) or nil
```

#### Getting Ready Interrupt Steps

When a reactor has multiple concurrent interrupts (e.g., parallel approvals), use `ready_interrupt_steps` to see all steps that are ready to be resumed:

```ruby
subject = test_reactor(MultiApprovalWorkflow, params)

# Get all ready interrupt steps
subject.ready_interrupt_steps  # => [:manager_approval, :director_approval]
```

### Resuming Paused Reactors

Use `resume` to continue execution with a payload:

```ruby
# Single interrupt - step is automatically detected
subject = test_reactor(ApprovalWorkflow, request_id: 123)
expect(subject).to be_paused

subject.resume(payload: { approved: true, approver: "manager" })

expect(subject).to be_success
```

#### Multiple Concurrent Interrupts

When multiple interrupts are ready, you **must** specify which step to resume:

```ruby
subject = test_reactor(MultiApprovalWorkflow, params)

# This will raise an error - ambiguous which interrupt to resume
# subject.resume(payload: { status: "approved" })  # => Error!

# Specify the step explicitly
subject.resume(step: :manager_approval, payload: { status: "approved" })
subject.resume(step: :director_approval, payload: { status: "approved" })

expect(subject).to be_success
```

### Interrupt Matchers

#### `be_paused`

Assert that a reactor is in paused state:

```ruby
expect(subject).to be_paused
expect(subject).not_to be_paused
```

#### `be_paused_at`

Assert that a reactor is paused with specific interrupt(s) ready:

```ruby
# Single interrupt
expect(subject).to be_paused_at(:wait_for_approval)

# Check if specific interrupt is among the ready ones
expect(subject).to be_paused_at(:manager_approval)

# Check multiple interrupts are ready
expect(subject).to be_paused_at(:manager_approval, :director_approval)
```

#### `have_ready_interrupts`

Assert the exact set of ready interrupt steps:

```ruby
# Assert exactly these interrupts are ready
expect(subject).to have_ready_interrupts(:manager_approval, :director_approval)
```

### Complete Interrupt Testing Example

```ruby
RSpec.describe ApprovalWorkflow do
  describe "single approval" do
    it "pauses at approval step and resumes" do
      subject = test_reactor(ApprovalWorkflow, request_id: 123)
      
      # Verify paused state
      expect(subject).to be_paused
      expect(subject).to be_paused_at(:wait_for_approval)
      expect(subject.current_step).to eq(:wait_for_approval)
      
      # Step results before interrupt should be available
      expect(subject.step_result(:prepare_request)).to be_present
      
      # Resume with approval payload
      subject.resume(payload: { approved: true, approver: "manager" })
      
      # Should complete after resume
      expect(subject).to be_success
      expect(subject.step_result(:finalize)).to include(approved: true)
    end
    
    it "stays paused with invalid payload" do
      subject = test_reactor(ApprovalWorkflow, request_id: 123)
      
      # Resume with invalid payload (fails validation)
      expect {
        subject.resume(payload: { invalid: "data" })
      }.to raise_error(RubyReactor::Error::ValidationError)
    end
  end
  
  describe "multiple approvals" do
    it "handles concurrent approval requirements" do
      subject = test_reactor(MultiApprovalWorkflow, request_id: 456)
      
      # Verify multiple interrupts are ready
      expect(subject).to be_paused
      expect(subject).to have_ready_interrupts(:manager_approval, :director_approval)
      
      # Resume first approval
      subject.resume(step: :manager_approval, payload: { status: "approved" })
      
      # Still paused, waiting for second approval
      expect(subject).to be_paused
      expect(subject.ready_interrupt_steps).to eq([:director_approval])
      
      # Complete second approval
      subject.resume(step: :director_approval, payload: { status: "approved" })
      
      expect(subject).to be_success
    end
    
    it "requires step specification for multiple interrupts" do
      subject = test_reactor(MultiApprovalWorkflow, request_id: 456)
      
      # Without step: parameter, raises error
      expect {
        subject.resume(payload: { status: "approved" })
      }.to raise_error(
        RubyReactor::Error::ValidationError,
        /multiple interrupt steps are ready/
      )
    end
  end
end
```

---

## Testing Coordination Primitives

Reactors that declare `with_lock`, `with_semaphore`, `with_rate_limit`, `with_period`, or `with_ordered_lock` can be tested with both vanilla execution assertions and dedicated state matchers that read the live Redis state via the configured storage adapter.

### Test environment requirements

The matchers ship with the standard test setup — once `RubyReactor::RSpec.configure(config)` runs in your `spec_helper.rb`, they're available. They require:

- A real Redis (the in-memory test mode does not back the primitives).
- The `type: :reactor` tag on the example group. It enables Sidekiq fake mode, wipes the storage adapter between examples (so leftover lock owners, semaphore tokens, rate-limit counters and period markers don't leak), resets the snooze knobs, and includes the async-job helpers (`drain_async_jobs`, `pending_async_jobs`) described below.

```ruby
RSpec.describe RefundOrderReactor, type: :reactor do
  # `test_reactor`, the state matchers, and the async-job helpers are all in scope here.
end
```

All execution in these examples goes through the `test_reactor` helper — never reach into `RubyReactor::SidekiqWorkers::Worker` directly. For async reactors, `test_reactor` processes the queued jobs for you by default; pass `process_jobs: false` when you need to inspect or drive the queue yourself.

### The `Skipped` result

`RubyReactor::Skipped` is a `Success` subclass returned in two cases: a `with_period` bucket has already been claimed, or a step explicitly returns `RubyReactor.Skipped(reason: "...")` to halt cleanly (no compensation runs). Use `be_skipped` to distinguish it from a plain `Success`:

```ruby
expect(test_reactor(MonthlyReportReactor, org_id: 7)).to be_skipped                  # any Skipped
expect(test_reactor(MonthlyReportReactor, org_id: 7)).to be_skipped.because(:period) # gate hit
expect(test_reactor(SyncReactor, foo: 1)).to be_skipped.at_step(:second)             # step return
```

`Skipped` still satisfies `success?`, so legacy `if result.success?` callers continue to work; the matcher reads `subject.result` and discriminates on `skipped?`.

### Asserting lock state

```ruby
it "releases the lock after a successful run" do
  test_reactor(RefundOrderReactor, order_id: 42).run

  expect("order:42").not_to be_locked
end

it "holds the lock for the duration of a long step" do
  thread = Thread.new { test_reactor(LongRefundReactor, order_id: 42).run }
  # Give the executor a moment to acquire
  sleep 0.05

  expect("order:42").to be_locked
  expect("order:42").to be_locked.by(thread.value.reactor_instance.context.context_id)
end

it "raises when contention is hit inline" do
  redis.hset("lock:order:42", "owner", "someone_else")
  redis.hset("lock:order:42", "count", "1")

  expect { test_reactor(RefundOrderReactor, order_id: 42).run }
    .to raise_error(RubyReactor::Lock::AcquisitionError)
end
```

The `be_locked` matcher takes the **user-provided lock key** (without the internal `lock:` prefix). Use the `.by(owner)` chain to assert ownership — typically the `context_id` of the top-level execution.

### Asserting semaphore state

```ruby
it "returns the token to the pool on success" do
  3.times { test_reactor(ApiCallReactor, {}).run }

  expect("api_limit").to have_available_tokens(5)
  expect("api_limit").to have_held_tokens(0)
end

it "exhausts capacity when held externally" do
  s = RubyReactor::Semaphore.new("api_limit", limit: 2)
  2.times { s.acquire }

  expect("api_limit").to have_available_tokens(0)
  expect("api_limit").to have_held_tokens(2)

  expect { test_reactor(ApiCallReactor, {}).run }.to raise_error(RubyReactor::Semaphore::AcquisitionError)
end
```

Both matchers take the **user-provided semaphore name** (without the `semaphore:` prefix).

### Asserting rate-limit state

```ruby
it "counts each call against the per-second window" do
  3.times { test_reactor(ChargeReactor, account_id: 42).run }

  expect("stripe:42").to have_rate_limit_count(3).for(:second)
end

it "raises inline once the window is full" do
  3.times { test_reactor(ChargeReactor, account_id: 42).run }

  expect { test_reactor(ChargeReactor, account_id: 42).run }
    .to raise_error(RubyReactor::RateLimit::ExceededError) do |e|
      expect(e.period_name).to eq("second")
      expect(e.retry_after_seconds).to be_between(1, 1)
    end
end
```

`have_rate_limit_count(n).for(period)` looks at the **current** bucket for the given `period` (use the same symbol or integer seconds you passed to `with_rate_limit`). For multi-window limits, assert each window separately:

```ruby
expect("stripe:42").to have_rate_limit_count(3).for(:second)
expect("stripe:42").to have_rate_limit_count(3).for(:minute)
```

For a **named global limit** (`with_rate_limit(:stripe)`), the key base is the name itself, so assert against that — register the limit first:

```ruby
before do
  RubyReactor.configure do |config|
    config.rate_limits.register(:stripe, limit: 3, period: :second)
  end
end

it "shares one bucket across reactors" do
  3.times { ChargeReactor.run(account_id: 42) }

  expect("stripe").to have_rate_limit_count(3).for(:second)
end
```

### Asserting period markers

```ruby
it "marks the bucket after the first successful run" do
  test_reactor(MonthlyReportReactor, org_id: 7).run
  expect("monthly_report:7").to be_period_marked.for(:month)
end

it "does not mark the bucket when the run fails" do
  test_reactor(FailingMonthlyReactor, org_id: 7).run
  expect("monthly_report:7").not_to be_period_marked.for(:month)
end

it "skips a second call in the same bucket" do
  test_reactor(MonthlyReportReactor, org_id: 7).run

  expect(test_reactor(MonthlyReportReactor, org_id: 7)).to be_skipped.because(:period)
end
```

`be_period_marked.for(period)` checks the marker at the **current** bucket. To verify the marker's TTL behavior, drop to direct Redis: `redis.ttl(RubyReactor::Period.key("monthly_report:7", :month))`.

### Asserting ordered-lock state

`with_ordered_lock` exposes its counters through four matchers, all taking the **user-provided ordered-lock key** as their subject (no prefix). They all read live Redis via `RubyReactor::OrderedLock.peek(key)` under the hood.

`OrderedReactor` here is `async`, so its work runs through queued Sidekiq jobs. Pass `process_jobs: false` to `test_reactor` when you want to assign nonces without running the jobs, then drive the queue with `drain_async_jobs` (run everything to completion) or `pending_async_jobs` (perform individual jobs out of order).

```ruby
it "assigns nonces in caller order" do
  # process_jobs: false enqueues without running, so the nonces stay in-flight.
  3.times { |i| test_reactor(OrderedReactor, { account_id: 1, thing: i + 1 }, process_jobs: false).run }

  expect("orders:1").to have_ordered_lock_next(3)
  expect("orders:1").to have_ordered_lock_last_completed(0)
  expect("orders:1").to have_ordered_lock_in_flight(1, 2, 3)
end

it "advances the cursor as workers complete" do
  3.times { |i| test_reactor(OrderedReactor, { account_id: 1, thing: i + 1 }, process_jobs: false).run }
  drain_async_jobs

  expect("orders:1").to be_ordered_lock_drained
end

it "keeps blocked nonces in-flight while the gate rejects them" do
  RubyReactor.configuration.lock_snooze_base_delay = 0.01
  RubyReactor.configuration.lock_snooze_jitter = 0
  RubyReactor.configuration.lock_snooze_max_attempts = 2

  test_reactor(OrderedReactor, { account_id: 9, thing: 1 }, process_jobs: false).run
  test_reactor(OrderedReactor, { account_id: 9, thing: 2 }, process_jobs: false).run

  # Perform only nonce 2 — nonce 1 never runs, so the gate must reject nonce 2.
  blocked = pending_async_jobs.last
  blocked.perform!

  expect("orders:9").to have_ordered_lock_last_completed(0)
  expect("orders:9").to have_ordered_lock_in_flight(1, 2)
end
```

Matcher reference:

| Matcher                                 | Asserts                                                          |
| --------------------------------------- | ---------------------------------------------------------------- |
| `have_ordered_lock_next(n)`             | `INCR` target — the highest assigned nonce.                      |
| `have_ordered_lock_last_completed(n)`   | The cursor — last nonce that has advanced terminally.            |
| `have_ordered_lock_in_flight(*nonces)`  | Exact (order-insensitive) set of nonces still in `assigned_at`.  |
| `be_ordered_lock_drained`               | All three counters at zero / GC'd. Use after a successful drain. |

After a clean drain, all three Redis keys are deleted by the Lua advance script and `peek` returns `{ next: 0, last_completed: 0, in_flight: [] }` — `be_ordered_lock_drained` exists so you don't have to remember that.

To test the poison-pill timeout, manipulate the `assigned_at` hash directly or stub `Time.now`:

```ruby
it "auto-advances past a blocker after poison_pill_timeout" do
  Timecop.freeze(Time.at(1000)) do
    test_reactor(OrderedReactor, { account_id: 5, thing: 1 }, process_jobs: false).run
  end
  Timecop.freeze(Time.at(2000)) do
    # poison_pill_timeout in the example reactor is 60s; blocker is 1000s old.
    state, _retry_after, _last = adapter.ordered_lock_can_proceed(
      "orders:5", nonce: 2, poison_pill_timeout: 60
    )
    expect(state).to eq("poison_advance")
  end
end
```

### Testing async snooze behavior

When an `async` reactor hits contention (a held lock or an exhausted semaphore), its queued job reschedules itself with a snooze delay instead of failing. Drive this through `test_reactor` with `process_jobs: false`, then perform the queued job with `pending_async_jobs`:

```ruby
it "reschedules with a snooze delay when the lock is held" do
  RubyReactor.configuration.lock_snooze_base_delay = 5
  RubyReactor.configuration.lock_snooze_jitter = 0

  # Hold the lock so the reactor's job can't acquire it.
  redis.hset("lock:order:42", "owner", "other")
  redis.hset("lock:order:42", "count", "1")

  subject = test_reactor(AsyncRefundReactor, { order_id: 42 }, process_jobs: false).run
  job = pending_async_jobs.first

  # The next snooze re-enqueues the same job with an incremented attempt count.
  expect(RubyReactor::SidekiqWorkers::Worker)
    .to receive(:perform_in)
    .with(5.0, *job.args, 1)

  job.perform!
end
```

The `perform_in` delay is `lock_snooze_base_delay + rand(0..lock_snooze_jitter)`. Pin those knobs to deterministic values (`jitter = 0`) in tests that assert on the exact delay.

### Testing snooze escalation

When the snooze cap (`lock_snooze_max_attempts`) is reached, the job stops rescheduling and the context is marked failed. With `test_reactor`'s default job processing, `drain_async_jobs` runs every snooze through to that cap, so you can assert on the subject directly:

```ruby
it "marks the context as failed after the snooze cap" do
  RubyReactor.configuration.lock_snooze_max_attempts = 3
  RubyReactor.configuration.lock_snooze_base_delay = 0.01
  RubyReactor.configuration.lock_snooze_jitter = 0

  # Hold the lock for good so every snooze attempt fails to acquire.
  redis.hset("lock:order:42", "owner", "other")
  redis.hset("lock:order:42", "count", "1")

  # test_reactor drains the queued snoozes for us; after the cap the job gives up.
  subject = test_reactor(AsyncRefundReactor, order_id: 42)

  expect(subject).to be_failure
  expect(pending_async_jobs).to be_empty
end
```

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
| `result` | Get the final result (Success/Failure/InterruptResult) |
| `success?` | Check if reactor succeeded |
| `failure?` | Check if reactor failed |
| `paused?` | Check if reactor is paused at an interrupt |
| `current_step` | Get the current interrupt step name (Symbol or nil) |
| `ready_interrupt_steps` | Get all ready interrupt step names (Array of Symbols) |
| `resume(payload:, step:)` | Resume a paused reactor with payload; `step:` required for multiple interrupts |
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
| `be_paused` | Assert reactor is paused at an interrupt |
| `be_paused_at(*steps)` | Assert reactor is paused with specific interrupt(s) ready |
| `have_ready_interrupts(*steps)` | Assert exact set of ready interrupt steps |
| `have_run_step(name)` | Assert step was executed |
| `.returning(value)` | Chain: assert step returned value |
| `.after(step)` | Chain: assert step ran after another |
| `have_retried_step(name)` | Assert step was retried |
| `.times(count)` | Chain: assert retry count |
| `have_validation_error(field)` | Assert input validation error on field |
| `be_skipped` | Assert result is a `RubyReactor::Skipped` (period gate or step return) |
| `.because(reason)` | Chain: assert the skip reason matches |
| `.at_step(name)` | Chain: assert the halting step (step-returned Skipped only) |
| `be_locked` | Assert an exclusive lock is currently held for the given key |
| `.by(owner)` | Chain: assert the lock owner (typically a `context_id`) |
| `have_available_tokens(n)` | Assert `n` semaphore tokens are still in the pool |
| `have_held_tokens(n)` | Assert `n` semaphore tokens are currently checked out |
| `have_rate_limit_count(n)` | Assert the current rate-limit bucket count |
| `.for(period)` | Chain (required): which window to check (`:second`, `:minute`, …, or integer seconds) |
| `be_period_marked` | Assert a `with_period` bucket has been marked |
| `.for(period)` | Chain (required): which bucket granularity to check |
