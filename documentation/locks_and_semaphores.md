# Locks & Semaphores

RubyReactor ships with **distributed exclusive locks** and **distributed semaphores** backed by Redis. They let a reactor coordinate access to a shared resource across processes — without dragging in a separate locking library.

A typical use case:

- Only one `RefundOrderReactor` should run per order at a time → exclusive lock keyed by order id.
- Calls to a rate-limited external API should never exceed 5 concurrent requests → semaphore with `limit: 5`.

Both primitives:

- Are acquired before any step runs and released in an `ensure` block (so a crash, failure, or interrupt does not leak a holder).
- Snooze (re-enqueue) instead of fail when contention is encountered inside a Sidekiq worker.
- Carry a TTL so a crashed Ruby process cannot block the resource forever.

## Table of Contents

- [Exclusive Locks](#exclusive-locks)
  - [Re-entrancy](#re-entrancy)
  - [Auto-extend (TTL keepalive)](#auto-extend-ttl-keepalive)
  - [Inline vs async behavior on contention](#inline-vs-async-behavior-on-contention)
  - [Owner identity](#owner-identity)
- [Semaphores](#semaphores)
  - [Token model](#token-model)
  - [Release safety](#release-safety)
- [Snooze configuration](#snooze-configuration)
- [Inheritance](#inheritance)
- [Observability](#observability)
- [Limitations](#limitations)

## Exclusive Locks

Declare an exclusive lock on a reactor with the `with_lock` DSL. The block receives the reactor inputs and must return the **lock key** as a string.

```ruby
class RefundOrderReactor < RubyReactor::Reactor
  input :order_id

  with_lock(ttl: 60) { |inputs| "order:#{inputs[:order_id]}" }

  step :refund do
    argument :order_id, input(:order_id)
    run { |args| PaymentGateway.refund(args[:order_id]) }
  end
end
```

While the reactor is running, every other caller trying to acquire `lock:order:<id>` either snoozes (async) or raises `RubyReactor::Lock::AcquisitionError` (inline).

### Re-entrancy

Composed reactors share the same lock owner, so they can re-acquire a lock that an outer reactor already holds without blocking themselves:

```ruby
class InventoryReactor < RubyReactor::Reactor
  with_lock { |inputs| "warehouse:#{inputs[:warehouse_id]}" }

  compose :stock_check, StockCheckReactor   # also locks "warehouse:<id>"
end
```

Re-entrancy is owner-based — a sibling process trying to grab `warehouse:<id>` while `InventoryReactor` runs will still be blocked. See [Owner identity](#owner-identity) for what counts as "the same owner."

### Auto-extend (TTL keepalive)

Long-running steps can outlive the `ttl` you pick. To prevent the lock from expiring mid-execution, RubyReactor **auto-extends** locks by default: a background thread refreshes the TTL every `ttl / 3` seconds (minimum 1s) while the reactor runs, and stops on release.

```ruby
# Default: keepalive enabled
with_lock(ttl: 60) { |i| "k:#{i[:id]}" }

# Disable if you trust ttl to outlast every step
with_lock(ttl: 60, auto_extend: false) { |i| "k:#{i[:id]}" }
```

If the Ruby process dies, the extender dies with it, so the TTL still kicks in and the lock becomes acquirable again.

### Inline vs async behavior on contention

The behavior on a "lock already held" condition depends on **where** the reactor is running:

| Caller                | Behavior on contention                                                                                          |
| --------------------- | --------------------------------------------------------------------------------------------------------------- |
| Inline (`Reactor.run`) | Raises `RubyReactor::Lock::AcquisitionError`. The caller decides whether to retry, switch to async, or give up. |
| Sidekiq worker        | Snoozes the job via `perform_in(delay, ...)`. **Does not** consume the Sidekiq retry budget.                    |

The async path also force-disables `wait:` (no `sleep`/BLPOP inside a worker thread) — better to snooze the job than to tie up a worker.

After `lock_snooze_max_attempts` snoozes, the worker stops re-enqueuing and marks the context as failed. See [Snooze configuration](#snooze-configuration).

```ruby
# Inline error handling
begin
  RefundOrderReactor.run(order_id: 42)
rescue RubyReactor::Lock::AcquisitionError
  # Someone else is refunding this order; surface a 409, retry later, or hand
  # off to async:
  RubyReactor::SidekiqWorkers::Worker.perform_async(...)
end
```

### Owner identity

The lock owner is the **root context id** of the currently-executing reactor — meaning every reactor *invocation* is its own owner, but every composed/nested reactor inside that invocation shares the owner.

Two implications:

- A user-triggered retry that creates a new top-level run has a **new** owner. If the previous run's lock has not expired yet (e.g. process crashed without auto-extend), the retry will see contention.
- Across the async pause/resume boundary, the lock is released on pause and re-acquired on resume — a separate runner can sneak in between. Lean on `ttl` and idempotency to make this safe.

## Semaphores

A semaphore caps **concurrent executions** of a reactor across processes. Declare one with `with_semaphore`:

```ruby
class GeocodeReactor < RubyReactor::Reactor
  input :address

  with_semaphore(limit: 5) { |inputs| "geocode_api" }

  step :geocode do
    argument :address, input(:address)
    run { |args| Geocoder.lookup(args[:address]) }
  end
end
```

At any time, at most five `GeocodeReactor` invocations run concurrently across your fleet. The 6th call snoozes (async) or raises `RubyReactor::Semaphore::AcquisitionError` (inline).

### Token model

Internally a semaphore is a Redis `LIST` of unique UUID tokens plus a `SET` tracking which tokens are currently held:

- `semaphore:<key>` — LIST of available token UUIDs.
- `semaphore:<key>:held` — SET of UUIDs currently checked out.
- `semaphore:<key>:init` — initialization sentinel (value = `limit`).

`acquire` does an atomic `LPOP + SADD` (Lua). `release` does a guarded `SREM + RPUSH` (Lua) so a token is only returned to the pool if the caller actually held it.

### Release safety

The release script enforces two invariants:

1. The token must be in `:held` (no spurious releases for tokens that were never acquired).
2. After release, the list size cannot exceed `limit` (no over-cap RPUSH).

This means a buggy double-release, a stale token from a crashed process, or a forged release attempt cannot inflate the pool beyond its configured capacity.

## Snooze configuration

When a Sidekiq worker hits contention it re-enqueues itself after a small delay. Three knobs on `RubyReactor.configuration` control this:

```ruby
RubyReactor.configure do |config|
  # Base seconds before the worker re-checks contention.
  config.lock_snooze_base_delay = 5

  # Extra random seconds added on top to avoid thundering herd
  # (delay = base + rand(0..jitter)).
  config.lock_snooze_jitter = 5

  # Maximum snoozes per job. After this, the context is marked :failed
  # and no more reschedules happen. Set to :infinity to never give up.
  config.lock_snooze_max_attempts = 20
end
```

The current snooze count is tracked as a positional arg on the Sidekiq job, so it survives reschedules but stays per-job (parallel jobs don't share a counter).

## Inheritance

Lock and semaphore config defined on a reactor are propagated to subclasses:

```ruby
class BaseRefund < RubyReactor::Reactor
  with_lock { |i| "order:#{i[:order_id]}" }
  # ...
end

class FullRefund < BaseRefund   # also locks "order:<id>"
end
```

A subclass can call `with_lock` / `with_semaphore` again to override the inherited configuration.

## Observability

- Snooze escalation, release failures, and "release on something we did not actually hold" conditions are logged via `RubyReactor.configuration.logger.warn`.
- The current owner of a lock is in the Redis hash `lock:<key>` under field `owner`.
- The held-tokens set for a semaphore is `semaphore:<key>:held`. Its cardinality plus `LLEN semaphore:<key>` should always equal `limit` at rest.

## Limitations

- **Step-level locking** is not yet supported — locks apply to the whole reactor run.
- **Inline retries** do not increment the snooze counter (they are not Sidekiq-scheduled). If you retry inline in a loop, add your own backoff.
- **Multi-Redis** failover is not addressed. The lock is as durable as your Redis deployment; for cross-region critical sections, consider an external locking service.
- **Wait inside a Sidekiq worker** is intentionally disabled. If you want to keep a worker thread parked on `BLPOP`, run that reactor inline instead.
