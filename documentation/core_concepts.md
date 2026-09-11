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

RubyReactor supports two definition styles:

| Style | When to use |
|-------|-------------|
| **Class steps** (preferred) | Production logic, compensation/undo, shared steps, anything you will test |
| **Inline blocks** | Prototypes, trivial steps, concise documentation examples |

> Documentation examples mix class steps with inline blocks — class steps where the logic matters, inline blocks where a step is trivial. Prefer class steps in your application code, especially as reactors grow.

### Step Classes (preferred)

Define steps as separate classes that subclass `RubyReactor::Step`. This is the recommended approach for real business logic: it keeps reactors readable, makes steps easy to unit test, and lets you reuse the same step across multiple reactors.

Every action (`run`, `compensate`, `undo`) runs on a **fresh instance built just for that action** — an instance built for `run` is discarded once it returns, and `undo`/`compensate` each get their own new instance from the stored arguments/result/reason. Nothing set inside `run` (an ivar, a memoized value) is visible inside a later `undo` or `compensate`, even when they happen to run in the same process — this is what makes behavior identical whether a step's rollback lands in the same worker or, as with an `async_step`, a separate one later. Instance readers: `inputs`, `context` (available in all three), `result` (`undo` only), `reason` (`compensate` only).

```ruby
class ReserveInventoryStep < RubyReactor::Step
  def run
    order = inputs[:order]
    # Business logic for inventory reservation
    reservation_id = InventoryService.reserve(order[:items])
    Success({
      reservation_id: reservation_id,
      reserved_items: order[:items].size
    })
  end

  def compensate
    # Cleanup logic for failed reservations
    puts "Cleaning up inventory reservation due to: #{reason}"
    # Release any partial reservations
    Success("Inventory reservation cleaned up")
  end

  def undo
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

**Benefits of class steps:**

- **Testability** — call `MyStep.run(args, context)` (and `compensate`/`undo`) directly in unit specs without running the whole reactor
- **Composability** — share a step class across reactors and build larger workflows from small, focused units
- **Readability** — reactor definitions stay orchestration-only; business logic lives in named classes instead of growing inline blocks
- **Maintainability** — compensation and undo logic sit beside `run` in one place

**Step instance methods:**
- **`run`**: The main business logic, reading `inputs`/`context`. Returns `Success(result)`, `Failure(error)`, `Halt(reason:)` (see [Halting a reactor cleanly](#halting-a-reactor-cleanly)), or `Skipped(value)` (see [Skipping a single step](#skipping-a-single-step)). Omitting it raises `NotImplementedError` naming the class
- **`compensate`**: Cleanup for the current failing step, reading `reason`/`inputs`/`context`. Called when the step fails. Defaults to `Skipped()` if omitted
- **`undo`**: Rollback for previously successful steps, reading `result`/`inputs`/`context`. Called during reactor failure rollback. Defaults to `Skipped()` if omitted

**Class-level entry points** (what the executor, the async worker, and a direct unit-test call all use): `MyStep.run(arguments, context)` (aliased `.call`), `MyStep.undo(result, arguments, context)`, `MyStep.compensate(reason, arguments, context)` — each builds the fresh instance described above, enforces the input contract first, and translates any `success!`/`fail!`/`skip!`/`halt!` signal into its result wrapper.

> A step's own input-validation failure is always non-retryable — `result.retryable?` is `false` whether the violation happened synchronously, inside an `async_step` worker, or inside a `compose`d child (see [Step Input Contracts](../README.md#step-input-contracts) in the README).

### Inline step definition

For quick prototypes or trivial steps, define logic inline inside the reactor. Unlike a class step's zero-arg instance methods, an inline `run` block always receives two positional arguments: the resolved arguments hash and the execution context. Declare inputs with `argument :name, source`:

```ruby
step :validate_order do
  argument :order_id, input(:order_id)

  run do |args, _context|
    order = Order.find(args[:order_id])
    return Failure("Order not found") unless order
    Success({ order: order })
  end
end
```

Inline blocks support `compensate` and `undo` the same way class steps do — useful for small examples, but harder to test and reuse as logic grows.

**Step components (both styles):**

- **Name**: Unique identifier (symbol)
- **Implementation**: `run` block or `self.run` class method
- **Dependencies**: Other steps that must complete first (`argument`, `wait_for`)
- **Compensation / undo**: Rollback logic for failures

### Step outcome helpers (`success!` / `fail!` / `halt!` / `skip!`)

`return Failure(...) unless ...` guard clauses work, but every one needs its own `return`. The one-line helpers drop that boilerplate — call them and the step body ends right there, with the matching signal:

| Helper | Equivalent |
|--------|------------|
| `success!(value)` | `return Success(value)` |
| `fail!(error, **opts)` | `return Failure(error, **opts)` |
| `halt!(reason:, **kwargs)` | `return Halt(reason:, **kwargs)` |
| `skip!(value)` | `return Skipped(value)` |

The [validate_order example above](#inline-step-definition) written with the helper:

```ruby
run do |args, _context|
  order = Order.find(args[:order_id])
  fail!("Order not found") unless order
  Success({ order: order })
end
```

They are not limited to a single guard clause at the top of `run` — a chain of them replaces what would otherwise be a nested `if/elsif` or an accumulator variable threaded through the method:

```ruby
def run
  order = Order.find_by(id: inputs[:order_id])
  fail!("Order not found") unless order
  fail!("Order already processed") if order.processed?
  fail!("Order cancelled") if order.cancelled?

  Success(order: order)
end
```

**Any call depth.** A helper works from a method the step body calls, however deep — the call ends the *step*, not just the current method, so validation logic can live in a plain helper method instead of returning a signal up through every caller:

```ruby
def run
  check_eligibility!   # fail! inside ends the step, not just this method
  Success(processed: true)
end

def check_eligibility!
  fail!("underage") if inputs[:user].age < 18
  fail!("suspended") if inputs[:user].suspended?
end
```

**Rescue-safe.** The helpers unwind via `throw`/`catch`, not an exception, so a step's own `rescue StandardError` (or even `rescue Exception`) around risky code cannot accidentally swallow the outcome — `ensure` blocks still run.

Available in `run`, `compensate`, and `undo` bodies, in both class steps and inline blocks. See [Halting a reactor cleanly](#halting-a-reactor-cleanly) and [Skipping a single step](#skipping-a-single-step) for `halt!`/`skip!`'s reactor-level semantics — the helper is just the one-line spelling of the same signal.

Calling one outside a step body (no enclosing step invocation to catch it) raises `UncaughtThrowError` — that's a programming error, not a supported use.

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
class ValidateOrderStep < RubyReactor::Step
  def run
    validate_order_logic
  end
end

class ProcessPaymentStep < RubyReactor::Step
  def run
    process_payment_for_order(inputs[:order])
  end
end

class SendConfirmationStep < RubyReactor::Step
  def run
    payment_result = inputs[:payment_result]
    send_confirmation_email(payment_result[:order], payment_result[:payment_id])
  end
end

class OrderProcessingReactor < RubyReactor::Reactor
  step :validate_order, ValidateOrderStep

  step :process_payment, ProcessPaymentStep do
    argument :order, result(:validate_order)
  end

  step :send_confirmation, SendConfirmationStep do
    argument :payment_result, result(:process_payment)
  end
end
```

**Dependency Resolution:**
- Topological sorting ensures correct execution order
- Future feature: Parallel execution of independent steps (when available)
- Validation prevents circular dependencies

## Results

`Reactor.run` returns one of five result types:

- **`RubyReactor::Success`** — `success?` is `true`. `value` holds the output of the step named in `returns`, or the full `intermediate_results` hash if no `returns` is declared. A run containing skipped steps still ends here — `Skipped` never surfaces as the run's terminal result (see below).
- **`RubyReactor::Failure`** — `failure?` is `true`. Readers include `error`, `step_name`, `reactor_name`, `step_arguments`, `inputs`, `exception_class`, `file_path`, `line_number`, `backtrace`, `validation_errors`, and `retryable?`.
- **`RubyReactor::Halt`** — a clean stop. A `Success` subclass, so `success?` is `true` **and** `halted?` is `true`; `reason` and `step_name` say where/why. Returned when a step returns `Halt(reason: "...")` or a `with_period` bucket is already claimed. Remaining steps don't run and completed steps are **not** compensated. See [Halting a reactor cleanly](#halting-a-reactor-cleanly).
- **`RubyReactor::DispatchResult`** — returned by an async reactor or when a step hands off to a worker. Readers: `job_id`, `execution_id`, `intermediate_results`.
- **`RubyReactor::InterruptResult`** — returned when an `interrupt` step pauses execution. Readers: `execution_id`, `correlation_id`, `status` (`:paused`), `timeout_at`, `intermediate_results`.

`RubyReactor::Skipped` is a sixth signal, but it is a *step-level* result, not a run-level one: a step's `run` can return it, and `MyStep.run(args, context)` returns it directly in a unit test, but `Reactor.run` always surfaces a plain `Success` at the top even when the `returns` step was itself skipped — the skip is visible in the execution trace, not in the run's terminal result type. See [Skipping a single step](#skipping-a-single-step).

Step-by-step state lives on the context, not the result object. Reload via `Reactor.find(execution_id)` to inspect:

```ruby
reactor = OrderProcessingReactor.find(execution_id)
reactor.context.intermediate_results # => { validate_order: {...}, ... }
reactor.context.status               # => "completed" | "failed" | "paused" | "running"
reactor.execution_trace              # ordered list of run/undo/compensate entries
reactor.result                       # reconstructed Success/Failure/InterruptResult
```

## Error Handling

RubyReactor provides sophisticated error handling with automatic compensation.

### Step Failures

When a step fails, execution stops and compensation begins:

```ruby
class ProcessPaymentStep < RubyReactor::Step
  def run
    PaymentService.charge(inputs[:amount], inputs[:token])
  end

  def compensate
    # Best-effort cleanup specific to this step's failure
    AuditService.log_payment_failure(inputs[:token], reason.message)
  end
end

class PaymentReactor < RubyReactor::Reactor
  step :process_payment, ProcessPaymentStep do
    argument :amount, input(:amount)
    argument :token, input(:card_token)
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

## Retries

RubyReactor supports automatic retry mechanisms for failed steps with configurable backoff strategies.

### When Retries Occur

When a step fails during execution, RubyReactor can automatically retry the step before triggering compensation and rollback. Retries occur when:

1. A step raises an exception during its `run` block
2. The step has retry configuration (either reactor-level defaults or step-specific settings)
3. The maximum retry attempts haven't been exceeded

### Retry Execution Flow

```mermaid
graph TD
    A[Step Fails] --> B{Attempts < Max<br/>Attempts?}
    B -->|Yes| C[Calculate Backoff Delay]
    C --> D[Queue for Retry<br/>with Delay]
    D --> E[Resume Execution<br/>from Failed Step]
    B -->|No| F[All Retries Exhausted]
    F --> G[Run Compensation<br/>for Failing Step]
    G --> H[Run Undo for<br/>Successful Steps<br/>in Reverse Order]
```

### Retry Configuration

Retries can be configured at the reactor level (as defaults) or per step:

```ruby
class OrderProcessingReactor < RubyReactor::Reactor
  step :validate_order do
    run do
      # validate input
    end

    undo do
      # Nothing to do here just as example
    end
  end

  step :check_inventory do
    # Uses reactor defaults (5 attempts, fixed backoff)
    run do 
      InventoryService.check_availability(product_id, quantity) 
    end

    undo do
      # Nothing to do here just as example
    end
  end

  step :reserve_inventory do
    retries max_attempts: 5, backoff: :fixed, base_delay: 2 # 2 seconds
    
    run do 
      InventoryService.reserve(product_id, quantity)
    end

    compensate do |error, arguments, context|
      # Cleanup partial reservations
      puts "Cleaning up inventory reservation due to: #{error.message}"
    end
  end
end
```

### Retry Parameters

- **`max_attempts`**: Maximum number of execution attempts (including initial attempt)
- **`backoff`**: Strategy for calculating delays between retries
  - `:exponential` (default): Delay doubles with each attempt
  - `:linear`: Delay increases linearly  
  - `:fixed`: Same delay for each attempt
- **`base_delay`**: Base delay for calculations (in seconds or ActiveSupport duration)

### Example Execution with Retries

Consider a reactor where `reserve_inventory` fails has a set `retries` with max_attemps of 5 max attempts with fixed backoff:

```
1. run step=validate_order          # Success
2. run step=check_inventory         # Success  
3. run step=reserve_inventory       # Attempt 1 - Fails
4. run step=reserve_inventory       # Attempt 2 - Fails (retry with 2s delay)
5. run step=reserve_inventory       # Attempt 3 - Fails (retry with 2s delay)
6. run step=reserve_inventory       # Attempt 4 - Fails (retry with 2s delay)
7. run step=reserve_inventory       # Attempt 5 - Fails (retry with 2s delay)
8. compensate step=reserve_inventory # All retries exhausted
9. undo step=check_inventory        # Rollback successful steps
10. undo step=validate_order        # in reverse order
```

### Retry vs Compensation vs Undo

- **Retries**: Re-attempt the failing step with backoff delays
- **Compensation**: Cleanup logic for the failing step after all retries are exhausted
- **Undo**: Rollback logic for previously successful steps during reactor failure

Retries happen first, followed by compensation and undo only if all retry attempts fail.

### Asynchronous Retries

For asynchronous reactors, retries are queued as background jobs with calculated delays, preventing worker thread blocking:

```ruby
class AsyncPaymentReactor < RubyReactor::Reactor
  background all: true

  step :charge_card do
    retries max_attempts: 3, backoff: :exponential, base_delay: 5.seconds
    run do
      # This might fail due to network issues
      PaymentService.charge(card_token, amount)
    end
  end
end
```

Failed steps are automatically requeued with exponential backoff delays, allowing workers to process other jobs while waiting.

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

```ruby
async_result = Reactor.run(inputs)
# Returns immediately
async_result.execution_id # UUID to look up state later

# Reload to inspect status / final result
reactor = Reactor.find(async_result.execution_id)
case reactor.context.status.to_s
when "completed" then reactor.result.value
when "failed"    then reactor.result.error
when "paused"    then reactor.result.correlation_id
when "running"   then :still_running
end
```

**Characteristics:**

- Non-blocking execution
- Background processing with Sidekiq or ActiveJob
- Retry capabilities
- Better scalability

## Step Arguments

`run` blocks always receive two positional arguments: the resolved arguments hash and the context. Declare each argument explicitly with `argument :name, source` — there is no implicit keyword injection.

Sources you can use:

- `input(:name)` — value from the reactor's inputs (the hash passed to `Reactor.run`).
- `input(:name, :path)` — nested path access into a hash input.
- `result(:step_name)` — full output of a previous step.
- `result(:step_name, :path)` — nested path into a previous step's output.
- `value(literal)` — a constant value.

```ruby
step :validate_order do
  argument :order_id, input(:order_id)
  argument :customer_id, input(:customer_id)

  run do |args, _context|
    order = Order.find_by(id: args[:order_id], customer_id: args[:customer_id])
    Success({ order: order })
  end
end

step :process_payment do
  argument :order, result(:validate_order, :order)

  run do |args, _context|
    payment = PaymentService.charge(args[:order].total, args[:order].card_token)
    Success({ payment_id: payment.id })
  end
end
```

If a step declares no `argument`s, the reactor's raw inputs hash is passed as `args`.

## Undo

Undo provides transactional rollback for previously successful steps when a later step fails.

### When Undo Runs

Unlike compensation which only runs for the failing step, undo is triggered during the **backwalk** phase when rolling back the entire reactor execution. When a step fails:

1. **Compensation** runs for the failing step itself
2. **Undo** runs for all previously successful steps in reverse order

### Basic Undo

```ruby
class ReserveInventoryStep < RubyReactor::Step
  def run
    reservation_id = InventoryService.reserve(inputs[:items])
    Success(reservation_id: reservation_id)
  end

  def undo
    InventoryService.release(result[:reservation_id])
    Success("Inventory reservation released")
  end
end

class OrderReactor < RubyReactor::Reactor
  step :reserve_inventory, ReserveInventoryStep do
    argument :items, input(:items)
  end
end
```

### Undo Context

A class step's `undo` is a zero-arg instance method reading three things:
- **`result`**: The successful result from the step's `run`
- **`inputs`**: The resolved arguments passed to the step
- **`context`**: The full execution context with all intermediate results

An inline `undo do |result, arguments, context| ... end` block still receives the same three as positional parameters instead:

```ruby
step :complex_operation do
  argument :input, input(:payload)

  run do |args, _ctx|
    # Complex operation that modifies external state
    record = create_record(args[:input])
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
class ReserveInventoryStep < RubyReactor::Step
  def run
    reservation_id = InventoryService.reserve(inputs[:items])
    Success(reservation_id: reservation_id)
  end

  def compensate
    puts "Cleaning up after reservation failure: #{reason.message}"
    Success()
  end
end

class OrderReactor < RubyReactor::Reactor
  step :reserve_inventory, ReserveInventoryStep do
    argument :items, input(:items)
  end
end
```

### Compensation Context

A class step's `compensate` is a zero-arg instance method reading three things:
- **`reason`**: The exception that caused the step to fail
- **`inputs`**: The resolved arguments that were passed to the step
- **`context`**: The full execution context

An inline `compensate do |error, arguments, context| ... end` block still receives the same three as positional parameters instead:

```ruby
step :process_payment do
  argument :order, result(:validate_order)
  argument :payment_method, input(:payment_method)

  run do |args, _ctx|
    # Payment processing logic that might fail
    PaymentService.charge(args[:order].total, args[:payment_method])
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

## Halting a reactor cleanly

Alongside `Success` and `Failure`, a step can return **`Halt`** — a clean stop. The reactor stops immediately: remaining steps don't run, and **already-completed steps are NOT compensated or undone**. Use it when a step discovers the rest of the workflow is unnecessary and the partial progress so far is correct to keep (e.g. "user already opted out", "nothing to do this round").

`Halt` is exposed exactly like `Success` and `Failure` — as a bare helper inside both class steps and inline `run` blocks (or use the one-line `halt!(reason: ...)`, which ends the step immediately from any call depth):

```ruby
# Class step
class SyncProfileStep < RubyReactor::Step
  def run
    return Halt(reason: "user_opted_out") if inputs[:user].opted_out?

    Success(synced: ProfileService.sync(inputs[:user]))
  end
end

# Inline block — identical helper
step :sync_profile do
  argument :user, input(:user)
  run do |args, _ctx|
    next Halt(reason: "user_opted_out") if args[:user].opted_out?

    Success(synced: ProfileService.sync(args[:user]))
  end
end
```

`Halt` is a `Success` subclass, so existing `if result.success?` branches still take the right path; check `result.halted?` to distinguish it:

```ruby
result = SyncReactor.run(user: user)
result.success?  # => true
result.halted?    # => true on a clean halt, false otherwise
result.reason     # => "user_opted_out"
result.step_name  # => :sync_profile (the halting step)
```

The reactor's context status becomes `:halted` (distinct from `:completed`/`:failed`), and a `{ type: :halt, step:, reason: }` entry is appended to the execution trace.

**`Halt` vs `Failure`:** use `Halt` when the partial progress is correct and should be kept; use `Failure` when prior steps need to be rolled back. A `with_period` dedup gate also produces a `Halt` result before any step runs. See [Locks & Semaphores — The `Halt` result](locks_and_semaphores.md#the-halt-result) for the full reference and the decision matrix.

## Skipping a single step

Where `Halt` stops the whole reactor, **`Skipped`** marks just one step as skipped while the reactor keeps going. Use it when a step discovers it has nothing to do this time, but the value dependants need is still available (e.g. "already synced, here's the cached value"):

```ruby
step :maybe_sync do
  argument :user, result(:fetch_user)
  run do |args, _ctx|
    next Skipped(args[:user]) if args[:user].already_synced?

    Success(sync!(args[:user]))
  end
end

step :notify do
  argument :user, result(:maybe_sync)  # receives the user either way
  run { |args, _ctx| Success(mail(args[:user])) }
end
```

- The value behaves exactly like a `Success` value: it's stored as the step's result, and dependants read it via `result(:step)` without knowing it was skipped.
- The reactor continues; the run's overall status is `:completed`, never `:halted`.
- The step is **not** enrolled for rollback — a later failure walks past it without compensation, because nothing happened.
- A `{ type: :skipped, step:, reason: }` entry is appended to the execution trace so dashboards and tests can still see it happened.

`Skipped` is a `Success` subclass too: `result.success?` is `true`; check `result.skipped?` to distinguish it, or use the one-line `skip!(value)` helper.

**The boundary that matters:** `Skipped` means *nothing happened*. If a step's `run` produced a real side effect before deciding to bail, return `Success` and declare an `undo` instead — `Skipped` steps are never rolled back, so a side effect hidden behind one would leak on a later failure.

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
- Multi-threaded execution via Sidekiq or ActiveJob workers
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