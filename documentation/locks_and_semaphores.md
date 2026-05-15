# Locks, Semaphores & Periods

RubyReactor ships with three Redis-backed coordination primitives — each tackling a different problem:

| Primitive        | Question it answers                                                                              |
| ---------------- | ------------------------------------------------------------------------------------------------ |
| `with_lock`      | "Is anyone else **currently** running with this key?" — concurrency control.                     |
| `with_semaphore` | "Are too many runs **currently** in flight for this key?" — capacity control.                    |
| `with_period`    | "Has a successful run **already happened in this calendar bucket**?" — dedup / once-per-period.  |

They are orthogonal and composable: a reactor can declare any combination.

A typical use case:

- Only one `RefundOrderReactor` should run per order at a time → exclusive lock keyed by order id.
- Calls to a rate-limited external API should never exceed 5 concurrent requests → semaphore with `limit: 5`.
- A monthly billing reactor should run exactly once per org per month, even if a buggy scheduler enqueues it daily → period gate keyed by org id with `every: :month`.

The lock/semaphore primitives:

- Are acquired before any step runs and released in an `ensure` block (so a crash, failure, or interrupt does not leak a holder).
- Snooze (re-enqueue) instead of fail when contention is encountered inside a Sidekiq worker.
- Carry a TTL so a crashed Ruby process cannot block the resource forever.

The period primitive is different: it is **dedup**, not concurrency. It records a marker after a successful run and skips subsequent runs in the same calendar bucket.

## Table of Contents

- [Exclusive Locks](#exclusive-locks)
  - [Re-entrancy](#re-entrancy)
  - [Auto-extend (TTL keepalive)](#auto-extend-ttl-keepalive)
  - [Inline vs async behavior on contention](#inline-vs-async-behavior-on-contention)
  - [Owner identity](#owner-identity)
- [Semaphores](#semaphores)
  - [Token model](#token-model)
  - [Release safety](#release-safety)
- [Periods (once-per-bucket dedup)](#periods-once-per-bucket-dedup)
  - [Bucket model](#bucket-model)
  - [When the marker is written](#when-the-marker-is-written)
  - [Composing with `with_lock`](#composing-with-with_lock)
  - [The `Skipped` result](#the-skipped-result)
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

## Periods (once-per-bucket dedup)

The period gate solves a different problem from locks and semaphores: it ensures a reactor runs **at most once per calendar bucket**, regardless of how many times its caller enqueues it.

A typical scenario:

> "Send the monthly billing report once a month. A scheduling bug now enqueues this reactor daily — we don't want 30 duplicate reports."

```ruby
class MonthlyBillingReactor < RubyReactor::Reactor
  input :org_id

  with_period(every: :month) { |inputs| "monthly_billing:#{inputs[:org_id]}" }

  step :build do
    argument :org_id, input(:org_id)
    run { |args| Billing.generate(args[:org_id]) }
  end
end
```

After the first successful run in May 2026, every other `MonthlyBillingReactor.run(org_id: 42)` call until June 1 (UTC) returns a `RubyReactor::Skipped` result. **No steps execute.**

### Bucket model

`every:` accepts:

- Symbols: `:minute`, `:hour`, `:day`, `:week`, `:month`, `:year` — calendar-aligned UTC buckets. Two calls at `2026-05-31 23:59 UTC` and `2026-06-01 00:01 UTC` fall into different `:month` buckets, even though they're two minutes apart.
- Integer seconds: e.g. `every: 3600` — sliding bucket computed as `time.to_i / every`.

The block returns the **base key**. The final Redis marker is `period:<base>:<bucket_id>`, e.g. `period:monthly_billing:42:2026-05`.

| Symbol    | Bucket format example     | TTL stored on marker |
| --------- | ------------------------- | -------------------- |
| `:minute` | `2026-05-15T14-30`        | 120 s                |
| `:hour`   | `2026-05-15T14`           | 7 200 s              |
| `:day`    | `2026-05-15`              | 172 800 s            |
| `:week`   | `2026-W20` (ISO week)     | 1 209 600 s          |
| `:month`  | `2026-05`                 | ~62 days             |
| `:year`   | `2026`                    | ~2 years             |

TTL is always **twice the period length** so the marker reliably dedups the next attempt, even with clock skew across the boundary.

### When the marker is written

The marker is written **only after a terminal `Success`** (and after the reactor's `mark_period_on_success` runs, which the executor handles automatically). This means:

- A failed run does **not** consume the bucket — the next attempt can succeed.
- A paused run (interrupted, async-handed-off) does **not** consume the bucket until the eventual resume completes successfully.
- A `Skipped` result does **not** re-mark the bucket (no-op).

Resume paths skip the period check entirely — a paused reactor must never skip *itself* when its eventual marker appears.

### Composing with `with_lock`

`with_period` alone is dedup, not concurrency. Two callers that fire at exactly the same time may both see "no marker yet" and both run. That's usually fine if the work is idempotent, but if you need strict at-most-one-per-bucket, pair it with `with_lock`:

```ruby
class MonthlyBillingReactor < RubyReactor::Reactor
  # Mutex: only one runner at a time per org.
  with_lock(ttl: 600) { |inputs| "monthly_billing:#{inputs[:org_id]}" }
  # Dedup: each (org, month) tuple runs only once.
  with_period(every: :month) { |inputs| "monthly_billing:#{inputs[:org_id]}" }
end
```

Order of evaluation per call:

1. **Period check.** If marker exists, return `Skipped` immediately. No lock acquired, no steps run.
2. **Lock acquire.** Standard concurrency control kicks in.
3. **Run steps.**
4. **On terminal Success: mark the period bucket.**
5. **Release lock.**

### The `Skipped` result

```ruby
result = MonthlyBillingReactor.run(org_id: 42)

result.success?    # => true   (Skipped is a Success subclass)
result.skipped?    # => true
result.period_key  # => "period:monthly_billing:42:2026-05"
result.reason      # => :period
```

`Skipped` deliberately satisfies `success?` so existing `if result.success? ... else ...` branches still take the right path. Code that wants to log or count duplicates can check `result.skipped?` explicitly.

The reactor's context status becomes `:skipped` (rather than `:completed`), so dashboards can render dedup events distinctly.

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

Lock, semaphore, and period config defined on a reactor are propagated to subclasses:

```ruby
class BaseRefund < RubyReactor::Reactor
  with_lock { |i| "order:#{i[:order_id]}" }
  # ...
end

class FullRefund < BaseRefund   # also locks "order:<id>"
end
```

A subclass can call `with_lock` / `with_semaphore` / `with_period` again to override the inherited configuration.

## Observability

- Snooze escalation, release failures, and "release on something we did not actually hold" conditions are logged via `RubyReactor.configuration.logger.warn`.
- The current owner of a lock is in the Redis hash `lock:<key>` under field `owner`.
- The held-tokens set for a semaphore is `semaphore:<key>:held`. Its cardinality plus `LLEN semaphore:<key>` should always equal `limit` at rest.
- The period marker is the plain key `period:<base>:<bucket_id>`. `TTL` on that key tells you when the bucket frees up.
- A `Skipped` result sets context status to `:skipped` (separate from `:completed`/`:failed`).

## Limitations

- **Step-level locking** is not yet supported — locks apply to the whole reactor run. Same for `with_period`.
- **Inline retries** do not increment the snooze counter (they are not Sidekiq-scheduled). If you retry inline in a loop, add your own backoff.
- **Multi-Redis** failover is not addressed. The lock is as durable as your Redis deployment; for cross-region critical sections, consider an external locking service.
- **Wait inside a Sidekiq worker** is intentionally disabled. If you want to keep a worker thread parked on `BLPOP`, run that reactor inline instead.
- **`with_period` alone is not a mutex.** Concurrent racers can both run before either has written the marker. Pair with `with_lock` if you need true at-most-one-per-bucket. The period is calendar-aligned, not "N hours since last run"; if you need sliding semantics, pass an integer `every:`.
