[![Gem Version](https://badge.fury.io/rb/ruby_reactor.svg)](https://badge.fury.io/rb/ruby_reactor)
[![Build Status](https://github.com/arturictus/ruby_reactor/actions/workflows/main.yml/badge.svg)](https://github.com/arturictus/ruby_reactor/actions)  <!-- if you have CI -->
[![Ruby Style Guide](https://img.shields.io/badge/code_style-rubocop-brightgreen.svg)](https://github.com/rubocop/rubocop)
[![Downloads](https://img.shields.io/gem/dt/ruby_reactor.svg)](https://rubygems.org/gems/ruby_reactor)

# RubyReactor

A dynamic, dependency-resolving saga orchestrator for Ruby. Ruby Reactor implements the Saga pattern with compensation-based error handling and DAG-based execution planning. It leverages **Sidekiq or ActiveJob** for asynchronous execution and **Redis** for state persistence.

![Payment workflow reactor](documentation/images/payment_workflow.png)

## Why Ruby Reactor?

Building complex business transactions often results in spaghetti code or brittle "god classes." Ruby Reactor solves this by implementing the **Saga Pattern** in a lightweight, developer-friendly package. It lets you define workflows as clear, dependency-driven steps without the boilerplate of heavy enterprise frameworks.

The key value is **Reliability**: if any part of your workflow fails, Ruby Reactor automatically triggers compensation logic to undo previous steps, ensuring your system never ends up in a corrupted half-state. Whether you're coordinating microservices or monolith modules, you get atomic-like consistency with background processing built-in.

## Features

- **DAG-based Execution**: Steps are executed based on their dependencies, allowing for parallel execution of independent steps.
- **Async Execution**: Steps can be executed asynchronously in the background using Sidekiq or ActiveJob (so any ActiveJob-compatible queue — Resque, Solid Queue, GoodJob, etc. — works too).
- **Map & Parallel Execution**: Iterate over collections in parallel with the `map` step, distributing work across multiple workers.
- **Retries**: Configurable retry logic for failed steps, with exponential backoff.
- **Compensation**: Automatic rollback of completed steps when a failure occurs.
- **Interrupts**: Pause and resume workflows to wait for external events (webhooks, user approvals).
- **Input Validation**: Integrated with `dry-validation` for robust input checking.
- **Distributed Locks, Semaphores, Rate Limits, Periods & Ordered Locks**: Coordinate across processes with Redis-backed primitives — exclusive locks for at-most-one-runner, semaphores for capacity caps, fixed-window rate limits for external APIs (single or multi-window like "3/sec AND 100/min"), `with_period` to dedup reactors to once per calendar bucket, and `with_ordered_lock` for strict transaction ordering via a monotonically increasing nonce assigned at enqueue. Async jobs snooze on contention with smart `retry_after` instead of consuming retry budget.

## Comparison

| Feature                  | Ruby Reactor | dry-transaction | Trailblazer | Custom Sidekiq Jobs |
|--------------------------|--------------|-----------------|-------------|---------------------|
| DAG/Parallel execution   | Yes          | No              | Limited     | Manual              |
| Auto compensation/undo   | Yes          | No              | Manual      | Manual              |
| Interrupts (pause/resume)| Yes          | No              | No          | Manual              |
| Locks / sem / rate / per | Yes          | No              | No          | Manual              |
| Built-in web dashboard   | Yes          | No              | No          | No                  |
| Async (Sidekiq/AJ)       | Yes          | No              | Limited     | Yes                 |
| Durable crash recovery   | Yes          | No              | No          | Manual              |

## Real-World Use Cases

- **E-commerce Checkout**: Orchestrate inventory reservation, payment authorization, and shipping label generation. If payment fails, automatically release inventory and cancel the shipping request.
- **Data Import Pipelines**: Ingest optional massive CSVs using `map` steps to validate and upsert records in parallel. If data validation fails for a chunk, fail fast or collect errors while letting valid chunks succeed.
- **Subscription Billing**: Coordinate Stripe charges, invoice email generation, and internal entitlement updates. Use interrupts to pause the workflow when 3rd-party APIs are required to continue the workflow or when specific customer approval is needed.

## Table of Contents

- [Features](#features)
- [Comparison](#comparison)
- [Real-World Use Cases](#real-world-use-cases)
- [Installation](#installation)
- [Configuration](#configuration)
- [Quick Start](#quick-start)
- [Defining Steps](#defining-steps)
- [Web Dashboard](#web-dashboard)
  - [Rails Installation](#rails-installation)
- [Usage](#usage)
  - [Basic Example: User Registration](#basic-example-user-registration)
  - [Async Execution](#async-execution)
    - [Full Reactor Async](#full-reactor-async)
    - [Background Hand-off](#background-hand-off)
    - [`async_step`](#async_step-one-step-dispatched-on-its-own)
    - [`async_reactor`](#async_reactor-a-whole-nested-reactor-running-independently)
  - [Durability & Recovery](#durability--recovery)
  - [Interrupts (Pause & Resume)](#interrupts-pause--resume)
  - [Locks, Semaphores & Ordered Locks](#locks-semaphores--ordered-locks)
  - [Map & Parallel Execution](#map--parallel-execution)
    - [Map with Dynamic Source (ActiveRecord)](#map-with-dynamic-source-activerecord)
  - [Input Validation](#input-validation)
  - [Complex Workflows with Dependencies](#complex-workflows-with-dependencies)
  - [Error Handling and Compensation](#error-handling-and-compensation)
  - [Using Pre-defined Schemas](#using-pre-defined-schemas)
  - [Testing](#testing)
- [Documentation](#documentation)
- [Future improvements](#future-improvements)
- [Development](#development)
- [Contributing](#contributing)
- [Code of Conduct](#code-of-conduct)

## Installation

Add this line to your application's Gemfile:

```ruby
gem 'ruby_reactor'
```

And then execute:

    $ bundle install

Or install it yourself as:

    $ gem install ruby_reactor

## Configuration

Every setting is **optional** — RubyReactor ships with the defaults shown. Drop
this into an initializer (e.g. `config/initializers/ruby_reactor.rb`); pasted as-is
it changes nothing, so it doubles as a reference of every knob.

> **Reading the block:** lines starting with `##` are documentation. Lines starting
> with a single `#` (a `config.…` call) are real settings commented at their
> default — uncomment one to enable it.

```ruby
RubyReactor.configure do |config|
  ## === Storage (Redis) ===

  ## Storage adapter. Default: :redis (the only adapter shipped today).
  # config.storage.adapter = :redis

  ## Redis URL. Default: "redis://localhost:6379/0".
  config.storage.redis_url = ENV.fetch("REDIS_URL", "redis://localhost:6379/0")

  ## Extra options passed to Redis.new. Default: {}.
  # config.storage.redis_options = { timeout: 1 }

  ## === Background job backend (Sidekiq by default, or ActiveJob) ===

  ## Queue used by RubyReactor's async worker. Default: :default.
  # config.queue_name = :default

  ## Retry count for infrastructure failures only (deserialization, Redis,
  ## network). Step retries are managed separately. Default: 3.
  # config.job_retry_count = 3

  ## `sidekiq_queue` / `sidekiq_retry_count` still work as deprecated aliases
  ## for `queue_name` / `job_retry_count` above.

  ## === Contention snooze (locks / semaphores / rate limits / ordered locks) ===

  ## When a worker cannot acquire a primitive it re-enqueues itself with
  ## `lock_snooze_base_delay + rand(0..lock_snooze_jitter)` seconds (rate-limit
  ## uses a precise `retry_after_seconds` hint from the error; ordered-lock waits
  ## re-poll at the base delay so a successor catches its blocker finishing fast),
  ## up to `lock_snooze_max_attempts` times before marking the context :failed.
  ## Set max_attempts to :infinity to never give up.
  # config.lock_snooze_base_delay = 5
  # config.lock_snooze_jitter = 5
  # config.lock_snooze_max_attempts = 20

  ## === Durability & crash recovery (see "Durability & Recovery" below) ===

  ## Retention TTL (seconds) for stored reactor/map state. Must exceed your
  ## worst-case snooze/retry window; re-stamped on every write. Default: 86_400.
  # config.context_ttl = 86_400

  ## TTL (seconds) for the per-context liveness lock. A live worker auto-extends
  ## it; its absence is the sweeper's "worker died" signal. Must exceed the
  ## longest a single step can run without yielding the GIL. Default: 60.
  # config.context_lock_ttl = 60

  ## Minimum seconds between per-step checkpoints within one run. 0 = checkpoint
  ## after every step (strongest guarantee). Raise to coalesce mid-run writes for
  ## long reactors — only safe when steps are idempotent. Default: 0.
  # config.checkpoint_min_interval = 0

  ## Recovery sweeper (the chain is kicked once by `RubyReactor.start_sweeper!`).
  # config.sweeper_enabled = true    # run recovery by default
  # config.sweeper_interval = 30     # seconds between sweeps = recovery-latency bound
  # config.sweeper_limit = 1000      # max contexts/maps inspected per sweep

  ## === Misc ===

  ## Logger. Default: Logger.new($stdout).
  # config.logger = Logger.new($stdout)

  ## Async router. Default: RubyReactor::Adapters::Sidekiq::Router. Swap in the
  ## built-in ActiveJob adapter (see "Async Execution" below), or point at any
  ## custom adapter — it only needs to respond to
  ## `perform_async(context_id, reactor_class_name, **)`.
  # config.async_router = RubyReactor::Adapters::ActiveJob::Router

  ## === Examples (no default — set these to use the feature) ===

  ## Named rate limits shared across reactors. Reference with `with_rate_limit(:stripe)`.
  # config.rate_limits.register(:stripe, limits: { second: 3, minute: 100 })

  ## OpenTelemetry / custom middlewares. Default: [].
  # config.middlewares = [RubyReactor::OpenTelemetry]
end
```

You can also leave out the `configure` block entirely — defaults work for local development against a Redis on `localhost:6379`.

> **Crash recovery needs a kick.** The `sweeper_*` settings above only configure
> the recovery sweeper — they do not start it. Call `RubyReactor.start_sweeper!`
> once at boot (ideally from a worker-process startup hook — a Sidekiq
> `on(:startup)` hook, or a Rails initializer for ActiveJob) or no crashed
> reactor will ever resume. See [Durability & Recovery](#durability--recovery).


## Quick Start

```ruby
class HelloReactor < RubyReactor::Reactor
  step :greet do
    run { Success("Hello from Ruby Reactor!") }
  end
  returns :greet
end

result = HelloReactor.run
puts result.value  # => "Hello from Ruby Reactor!"
```

> **Note:** Examples in this README use inline `step` blocks where a step is trivial. For production workflows, prefer [class-based steps](#defining-steps).

## Defining Steps

RubyReactor supports two ways to define step logic:

| Style | Best for |
|-------|----------|
| **Class steps** (preferred) | Real business logic, compensation/undo, shared steps, testability |
| **Inline blocks** | Quick prototypes, trivial one-liners, documentation examples |

Whichever style you use, a step's `run` returns one of three signals — all exposed as bare helpers in both class steps and inline blocks:

- **`Success(value)`** — step succeeded; `value` flows to dependent steps.
- **`Failure(error)`** — step failed; the reactor rolls back completed steps (compensate/undo).
- **`Skipped(reason:)`** — clean halt: stop the reactor, keep partial progress, **no rollback**. See [Skipping a reactor cleanly](documentation/core_concepts.md#skipping-a-reactor-cleanly).

**Class steps** are plain Ruby classes that include `RubyReactor::Step` and implement `run`, and optionally `compensate` and `undo`:

```ruby
class ReserveInventoryStep
  include RubyReactor::Step

  def self.run(arguments, context)
    reservation_id = InventoryService.reserve(arguments[:order][:items])
    Success(reservation_id: reservation_id)
  end

  def self.compensate(error, arguments, context)
    InventoryService.release_partial(arguments[:order][:items])
    Success()
  end

  def self.undo(result, arguments, context)
    InventoryService.release(result[:reservation_id])
    Success()
  end
end

class OrderProcessingReactor < RubyReactor::Reactor
  step :reserve_inventory, ReserveInventoryStep do
    argument :order, result(:validate_order)
  end
end
```

**Why prefer class steps?**

- **Testability** — unit-test `run`, `compensate`, and `undo` in isolation without booting the whole reactor
- **Composability** — share the same step class across multiple reactors and compose larger workflows from small, focused units
- **Readability** — reactor files stay orchestration-only; business logic lives in named classes instead of growing inline blocks

See [Core Concepts — Step Classes](documentation/core_concepts.md#step-classes-preferred) for the full reference. Usage examples below mix class and inline steps — inline where the logic is trivial.

## Web Dashboard

RubyReactor ships with a built-in web dashboard to inspect reactor executions, view logs, and retry failed steps. The dashboard is a Rack app (a [Roda](https://roda.jeremyevans.net/) application) bundled inside the gem with its pre-compiled JS/CSS assets — no extra install or asset build step is required.

### Rails Installation

Add the gem to your `Gemfile`:

```ruby
gem "ruby_reactor"
```

Then mount the dashboard in your `config/routes.rb`:

```ruby
Rails.application.routes.draw do
  # ... other routes
  mount RubyReactor::Web::Application => "/ruby_reactor"
end
```

That's it — visit `/ruby_reactor` and the UI loads. `RubyReactor::Web::Application` is autoloaded by Zeitwerk on first reference, so no extra `require` is needed.

### Rack / Sinatra / Standalone

Because it's a plain Rack app, you can mount it anywhere `call(env)` is accepted:

```ruby
# config.ru
require "ruby_reactor/web/application"
run RubyReactor::Web::Application
```

![RubyReactor Dashboard Screenshot](documentation/images/failed_order_processing.png)

You can secure the dashboard using standard Rails authentication methods (e.g., wrapping the `mount` line in an `authenticate` block with Devise, or in a `constraints` block).

## Usage

RubyReactor allows you to define complex workflows as "reactors" with steps that can depend on each other, handle failures with compensations, and validate inputs. Examples in this section mix class steps with inline blocks; see [Defining Steps](#defining-steps) for guidance.

### Basic Example: User Registration

```ruby
require 'ruby_reactor'

class ValidateEmailStep
  include RubyReactor::Step

  def self.run(arguments, _context)
    email = arguments[:email]
    email&.include?('@') ? Success(email.strip) : Failure("Email must contain @")
  end
end

class CreateUserStep
  include RubyReactor::Step

  def self.run(arguments, _context)
    Success(
      id: rand(10000),
      email: arguments[:email],
      password_hash: arguments[:password_hash],
      created_at: Time.now
    )
  end

  def self.compensate(_error, arguments, _context)
    Notify.to(arguments[:email])
    Success()
  end
end

class UserRegistrationReactor < RubyReactor::Reactor
  input :email
  input :password

  step :validate_email, ValidateEmailStep do
    argument :email, input(:email)
  end

  step :hash_password do
    argument :password, input(:password)
    run do |args, _context|
      require 'digest'
      Success(Digest::SHA256.hexdigest(args[:password]))
    end
  end

  step :create_user, CreateUserStep do
    argument :email, result(:validate_email)
    argument :password_hash, result(:hash_password)
  end

  step :notify_user do
    argument :email, result(:validate_email)
    wait_for :create_user

    run do |args, _context|
      Email.send!(args[:email], "verify your email")
      Success()
    end

    compensate do |_error, args, _context|
      Email.send("support@acme.com", "Email verification for #{args[:email]} couldn't be sent")
      Success()
    end
  end

  returns :create_user
end

# Run the reactor
result = UserRegistrationReactor.run(
  email: 'alice@example.com',
  password: 'secret123'
)

if result.success?
  puts "User created: #{result.value[:email]}"
else
  puts "Failed: #{result.error}"
end
```

### Async Execution

Execute reactors in the background using Sidekiq or ActiveJob. The backend is
chosen via `config.async_router` (defaults to the Sidekiq adapter); to run on
ActiveJob instead:

```ruby
RubyReactor.configure do |config|
  config.async_router = RubyReactor::Adapters::ActiveJob::Router
end
```

That's the only switch — everything below (full-reactor async, step-level
async, durability, retries, snoozing) works identically on either backend.

#### Full Reactor Async

```ruby
class AsyncReactor < RubyReactor::Reactor
  background all: true # Entire reactor runs in background

  step :long_running_task do
    run { perform_heavy_work }
  end
end

# Returns immediately with AsyncResult
result = AsyncReactor.run(params)
```

#### Background Hand-off

A reactor can name **one** point where execution stops running in the caller's
process and is handed to a worker. Everything before it runs in the caller;
everything after it runs in a single background job. The cut point is nameable
from either side.

```ruby
class CreateUserReactor < RubyReactor::Reactor
  input :params

  step :validate_inputs do
    run { |args| validate(args[:params]) }
  end

  step :create_user do
    argument :params, result(:validate_inputs)
    run { |args| User.create(args[:params]) }
  end

  # :create_user is the LAST step to run in the calling process.
  # Equivalently here: `background before: :open_account`.
  background after: :create_user

  step :open_account do
    argument :user, result(:create_user)
    run { |args| Bank.open_account(args[:user]) }
  end

  step :report_new_user do
    argument :user, result(:create_user)
    wait_for :open_account
    run { |args| Analytics.track(args[:user]) }
  end
end

# Usage
def create(params)
  # Returns an AsyncResult immediately once :create_user completes
  result = CreateUserReactor.run(params)

  # Access synchronous results immediately
  user = result.intermediate_results[:create_user]

  # do something with user
end
```

`after: :x` guarantees `:x` runs in the calling process and is the last to do so.
`before: :x` guarantees `:x` runs in the worker and is the first to do so. They
coincide in a linear chain; **in a DAG they pin different steps**, so pick
whichever step you actually need pinned. Compensation is unchanged — `background`
changes where code runs, not the saga contract.

> **Breaking change:** the per-step `async true` flag has been **removed**. It was
> ambiguous — only the *first* flagged step in a reactor ever took effect and the
> rest were silently ignored — and it now raises at class-definition time. The
> exact replacement for a flagged step `:x` is `background before: :x`. The same
> applies to `async` inside a `compose` block.
>
> **Breaking change:** whole-reactor `async true` has also been **removed** — it
> named the same idea as `background`'s cut point with a different word, right next
> to `async_step`/`async_reactor`, whose names mean something else. It now raises
> at class-definition time. The exact replacement is `background all: true`.

#### `async_step`: one step, dispatched on its own

Where `background` relocates the *rest* of a reactor, `async_step` dispatches one
step's work to its own job while the reactor keeps running every other ready step.

```ruby
class SignupReactor < RubyReactor::Reactor
  input :email

  async_step :send_email do
    argument :to, input(:email)
    run { |args| Mailer.welcome(args[:to]).deliver_now; Success(:sent) }
  end

  # Does NOT wait — it has no dependency on :send_email.
  step :record_signup do
    argument :email, input(:email)
    run { |args| Success(Signup.create!(email: args[:email])) }
  end

  # DOES wait, because it reads the result.
  step :confirm_delivery do
    argument :delivery, result(:send_email)
    run { |args| Success("confirmed") }
  end
end
```

Reading `result(:send_email)` is what makes a step wait, and the wait is bounded
by `config.async_wait_timeout` (default 30s) — never unbounded. On success the
reader gets the raw value; on failure it gets the `Failure` **object**, so it can
inspect it and decide.

**Compensation is opt-in.** If a dispatched step fails and nothing reads its
result, the reactor is not compensated — it was dispatched precisely so the
reactor would not depend on it. A reader that returns `Failure` triggers
compensation normally.

#### `async_reactor`: a whole nested reactor, running independently

```ruby
class SignupReactor < RubyReactor::Reactor
  input :user_id

  # Fire-and-forget: nothing reads it, so its failure never affects this reactor.
  async_reactor :backfill_profile, ProfileBackfillReactor do
    argument :user_id, input(:user_id)
  end

  async_reactor :provision_account, AccountProvisioningReactor do
    argument :user_id, input(:user_id)
  end

  step :verify do
    argument :account, result(:provision_account)   # waits for the child
    run do |args|
      args[:account].success? ? Success(args[:account].value) : Failure(args[:account].error)
    end
  end
end
```

The child is an ordinary, independently addressable execution, linked to the
parent by execution id (drillable in the dashboard) but excluded from its
compensation graph. Reach for `compose` instead when the child belongs to this
unit of work — its result is available immediately and its failure rolls the
parent back.

Lock ownership is never shared across the async boundary: a child declaring a key
the parent holds fails at dispatch with an explanatory error rather than
deadlocking. See [Async Reactors](documentation/async_reactors.md) for the full
rules.

### Durability & Recovery

Async reactors are durable: state lives in Redis, not in the job payload. Before
any background job is enqueued the root context is persisted, and after every
completed step a checkpoint advances the stored blob — so a crash re-runs at most
one step, never the whole reactor. Each running reactor also holds a short
**liveness lock** that a live worker auto-extends; its absence is how a dead
worker is detected.

**Recovery is not automatic until you start the sweeper.** A crashed worker's
reactor only resumes when the recovery sweeper notices the lapsed liveness lock
and re-enqueues it. The sweeper is a self-rescheduling chain — **kick it once per
process boot:**

The recommended spot is a worker-process startup hook, so only the worker
process runs recovery (not your web/console/client processes). On Sidekiq:

```ruby
# config/initializers/sidekiq.rb
Sidekiq.configure_server do |config|
  config.on(:startup) { RubyReactor.start_sweeper! }
end
```

ActiveJob has no equivalent server-only hook — call it from wherever your
queue adapter's worker process boots (e.g. `bin/jobs` for Solid Queue, or a
dedicated initializer guarded by an env var so it doesn't also run in web
processes):

```ruby
# config/initializers/ruby_reactor.rb
RubyReactor.start_sweeper! if ENV["RUBY_REACTOR_WORKER"]
```

Anywhere that runs once at boot works too (idempotent, so it's safe even if
every process calls it) — e.g. an unconditional Rails initializer:

```ruby
# config/initializers/ruby_reactor.rb
RubyReactor.start_sweeper!
```

That's all that's required: `start_sweeper!` is idempotent (safe to call on every
boot — duplicate kicks collapse to one chain), runs both the top-level reactor
sweeper and the map sweeper every `config.sweeper_interval` seconds, and stops if
you set `config.sweeper_enabled = false`. The interval is your recovery-latency
bound.

> **Sidekiq Enterprise `super_fetch` compatibility:** the chain is safe under
> reliable fetch. `super_fetch` re-runs a job whose worker died mid-execution, so
> a tick that crashes *after* enqueuing its successor but *before* acking would,
> with naive single-flight, be recovered alongside that successor and fork the
> chain (doubling every interval). RubyReactor avoids this: it never relies on
> "one job in the chain" — each next tick is claimed by a per-time-window lock, so
> a `super_fetch`-recovered tick computes the same window, loses the claim, and
> collapses back to a single successor. The startup hook above is likewise
> idempotent across multiple `super_fetch` server processes.

**Prefer your own scheduler?** Set `config.sweeper_enabled = false` (which makes
`start_sweeper!` a no-op) and drive recovery from cron, a Kubernetes `CronJob`,
`sidekiq-cron`, `sidekiq-scheduler`, or Rails recurring tasks. Each tick is one
call:

```ruby
RubyReactor.sweep_once # => { reactors: <n re-enqueued>, maps: <n recovered> }
```

For example, a rake task a system cron / CronJob can invoke:

```ruby
# lib/tasks/ruby_reactor.rake
namespace :ruby_reactor do
  task sweep: :environment do
    RubyReactor.sweep_once
  end
end
```

### Interrupts (Pause & Resume)

Pause execution to wait for external events like webhooks or user approvals.

```ruby
class ApprovalReactor < RubyReactor::Reactor
  step :submit_request do
    run { |args| RequestService.submit(args) }
  end

  interrupt :wait_for_manager do
    wait_for :submit_request
    # Resume using this ID
    correlation_id { |ctx| "req-#{ctx.result(:submit_request)[:id]}" }
  end

  step :process_decision do
    argument :decision, result(:wait_for_manager)
    run do |args| 
      args[:decision] == 'approved' ? Success() : Failure("Rejected")
    end
  end
end

# Usage:
# 1. Start execution
execution = ApprovalReactor.run(params) # => Returns Paused status

# 2. Later, resume it via correlation ID
ApprovalReactor.continue_by_correlation_id(
  correlation_id: "req-123",
  payload: "approved",
  step_name: :wait_for_manager
)
```

### Locks, Semaphores & Ordered Locks

Coordinate across processes with Redis-backed primitives:

- **`with_lock`** — at-most-one runner per key at a time (concurrency control).
- **`with_semaphore`** — cap total concurrent runners per key (capacity control).
- **`with_rate_limit`** — fixed-window rate limit, single or multi-window ("3/sec AND 100/min"). Inline per-reactor, or reference a named limit registered once in `RubyReactor.configure` and shared across reactors.
- **`with_period`** — run at most once per calendar bucket (dedup / once-per-day, once-per-month, etc).
- **`with_ordered_lock`** — strict transaction ordering via a monotonically increasing nonce assigned at enqueue. Workers can only proceed when their nonce equals `last_completed + 1`.

```ruby
class RefundOrderReactor < RubyReactor::Reactor
  input :order_id

  # Only one refund per order at a time. Auto-extend keeps the TTL fresh while
  # the reactor runs, so long steps cannot let the lock expire mid-flight.
  with_lock(ttl: 60) { |inputs| "order:#{inputs[:order_id]}" }

  step :refund do
    argument :order_id, input(:order_id)
    run { |args| PaymentGateway.refund(args[:order_id]) }
  end
end

class GeocodeReactor < RubyReactor::Reactor
  input :address

  # At most 5 geocode calls in flight across the fleet.
  with_semaphore(limit: 5) { |inputs| "geocode_api" }

  step :geocode do
    argument :address, input(:address)
    run { |args| Geocoder.lookup(args[:address]) }
  end
end

class MonthlyBillingReactor < RubyReactor::Reactor
  input :org_id

  # Run at most once per UTC month per org. Subsequent calls in the same month
  # return RubyReactor::Skipped without executing any step. Pair with
  # with_lock for strict at-most-one even under concurrent racers.
  with_period(every: :month) { |inputs| "monthly_billing:#{inputs[:org_id]}" }

  step :build do
    argument :org_id, input(:org_id)
    run { |args| Billing.generate(args[:org_id]) }
  end
end

class ChargeReactor < RubyReactor::Reactor
  input :account_id

  # Respect upstream Stripe rate limits: 3/sec and 100/min.
  # Async workers snooze for exactly retry_after seconds instead of
  # consuming the backend's retry budget.
  with_rate_limit(
    limits: { second: 3, minute: 100 }
  ) { |inputs| "stripe:#{inputs[:account_id]}" }

  step :charge do
    argument :account_id, input(:account_id)
    run { |args| Stripe.charge(args[:account_id]) }
  end
end

class OrderedTransactionReactor < RubyReactor::Reactor
  async
  input :account_id
  input :transaction

  # Strict order: a monotonically increasing nonce is assigned at enqueue
  # time (inside `Reactor.run`). Workers only execute when their nonce
  # equals last_completed + 1; otherwise they snooze. After the sequence
  # fully drains the counter resets to 0.
  with_ordered_lock(poison_pill_timeout: 300) { |inputs| "txs:#{inputs[:account_id]}" }

  step :apply do
    argument :transaction, input(:transaction)
    run { |args| Ledger.apply(args[:transaction]) }
  end
end

# Caller-side order is preserved; the worker pool may pick jobs in any order
# but the gate enforces sequential execution per key.
[tx1, tx2, tx3].each { |tx| OrderedTransactionReactor.run(account_id: 42, transaction: tx) }
```

**Named global limits.** When several reactors hit the same external service, register the limit once and reference it by name. The name is the shared key base, so every reactor throttles against one bucket:

```ruby
RubyReactor.configure do |config|
  config.rate_limits.register(:stripe, limits: { second: 3, minute: 100 })
  config.rate_limits.register(:twilio, limit: 10, period: :second)
end

class ChargeReactor < RubyReactor::Reactor
  input :account_id

  with_rate_limit(:stripe)   # shared :stripe quota across every reactor

  step :charge do
    argument :account_id, input(:account_id)
    run { |args| Stripe.charge(args[:account_id]) }
  end
end
```

Referencing an unregistered name raises `RubyReactor::RateLimitRegistry::UnknownLimitError`. Named limits hit the same enforcement path as inline ones, so async snooze behavior is identical.

On contention:

- **Inline** (`Reactor.run`) raises `RubyReactor::Lock::AcquisitionError` / `RubyReactor::Semaphore::AcquisitionError` / `RubyReactor::RateLimit::ExceededError` / `RubyReactor::OrderedLock::WaitError`.
- **Async** (Sidekiq or ActiveJob) snoozes the job via `perform_in(delay, ...)`. For rate limits the delay uses the error's `retry_after_seconds` hint (precise wakeup — the bucket roll time is known exactly); for locks, semaphores, and ordered-lock waits it's `lock_snooze_base_delay + jitter` (a short re-poll, since a held lock or a live blocker nonce typically clears in milliseconds). Snoozes do not count against the backend's retry budget. After `lock_snooze_max_attempts` snoozes the context is marked failed (ordered-lock waits bypass the cap — see the ordered-lock docs).

On dedup hits (period gate already marked), the reactor returns a `RubyReactor::Skipped` result instead — no steps run, no exception:

```ruby
result = MonthlyBillingReactor.run(org_id: 42)
result.success?  # true (Skipped is a Success subclass)
result.skipped?  # true on dedup hit, false otherwise
```

A step's `run` block can also return `Skipped(reason: "...")` to halt the reactor cleanly — remaining steps don't execute, **and already-completed steps are NOT compensated**. Use it when the rest of the workflow is unnecessary and partial progress should be kept (`Failure` is for "stop and roll back"). `Skipped` is a bare helper just like `Success`/`Failure` (or use the fully-qualified `RubyReactor.Skipped(...)`).

```ruby
step :ensure_active do
  argument :user, result(:fetch_user)
  run do |args, _ctx|
    next Skipped(reason: "user_opted_out") if args[:user].opted_out?
    Success(args[:user])
  end
end
```

See [Locks, Semaphores, Rate Limits, Periods & Ordered Locks](documentation/locks_and_semaphores.md) for re-entrancy, auto-extend, multi-window quotas, bucket semantics, owner identity, snooze tuning, ordered-lock assignment + poison-pill semantics, and operational notes.

### Map & Parallel Execution

Process collections in parallel using the `map` step:

```ruby
class DataProcessingReactor < RubyReactor::Reactor
  input :items

  map :process_items do
    source input(:items)
    argument :item, element(:process_items)
    
    # Enable async execution with batching
    async true, batch_size: 50

    step :transform do
      argument :item, input(:item)
      run { |args| transform_item(args[:item]) }
    end

    returns :transform
  end
end
```

By using `async true` with `batch_size`, the system applies **Back Pressure** to efficiently manage resources. [Read more about Back Pressure & Resource Management](documentation/data_pipelines.md#back-pressure--resource-management).

`batch_size` is optional: with `async true` alone, RubyReactor fans out one worker per element (defaulting the batch size to the full source size) and aggregates the outcomes into a `ResultEnumerator` — convenient for small collections, but with no back pressure. See [Async Without `batch_size`](documentation/data_pipelines.md#async-without-batch_size).

#### Map with Dynamic Source (ActiveRecord)

You can use a block for `source` to dynamically fetch data, such as from ActiveRecord queries. The result is wrapped in a `ResultEnumerator` for easy access to successes and failures.

```ruby
map :archive_old_users do
  argument :days, input(:days)

  # Dynamic source using ActiveRecord
  source do |args|
    User.where("last_login_at < ?", args[:days].days.ago)
  end
  
  argument :user, element(:archive_old_users)
  async true, batch_size: 100

  step :archive do
    argument :user, input(:user)
    run { |args| args[:user].archive! }
  end
  
  returns :archive
end

step :summary do
  argument :results, result(:archive_old_users)
  run do |args|
    puts "Archived: #{args[:results].successes.count}"
    puts "Failed: #{args[:results].failures.count}"
    Success()
  end
end
```

### Input Validation

RubyReactor integrates with dry-validation for input validation. A single
`input` method escalates from a bare declaration to a full nested schema.
Name and optionality are declared once.

**Form 0 — declaration only** (no validation, value passes through as-is):

```ruby
input :user
input :payload, redact: true
```

**Form 1 — inline scalar** (the common case). The type is an optional
positional; any keyword ending in `?` is a dry-schema predicate:

```ruby
input :name,  :string,  min_size?: 2
input :email, :string,  format?: /\A[^@\s]+@[^@\s]+\z/
input :age,   :integer, gteq?: 18

# optional: true flips required(...).filled -> optional(...).maybe
input :bio,   :string,  optional: true, max_size?: 100
```

**Form 1b — class / module** maps to a `type?` instance check:

```ruby
input :user,  User                 # required(:user).filled(type?: User)
input :items, Array, min_size?: 1  # instance check + predicate
```

**Form 2 — macro block** for nested / complex schemas. The block receives the
input's macro (already bound to the name and optionality), and because it is a
block argument your class constants and helpers stay reachable:

```ruby
EMAIL = /\A[^@\s]+@[^@\s]+\z/

input :order do |i|
  i.hash do
    required(:customer).hash do
      required(:email).filled(:string, format?: EMAIL)
    end
    required(:items).each do
      schema { required(:product_id).filled(:string) }
    end
  end
end
```

**Form 3 — pre-built schema / contract** (also the home for coercing dry-types):

```ruby
UserSchema = Dry::Schema.Params do
  required(:user).hash { required(:email).filled(:string) }
end

input :user, validate: UserSchema
```

Putting the inline forms together:

```ruby
class ValidatedUserReactor < RubyReactor::Reactor
  input :name,  :string,  min_size?: 2
  input :email, :string
  input :age,   :integer, gteq?: 18
  input :bio,   :string,  optional: true, max_size?: 100

  step :create_profile do
    argument :name, input(:name)
    argument :email, input(:email)
    argument :age, input(:age)
    argument :bio, input(:bio)

    run do |args, context|
      profile = {
        name: args[:name],
        email: args[:email],
        age: args[:age],
        bio: args[:bio] || "No bio provided",
        created_at: Time.now
      }
      Success(profile)
    end
  end

  returns :create_profile
end

# Valid input
result = ValidatedUserReactor.run(
  name: "Alice Johnson",
  email: "alice@example.com",
  age: 25,
  bio: "Software developer"
)

# Invalid input - will return validation errors
result = ValidatedUserReactor.run(
  name: "A",  # Too short
  email: "",  # Empty
  age: 15     # Too young
)
```

All validation failures — inputs, step arguments, step output, and interrupt
payloads — surface uniformly as a `RubyReactor::Error::InputValidationError`
with a `field_errors` hash:

```ruby
result = ValidatedUserReactor.run(name: "A")
result.error                       # => RubyReactor::Error::InputValidationError
result.error.field_errors[:name]   # => "size cannot be less than 2"
```

### Step Argument & Output Validation

Arguments can be validated inline using the same forms as `input`. Inline rules
compose with a `validate_args` block (used for cross-field rules):

```ruby
step :charge do
  argument :amount,   input(:amount),   :decimal, gt?: 0
  argument :currency, input(:currency), :string,  included_in?: %w[USD EUR GBP]
  argument :user,     input(:user),     User              # type? instance check

  # Optional cross-field block (composes with the inline rules above)
  validate_args do
    required(:amount).filled(:decimal, lt?: 10_000)
  end

  run { |args, _| charge!(args) }
end
```

Output validation is scalar-aware — pass a type/predicates for a single value,
or a block for a hash output:

```ruby
validate_output :integer, gteq?: 0   # scalar return value
validate_output do                   # hash return value
  required(:id).filled(:string)
end
```

### Interrupt Payload Validation

Validate the payload supplied on resume with `validate_payload` (the older
`validate` is kept as a deprecated alias):

```ruby
interrupt :await_approval do
  wait_for :submit_request

  validate_payload do
    required(:approved).filled(:bool)
    optional(:note).maybe(:string)
  end
end
```

### Complex Workflows with Dependencies

Steps can depend on results from multiple other steps:

```ruby
class OrderProcessingReactor < RubyReactor::Reactor
  input :user_id
  input :product_ids, Array, min_size?: 1

  step :validate_user do
    argument :user_id, input(:user_id)

    run do |args, context|
      # Check if user exists and has permission to purchase
      user = find_user(args[:user_id])
      user ? Success(user) : Failure("User not found")
    end
  end

  step :validate_products do
    argument :product_ids, input(:product_ids)

    run do |args, context|
      products = args[:product_ids].map { |id| find_product(id) }
      if products.all?
        Success(products)
      else
        Failure("Some products not found")
      end
    end
  end

  step :calculate_total do
    argument :products, result(:validate_products)

    run do |args, context|
      total = args[:products].sum { |p| p[:price] }
      Success(total)
    end
  end

  step :check_inventory do
    argument :products, result(:validate_products)

    run do |args, context|
      available = args[:products].all? { |p| p[:stock] > 0 }
      available ? Success(true) : Failure("Out of stock")
    end
  end

  step :process_payment do
    argument :user, result(:validate_user)
    argument :total, result(:calculate_total)

    run do |args, context|
      # Process payment logic here
      payment_id = process_payment(args[:user][:id], args[:total])
      Success(payment_id)
    end

    undo do |error, args, context|
      # Refund payment on failure
      refund_payment(args[:payment_id])
      Success()
    end
  end

  step :create_order do
    argument :user, result(:validate_user)
    argument :products, result(:validate_products)
    argument :payment_id, result(:process_payment)

    run do |args, context|
      order = create_order_record(args[:user], args[:products], args[:payment_id])
      Success(order)
    end

    undo do |error, args, context|
      # Cancel order and update inventory
      cancel_order(args[:order][:id])
      Success()
    end
  end

  step :update_inventory do
    argument :products, result(:validate_products)

    run do |args, context|
      args[:products].each { |p| decrement_stock(p[:id]) }
      Success(true)
    end

    undo do |error, args, context|
      # Restock products
      args[:products].each { |p| increment_stock(p[:id]) }
      Success()
    end
  end

  step :send_confirmation do
    argument :user, result(:validate_user)
    argument :order, result(:create_order)

    run do |args, context|
      send_email(args[:user][:email], "Order confirmed", order_details(args[:order]))
      Success(true)
    end
  end

  returns :send_confirmation
end
```

### Error Handling and Compensation

When a step fails, RubyReactor automatically undoes completed steps in reverse order, compensate only runs in the failing step and backwalks the executed steps undo blocks:

```ruby
class TransactionReactor < RubyReactor::Reactor
  input :from_account
  input :to_account
  input :amount

  step :validate_accounts do
    argument :from_account, input(:from_account)
    argument :to_account, input(:to_account)

    run do |args, context|
      from = find_account(args[:from_account])
      to = find_account(args[:to_account])

      if from && to && from != to
        Success({from: from, to: to})
      else
        Failure("Invalid accounts")
      end
    end
  end

  step :check_balance do
    argument :accounts, result(:validate_accounts)
    argument :amount, input(:amount)

    run do |args, context|
      if args[:accounts][:from][:balance] >= args[:amount]
        Success(args[:accounts])
      else
        Failure("Insufficient funds")
      end
    end
  end

  step :debit_account do
    argument :accounts, result(:check_balance)
    argument :amount, input(:amount)

    run do |args, context|
      debit(args[:accounts][:from][:id], args[:amount])
      Success(args[:accounts])
    end

    undo do |error, args, context|
      # Credit the amount back
      credit(args[:accounts][:from][:id], args[:amount])
      Success()
    end
  end

  step :credit_account do
    argument :accounts, result(:debit_account)
    argument :amount, input(:amount)

    run do |args, context|
      credit(args[:accounts][:to][:id], args[:amount])
      Success({transaction_id: generate_transaction_id()})
    end

    undo do |error, args, context|
      # Debit the amount back from recipient
      debit(args[:accounts][:to][:id], args[:amount])
      Success()
    end
  end

  step :notify do
    argument :accounts, result(:validate_accounts)
    wait_for :credit_account, :debit_account

    run do |args, context|
      Notify.to(args[:accounts][:from])
      Notify.to(args[:accounts][:to])
    end
     
  end

  returns :credit_account
end

# If credit_account fails, RubyReactor will:
# 1. Compensate credit_account (debit the recipient)
# 2. Undo debit_account (credit the sender)
# Result: Complete rollback of the transaction
```

### Using Pre-defined Schemas

You can use existing dry-validation schemas:

```ruby
require 'dry/schema'

user_schema = Dry::Schema.Params do
  required(:user).hash do
    required(:name).filled(:string, min_size?: 2)
    required(:email).filled(:string)
    optional(:phone).maybe(:string)
  end
end

class SchemaValidatedReactor < RubyReactor::Reactor
  input :user, validate: user_schema

  step :process_user do
    argument :user, input(:user)

    run do |args, context|
      Success(args[:user])
    end
  end

  returns :process_user
end
```

### Testing

RubyReactor provides testing utilities for RSpec. See the [Testing with RSpec](documentation/testing.md) guide for comprehensive documentation — including [unit-testing class-based steps](documentation/testing.md#testing-step-classes) directly.

```ruby
RSpec.describe PaymentReactor do
  it "processes payment successfully" do
    subject = test_reactor(PaymentReactor, order_id: 123, amount: 99.99)
    
    expect(subject).to be_success
    expect(subject).to have_run_step(:charge_card).after(:validate_order)
    expect(subject.step_result(:charge_card)).to include(status: "completed")
  end

  it "handles payment failures with mocked steps" do
    subject = test_reactor(PaymentReactor, order_id: 123, amount: 99.99)
      .mock_step(:charge_card) { Failure("Card declined") }
    
    expect(subject).to be_failure
    expect(subject.error).to include("Card declined")
  end
end
```

## Documentation

For detailed documentation, see the following guides:

### [Core Concepts](documentation/core_concepts.md)
Learn about the fundamental building blocks of RubyReactor: Reactors, Steps, Context, and Results. Covers class-based steps (the preferred approach) and inline blocks, how data flows between steps, and how the context maintains state throughout execution.

### [DAG (Directed Acyclic Graph)](documentation/DAG.md)
Deep dive into how RubyReactor manages dependencies. This guide explains how the Directed Acyclic Graph is constructed to ensure steps execute in the correct topological order, enabling automatic parallelization of independent steps.

### [Async Reactors](documentation/async_reactors.md)
Explore the ways to move work off the calling process: Full Reactor Async, the `background` hand-off, `async_step`, and `async_reactor`. Learn how RubyReactor leverages Sidekiq or ActiveJob for background processing, non-blocking execution, and scalable worker management.

### [Composition](documentation/composition.md)
Discover how to build complex, modular workflows by composing reactors within other reactors. This guide covers inline composition, class-based composition, and how to manage dependencies between composed workflows.

### [Data Pipelines](documentation/data_pipelines.md)
Master the `map` feature for processing collections. Learn about parallel execution, batch processing for large datasets, and error handling strategies like fail-fast vs. partial result collection.

### [Retry Configuration](documentation/retry_configuration.md)
Configure robust retry policies for your steps. This guide details the available backoff strategies (exponential, linear, fixed), how to configure retries at the reactor or step level, and how async retries work without blocking workers.

### [Interrupts](documentation/interrupts.md)
Learn how to pause and resume reactors to handle long-running processes, manual approvals, and asynchronous callbacks. Patterns for correlation IDs, timeouts, and payload validation.

### [Testing with RSpec](documentation/testing.md)
Comprehensive guide to testing reactors with RubyReactor's testing utilities. Learn about the `TestSubject` class for reactor execution and introspection, step mocking for isolating dependencies, testing nested and composed reactors, and custom RSpec matchers like `be_success`, `have_run_step`, and `have_retried_step`.

### [Locks, Semaphores, Rate Limits, Periods & Ordered Locks](documentation/locks_and_semaphores.md)

Coordinate access to shared resources across processes with Redis-backed primitives: exclusive locks (`with_lock`), concurrency-limiting semaphores (`with_semaphore`), fixed-window rate limits with multi-window quotas (`with_rate_limit`), calendar-bucketed dedup (`with_period`, returning `Skipped` results), and strict sequential ordering via a monotonically increasing nonce assigned at enqueue (`with_ordered_lock`). Covers re-entrancy across composed reactors, TTL auto-extend, inline-vs-async contention behavior, smart `retry_after` snoozes for rate limits, snooze tuning, the token-based semaphore safety model, once-per-day/month/year scheduling patterns, ordered-lock counter reset on drain, poison-pill timeouts, and deadlock-safe composition rules.

### [Middlewares & OpenTelemetry](documentation/middlewares.md)

Hook into the execution lifecycle with observer middlewares. Covers the full set of lifecycle events (reactor, step, retry, compensation/undo, async hand-off, locks/semaphores), writing and registering custom middlewares (global and per-reactor), and the built-in `RubyReactor::OpenTelemetry` tracing middleware — span structure, input/argument redaction, distributed trace propagation across async/retry boundaries, and custom exporters.

### Examples
- [Order Processing](documentation/examples/order_processing.md) - Complete order processing workflow example
- [Payment Processing](documentation/examples/payment_processing.md) - Payment handling with compensation
- [Inventory Management](documentation/examples/inventory_management.md) - Inventory management system example

## Future improvements

- [X] Global id to serialize ActiveRecord classes
- [X] Descriptive errors
- [X] `map` step to iterate over arrays in parallel
- [X] `compose` special step to execute reactors as step
- [X] `interrupt` to pause and resume reactors
- [X] Middlewares
- [ ] Async ruby to parallelize same level steps
- [x] Web dashboard to inspect reactor results and errors
- [ ] Multiple storage adapters
  - [X] Redis
  - [ ] ActiveRecord
- [X] Multiple Async adapters
  - [X] Sidekiq
  - [X] ActiveJob
- [X] OpenTelemetry support
- [X] locks

## Development

After checking out the repo, run `bin/setup` to install dependencies. Then, run `rake spec` to run the tests. You can also run `bin/console` for an interactive prompt that will allow you to experiment.

To install this gem onto your local machine, run `bundle exec rake install`. To release a new version, update the version number in `version.rb`, and then run `bundle exec rake release`, which will create a git tag for the version, push git commits and the created tag, and push the `.gem` file to [rubygems.org](https://rubygems.org).

### Running Redis for the test suite

The gem's RSpec suite expects Redis on port `6780` (see [spec/spec_helper.rb](spec/spec_helper.rb)). Start it via Docker Compose:

```bash
docker compose up -d redis-test
```

Then run the suite:

```bash
bundle exec rspec
```

Stop it when done:

```bash
docker compose stop redis-test
```

### Running the demo Rails app

The demo Rails app under [demo_app/](demo_app/) has its own Redis (port `6380`) and bind-mounts the repo so edits to `lib/` are live. Two ways to run it:

**Option A — fully containerized (Redis + Rails + Sidekiq):**

```bash
docker compose up demo-redis demo-app demo-sidekiq
```

App available at <http://localhost:3789>.

**Option B — Redis in Docker, Rails on host:**

```bash
docker compose up -d demo-redis

cd demo_app
bin/rails db:prepare
REDIS_URL=redis://localhost:6380/1 bin/rails server
# in another shell, if you need Sidekiq:
REDIS_URL=redis://localhost:6380/1 bundle exec sidekiq
```

To run the demo app specs:

```bash
cd demo_app
bundle exec rspec
```

Tear everything down:

```bash
docker compose down          # stop containers
docker compose down -v       # also remove demo_redis_data + bundle_cache volumes
```

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/arturictus/ruby_reactor. This project is intended to be a safe, welcoming space for collaboration, and contributors are expected to adhere to the [code of conduct](https://github.com/arturictus/ruby_reactor/blob/main/CODE_OF_CONDUCT.md).

## Code of Conduct

Everyone interacting in the RubyReactor project's codebases, issue trackers, chat rooms and mailing lists is expected to follow the [code of conduct](https://github.com/arturictus/ruby_reactor/blob/main/CODE_OF_CONDUCT.md).
