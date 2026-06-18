# Locks, Semaphores, Rate Limits, Periods & Ordered Locks

RubyReactor ships with five Redis-backed coordination primitives — each tackling a different problem:

| Primitive           | Question it answers                                                                                  |
| ------------------- | ---------------------------------------------------------------------------------------------------- |
| `with_lock`         | "Is anyone else **currently** running with this key?" — concurrency control.                         |
| `with_semaphore`    | "Are too many runs **currently** in flight for this key?" — capacity control.                        |
| `with_rate_limit`   | "Have we already made N calls in this time window?" — fixed-window rate limiting (e.g. 3/sec).       |
| `with_period`       | "Has a successful run **already happened in this calendar bucket**?" — dedup / once-per-period.      |
| `with_ordered_lock` | "Is my turn yet?" — strict sequential ordering via a monotonically increasing nonce.                 |

They are orthogonal and composable: a reactor can declare any combination.

A typical use case:

- Only one `RefundOrderReactor` should run per order at a time → exclusive lock keyed by order id.
- Calls to an external service should never exceed 5 concurrent requests → semaphore with `limit: 5`.
- Calls to a rate-limited API must respect "3 per second AND 100 per minute" → multi-window `with_rate_limit`.
- A monthly billing reactor should run exactly once per org per month, even if a buggy scheduler enqueues it daily → period gate keyed by org id with `every: :month`.
- Ledger transactions for an account must apply in submission order even under a parallel worker pool → ordered-lock keyed by account id.

The lock/semaphore primitives:

- Are acquired before any step runs and released in an `ensure` block (so a crash, failure, or interrupt does not leak a holder).
- Snooze (re-enqueue) instead of fail when contention is encountered inside a Sidekiq worker.
- Carry a TTL so a crashed Ruby process cannot block the resource forever.

The period primitive is different: it is **dedup**, not concurrency. It records a marker after a successful run and skips subsequent runs in the same calendar bucket.

The ordered-lock primitive is different again: it assigns a nonce at **enqueue time** (inside `Reactor.run`) and uses a strict `last_completed + 1` gate to enforce sequential execution per key, even under a fan-out worker pool.

## Table of Contents

- [Exclusive Locks](#exclusive-locks)
  - [Re-entrancy](#re-entrancy)
  - [Auto-extend (TTL keepalive)](#auto-extend-ttl-keepalive)
  - [Inline vs async behavior on contention](#inline-vs-async-behavior-on-contention)
  - [Owner identity](#owner-identity)
- [Semaphores](#semaphores)
  - [Token model](#token-model)
  - [Release safety](#release-safety)
- [Rate Limits](#rate-limits)
  - [Single window](#single-window)
  - [Multi-window quotas](#multi-window-quotas)
  - [Named global limits](#named-global-limits)
  - [Algorithm & atomicity](#algorithm--atomicity)
  - [Smart snooze on async](#smart-snooze-on-async)
- [Periods (once-per-bucket dedup)](#periods-once-per-bucket-dedup)
  - [Bucket model](#bucket-model)
  - [When the marker is written](#when-the-marker-is-written)
  - [Composing with `with_lock`](#composing-with-with_lock)
  - [The `Skipped` result](#the-skipped-result)
  - [Skipping mid-reactor from a step](#skipping-mid-reactor-from-a-step)
- [Ordered Locks (strict sequencing)](#ordered-locks-strict-sequencing)
  - [How it works](#how-it-works)
  - [Drain and counter reset](#drain-and-counter-reset)
  - [Poison-pill timeout](#poison-pill-timeout)
  - [Composition with other primitives](#composition-with-other-primitives)
  - [What does NOT advance the cursor](#what-does-not-advance-the-cursor)
  - [Strict mode — stop the line on failure](#strict-mode--stop-the-line-on-failure)
  - [Operations](#operations)
  - [Caveats](#ordered-lock-caveats)
  - [Composed children](#composed-children)
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

## Rate Limits

`with_rate_limit` caps **how many runs are allowed within a time window**, regardless of whether they overlap in time. This is what you want for "no more than 3 calls per second to the Stripe API."

It is not the same as `with_semaphore`:

- Semaphore: "no more than N **concurrent** runs at any instant."
- Rate limit: "no more than N runs **starting** within any X-second window."

A reactor making three back-to-back API calls in 100ms hits a `3/sec` rate limit on the fourth — even though only one is ever in flight at a time.

### Single window

```ruby
class ChargeReactor < RubyReactor::Reactor
  input :account_id

  with_rate_limit(limit: 3, period: :second) { |inputs| "stripe:#{inputs[:account_id]}" }

  step :charge do
    argument :account_id, input(:account_id)
    run { |args| Stripe.charge(args[:account_id]) }
  end
end
```

`period:` accepts the same units as `with_period`: `:second`, `:minute`, `:hour`, `:day`, `:week`, `:month`, `:year`, or integer seconds.

The block returns the **key base**; each window stores its counter under `rate:<base>:<period_name>:<bucket_id>` so different periods don't collide.

### Multi-window quotas

Real upstream APIs typically expose layered limits ("3/sec AND 100/min AND 5000/hr"). Pass them all in one call with `limits:`:

```ruby
with_rate_limit(
  limits: { second: 3, minute: 100, hour: 5000 }
) { |inputs| "stripe:#{inputs[:account_id]}" }
```

All windows are checked atomically in one Lua call. **If any window fails, none of the others get incremented** — so a burst that blows the per-second cap doesn't also burn a per-minute slot.

The error reports the tightest (failing) window:

```ruby
begin
  ChargeReactor.run(account_id: 42)
rescue RubyReactor::RateLimit::ExceededError => e
  e.period_name          # => "second"
  e.limit                # => 3
  e.period_seconds       # => 1
  e.retry_after_seconds  # => seconds until the bucket rolls (1..period)
  e.key_base             # => "stripe:42"
end
```

### Named global limits

The inline forms above scope a limit to one reactor, with a per-call key base from the block. When **several reactors call the same external service**, you usually want them to share a single quota instead. Register the limit once in `RubyReactor.configure` and reference it by name:

```ruby
RubyReactor.configure do |config|
  config.rate_limits.register(:stripe, limits: { second: 3, minute: 100 })
  config.rate_limits.register(:twilio, limit: 10, period: :second)
end
```

`register` takes the **same window arguments** as the inline DSL — a single window (`limit:` + `period:`) or layered windows (`limits:`). Then in any reactor:

```ruby
class ChargeReactor < RubyReactor::Reactor
  input :account_id

  with_rate_limit(:stripe)

  step :charge do
    argument :account_id, input(:account_id)
    run { |args| Stripe.charge(args[:account_id]) }
  end
end

class RefundReactor < RubyReactor::Reactor
  input :charge_id

  with_rate_limit(:stripe)   # same :stripe bucket — shares the quota with ChargeReactor

  step :refund do
    argument :charge_id, input(:charge_id)
    run { |args| Stripe.refund(args[:charge_id]) }
  end
end
```

Key points:

- **The name is the key base.** A named limit uses the name itself (`"stripe"`) as the Redis key base, so every reactor referencing `:stripe` throttles against **one shared bucket** — exactly what you want for a global API quota. (Counters live at `rate:stripe:<period_name>:<bucket_id>`.)
- **Name-only.** `with_rate_limit(:stripe)` takes no `limit:`/`period:`/`limits:` and no key block — those come from the registry. Passing both raises `ArgumentError`.
- **Lazy resolution.** The name is resolved from the registry at run time, not at class load, so `configure` and reactor definitions can load in any order.
- **Unknown names fail loud.** Referencing a name that was never registered raises `RubyReactor::RateLimitRegistry::UnknownLimitError` (a configuration error that propagates out of `run`, not swallowed into a step failure). In a Sidekiq worker this is treated as permanent: the context is marked `:failed` immediately — no snooze, no Sidekiq retry burn.
- **Same enforcement path.** Named and inline limits both run through the same counter check, so multi-window semantics, the `ExceededError`, and async snooze behave identically (see below).

Use the inline block form instead when you need a **per-entity** key (e.g. one quota *per account*) rather than a single shared bucket.

### Algorithm & atomicity

Fixed-window counter (same family as the [kpumuk/throttling](https://github.com/kpumuk/throttling) gem):

- Bucket id = `floor(now / period_seconds)`. It changes the instant the period rolls, so old buckets become irrelevant the moment they expire — no cleanup needed.
- One Redis `INCR` per window, with a single `EXPIRE` on the first increment of a new bucket. TTL = `2 * period_seconds` for safety.
- Multi-window: two passes inside a single Lua script — check all, then increment all. No interleaving with other clients.

Trade-off vs token bucket: fixed-window can allow up to 2× the limit across the very boundary (3 at `:59.99` + 3 at `:00.01` = 6 in 20ms). For typical upstream API limits this is fine; if you need strict pacing, layer a second `with_rate_limit(limit: 1, period: <interval>)`.

### Smart snooze on async

When a Sidekiq worker hits a rate limit, it reads `retry_after_seconds` off the error and snoozes for **exactly** that long (plus jitter, floored at 0.1s). The next attempt fires the moment the bucket rolls — no busy waiting, no fixed cadence.

This shares the existing snooze cap (`lock_snooze_max_attempts`). After the cap is reached, the context is marked `:failed`, same as for lock/semaphore contention.

| Caller        | Behavior on rate-limit hit                                                                                                            |
| ------------- | ------------------------------------------------------------------------------------------------------------------------------------- |
| Inline        | Raises `RubyReactor::RateLimit::ExceededError`. Caller can `sleep(error.retry_after_seconds); retry` or surface 429 to its user.      |
| Sidekiq async | Snoozes `perform_in(retry_after + jitter, ...)`. Does not burn Sidekiq retry budget. Counted against `lock_snooze_max_attempts`.      |

The rate-limit check happens **before** lock/semaphore acquisition: a job that would be rate-limited never grabs a mutex.

Like the period gate, the rate limit applies to the **first execution** only — the inline call for sync reactors, the first worker pass for async reactors. Genuine resumes (interrupt continue, async step handoff, retry requeue) never re-check: a paused reactor must not throttle itself on the way back in.

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

The gate applies to the **first execution** only — for sync reactors that's the inline call; for async reactors it's the first worker pass. Genuine resumes (interrupt continue, async step handoff, retry requeue) skip the period check entirely — a paused reactor must never skip *itself* when its eventual marker appears.

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

1. **Period check (fast path).** If marker exists, return `Skipped` immediately. No lock acquired, no steps run.
2. **Lock acquire.** Standard concurrency control kicks in.
3. **Period re-check (under the lock).** Closes the race where two callers both pass step 1 and then serialize on the lock: by the time the loser acquires it, the winner has marked the bucket, so the loser returns `Skipped` instead of re-running the work. The lock is still released normally on this path.
4. **Run steps.**
5. **On terminal Success: mark the period bucket.**
6. **Release lock.**

With the under-lock re-check, `with_lock` + `with_period` gives **strict at-most-one-per-bucket**: the marker dedups, the lock serializes, and the re-check seals the gap between them.

### The `Skipped` result

`RubyReactor::Skipped` is a Success-subclass result returned in two situations:

1. **Implicit period gate**, as shown above — a `with_period` reactor reruns in an already-claimed bucket.
2. **Explicit step return** — a step's `run` block returns `Skipped(...)` to halt the reactor cleanly without compensation. `Skipped` is a bare helper available in both class steps and inline blocks, exactly like `Success`/`Failure` (the fully-qualified `RubyReactor.Skipped(...)` works too). See [Skipping mid-reactor from a step](#skipping-mid-reactor-from-a-step) below.

Both shapes share the same API:

```ruby
result = MonthlyBillingReactor.run(org_id: 42)

result.success?    # => true   (Skipped is a Success subclass)
result.skipped?    # => true
result.reason      # => :period (or whatever the step passed)
result.period_key  # => "period:monthly_billing:42:2026-05" (period gate only)
result.step_name   # => :build_report (step return only)
```

`Skipped` deliberately satisfies `success?` so existing `if result.success? ... else ...` branches still take the right path. Code that wants to log or count skips explicitly checks `result.skipped?`.

The reactor's context status becomes `:skipped` (rather than `:completed`), so dashboards can render skip events distinctly.

### Skipping mid-reactor from a step

You can also produce a `Skipped` result from inside a step's `run` block. This is useful when a step discovers that the rest of the workflow is unnecessary **and the partial progress so far is fine to keep**.

```ruby
class SyncSubscriberReactor < RubyReactor::Reactor
  input :user_id

  step :fetch_user do
    argument :user_id, input(:user_id)
    run { |args| User.find(args[:user_id]) }
  end

  step :ensure_active do
    argument :user, result(:fetch_user)
    run do |args, _ctx|
      # Nothing to do — bail out, but keep the user-fetch we already did.
      next Skipped(reason: "user_opted_out") if args[:user].opted_out?

      Success(args[:user])
    end
  end

  step :push_to_mailing_list do
    argument :user, result(:ensure_active)
    run { |args| Mailchimp.subscribe(args[:user]) }
  end
end

result = SyncSubscriberReactor.run(user_id: 42)

if result.skipped?
  Rails.logger.info("Sync skipped (#{result.reason}) at step #{result.step_name}")
end
```

What happens when a step returns `Skipped`:

| Aspect                                | Behavior                                                                                                                              |
| ------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------- |
| Remaining steps                       | Not executed. The reactor halts at the skipping step.                                                                                 |
| Previously completed steps            | **Left intact — no compensation** runs. This is the critical difference vs `Failure`.                                                 |
| Step's value                          | Not stored in `intermediate_results` (it produced no usable output). Downstream never runs, so unreachable.                           |
| Execution trace                       | A `{ type: :skipped, step: <name>, reason: <reason> }` entry is appended.                                                             |
| Returned `Skipped`                    | Carries `step_name` (the halting step) and `reason` (whatever the user passed).                                                       |
| `Reactor.run` / `result.success?`     | Returns the `Skipped`. `success?` is `true`, `skipped?` is `true`, status `:skipped`.                                                 |

**`Skipped` vs `Failure` decision matrix:**

| Situation                                            | Return                                            |
| ---------------------------------------------------- | ------------------------------------------------- |
| Step did its job; subsequent steps not needed        | `RubyReactor.Skipped(reason: "...")`              |
| Step couldn't proceed because of an error            | `RubyReactor.Failure(error)` — triggers undo path |
| Step succeeded normally                              | `RubyReactor.Success(value)`                      |

A common smell to avoid: returning `Skipped` from a step that has just done **partial** work that needs cleanup. If you'd want compensation to run, use `Failure` instead — `Skipped` explicitly says "the partial progress is correct, stop here."

## Ordered Locks (strict sequencing)

`with_ordered_lock` enforces strict per-key transaction ordering. When you fan a stream of work out across an async worker pool, normal queues give no order guarantee — two workers can pop neighbouring jobs and run them in whichever order the scheduler picks. The ordered-lock primitive fixes that with a monotonically increasing nonce that is **assigned at enqueue time** (synchronously inside `Reactor.run`, before `perform_async` is called) and a strict `last_completed + 1` gate at execute time.

> **Use only on `async` reactors.** The gate's only "wait" mechanism is the Sidekiq worker rescuing `OrderedLock::WaitError` and snoozing via `perform_in`. A **synchronous** reactor (no `async`) has no worker to snooze it: a nonce assigned out of order raises `OrderedLock::WaitError` straight to the caller of `Reactor.run`. Single-threaded sequential sync calls happen to be fine (each nonce is always `last_completed + 1` by the time it runs), but **concurrent sync `Reactor.run` calls on the same key will raise** to whichever caller is out of order. If you need ordering, mark the reactor `async`.

```ruby
class ApplyTransactionReactor < RubyReactor::Reactor
  async
  input :account_id
  input :transaction

  with_ordered_lock(
    poison_pill_timeout: 300   # secs before the gate auto-advances past a stuck blocker
  ) { |inputs| "txs:#{inputs[:account_id]}" }

  step :apply do
    argument :transaction, input(:transaction)
    run { |args| Ledger.apply(args[:transaction]) }
  end
end

# Caller-side submission order is preserved per key.
[tx1, tx2, tx3].each do |tx|
  ApplyTransactionReactor.run(account_id: 42, transaction: tx)
end
# → nonces 1, 2, 3 assigned in `Reactor.run` (atomic INCR in Redis).
# → workers may dequeue in any order, but only the one holding `last_completed + 1`
#   executes; others raise `OrderedLock::WaitError` and snooze.
```

### How it works

Three Redis keys per ordered-lock key (hash-tagged so they stay on one shard in a Redis cluster):

| Key                                   | Purpose                                            |
| ------------------------------------- | -------------------------------------------------- |
| `ordered_lock:{<key>}:next`           | Last-assigned nonce (caller-side INCR target).     |
| `ordered_lock:{<key>}:last_completed` | Last-advanced nonce (worker-side cursor).          |
| `ordered_lock:{<key>}:assigned_at`    | Hash `{ nonce => unix_ts }` for poison-pill TTLs.  |

Lifecycle per run:

1. **Enqueue (caller process, inside `Reactor.run`)** — single Lua `INCR` on `next`, plus `HSET assigned_at`. The nonce is stamped onto `context.private_data[:ordered_lock]` and persisted in the serialized context that Sidekiq carries to the worker. Input-validation failures abort BEFORE assigning, so a bad payload never consumes a nonce.
2. **Execute (worker)** — the executor's first gate (before rate-limit, lock, semaphore) is a Lua `can_proceed` script. It returns `go` if `my_nonce == last_completed + 1` (or if `my_nonce <= last_completed`, i.e. a Sidekiq retry of an already-advanced run — idempotent), or `wait` otherwise. On `wait`, the executor raises `RubyReactor::OrderedLock::WaitError`, no other primitive has been acquired, and the Sidekiq worker snoozes via `perform_in(lock_snooze_base_delay + jitter, ...)` — a short re-poll, since the blocker nonce usually completes in milliseconds. The `WaitError` carries a `retry_after_seconds` derived from the poison-pill window, but that is the *upper bound* before a dead blocker is force-advanced, not the expected wait, so it is deliberately **not** used as the re-poll interval (doing so would make every out-of-order nonce sleep up to `poison_pill_timeout`). A genuinely dead blocker is cleared by poison auto-advance on a later gate, at most one `poison_pill_timeout` after it went stale.
3. **Terminal completion (`ensure` block in the executor)** — on `Success` / `Skipped` / `Failure` (with all retries exhausted), a Lua `advance` script moves `last_completed` forward to `my_nonce`. Idempotent: a duplicate / out-of-order advance is a no-op.

### Drain and counter reset

When `last_completed` catches up to `next`, the advance Lua deletes all three keys. The very next `Reactor.run` on that key starts again at nonce 1. This means you can re-use the same key across independent batches without worrying about an ever-growing counter:

```ruby
[a, b, c].each { |t| ApplyTransactionReactor.run(account_id: 42, transaction: t) }
# … wait for the queue to drain (or use OrderedLock.peek to check) …
# → nonces 1, 2, 3, drained, counter deleted.

[d, e, f].each { |t| ApplyTransactionReactor.run(account_id: 42, transaction: t) }
# → nonces 1, 2, 3 again. Same ordering enforcement.
```

If a new run arrives **before** the previous batch fully drains, it simply gets `next + 1` (e.g. 4, 5, 6) — the counter only resets after a clean drain.

### Poison-pill timeout

A naive ordered-lock has a fatal failure mode: if the caller crashes between `INCR` and `perform_async`, or if the worker dies after starting but before reaching the executor's `ensure` advance, the blocker nonce sits there forever and every subsequent nonce snoozes against it indefinitely.

`poison_pill_timeout` (default `OrderedLock::DEFAULT_POISON_PILL_TIMEOUT`, currently 600s) protects against this. Inside the `can_proceed` Lua, if the blocker nonce was assigned more than `poison_pill_timeout` seconds ago, the script auto-advances `last_completed` past it. Tune this to roughly the maximum time you expect a single nonce to legitimately stay in-flight (including queue wait + retries).

**Liveness heartbeat.** `assigned_at` is stamped at enqueue, but every time a nonce runs its own gate check (the initial attempt and each snooze round) it restamps its `assigned_at` to "now". **Additionally, while a nonce that passed its gate is actively executing its steps, a background thread restamps `assigned_at` every `poison_pill_timeout / 3` seconds (floored at 1s).** Without this second heartbeat, a blocker whose steps legitimately run longer than `poison_pill_timeout` would be poison-passed by a successor mid-execution — a silent ordering violation, since the gate-check heartbeat fires only at the start of a run, not during it. Together these mean the poison clock measures *time since the job last proved it was alive*, not time since enqueue — a job that sat in a deep queue then snoozed on a downstream lock, or one that is grinding through a long step, keeps a fresh timestamp and won't be poison-passed while it is genuinely making progress. (Every restamp is guarded by `hexists`, so it never resurrects a timer that a terminal advance already deleted, and by the epoch fence, so a stale-batch straggler never touches the live batch.)

> ⚠️ **Backlog caveat.** The heartbeat only fires once a job is *picked up* and runs its gate. A job that is still sitting in the Sidekiq queue — never dispatched — keeps its enqueue-time `assigned_at`. If your queue backlog routinely exceeds `poison_pill_timeout`, a blocker can be poison-passed while it is merely waiting its turn to be dispatched, and ordering is silently ceded for that nonce. Set `poison_pill_timeout` comfortably above your worst-case *dispatch latency* (backlog drain time), not just your per-job runtime. Under sustained overload where backlog > timeout, ordered-lock ordering degrades by design — provision worker capacity or raise the timeout accordingly.

A caller can also force-advance past a stuck nonce manually:

```ruby
RubyReactor::OrderedLock.skip!("txs:42", nonce: 7)
```

### Composition with other primitives

The ordered-lock gate runs **before** any other primitive in the executor:

```text
execute:
  check_ordered_lock_gate    # raise WaitError → snooze, no other primitive held
  check_period_gate
  check_rate_limit           # consumes a window slot
  acquire_exclusive_lock
  acquire_semaphore
  …run steps…
ensure:
  release semaphore + lock
  advance ordered_lock cursor (on terminal status only)
```

This ordering is deliberate and prevents a classic hold-and-wait deadlock that would otherwise occur if a reactor combined `with_lock` and `with_ordered_lock` on overlapping keys:

> Without ordered-first: nonce 2 acquires `with_lock("X")`, then waits for nonce 1. Nonce 1 tries to acquire `with_lock("X")` and blocks behind nonce 2. With `auto_extend: true`, the lock TTL never expires. Both stuck forever.

With ordered-first, a waiting nonce holds no other primitive. It snoozes and tries again later.

A reactor can freely combine `with_ordered_lock` with any of `with_lock`, `with_semaphore`, `with_rate_limit`, and `with_period`. Composition with `with_lock` on the **same key** is a common pattern: ordering across the stream + at-most-one-runner per nonce.

### What does NOT advance the cursor

The cursor moves forward only on results the executor considers **terminal** for this run:

- `RubyReactor::Success` (including `RubyReactor::Skipped`)
- `RubyReactor::Failure` (when in-reactor step retries are exhausted)

The cursor does **not** move on:

- `RubyReactor::InterruptResult` — the reactor is paused waiting for `continue()`. The same nonce stays in-flight; the poison-pill timeout is the long-term safety net here, so tune it accordingly for human-action workflows.
- `RubyReactor::AsyncResult` — the run handed off to a different Sidekiq job; that job still carries the same nonce.
- `RetryQueuedResult` — a step explicitly re-queued itself.
- `OrderedLock::WaitError` / `Lock::AcquisitionError` / other contention errors — they propagate before the executor sets `@result`, so the `ensure` block sees nothing terminal and does not advance.

Sidekiq retries of a job whose nonce is already past `last_completed` are also safe: `can_proceed` returns `go` for any `my_nonce <= last_completed`, so a duplicate execution does no harm and the (idempotent) advance is a no-op.

### Strict mode — stop the line on failure

By default `with_ordered_lock(strict: true)` treats the sequence as a pipeline: **if any nonce terminates with a `Failure`, every subsequent nonce in the same batch is short-circuited with `Skipped(reason: :ordered_lock_chain_failed)` and never executes its steps.** This models "don't apply transaction N+1 if transaction N broke the ledger" — useful when later work depends on the success of earlier work and reordering is not safe.

```ruby
class ApplyTransactionReactor < RubyReactor::Reactor
  async
  with_ordered_lock(poison_pill_timeout: 300) { |i| "txs:#{i[:account_id]}" } # strict: true by default
  step :apply do
    argument :tx, input(:transaction)
    run { |args| Ledger.apply(args[:tx]) } # raising/Failure poisons the chain
  end
end
```

If you want the *opposite* — preserve ordering but keep applying subsequent nonces even when an earlier one failed — pass `strict: false`:

```ruby
with_ordered_lock(strict: false) { |i| "emails:#{i[:user_id]}" }
```

Notes on strict mode:

- The poison marker is per **key**, not per reactor class. Different reactors that share a key share the marker.
- Only the **first** failure sticks. A second failure does not move the marker; cleanup is automatic on full drain.
- Skipped runs from this mechanism are real `Skipped` results (`status: :skipped`, `result.success?` true, `result.skipped?` true, `result.reason == :ordered_lock_chain_failed`). They **do** advance the cursor — the chain keeps draining, it just produces Skipped for each subsequent member.
- The chain-skip check applies only on the **initial** `execute`. A run that already started and then paused (InterruptResult / AsyncResult) **completes on resume** even if the chain failed while it was parked — once a nonce is past the gate it owns its slot until terminal.
- The marker auto-clears on full drain (`last_completed == next`). The very next batch starts un-poisoned.
- Operators can read the marker via `RubyReactor::OrderedLock.peek(key)[:first_failed]` (0 if no failure).

### Operations

```ruby
RubyReactor::OrderedLock.peek("txs:42")
# => { next: 7, last_completed: 4, in_flight: [5, 6, 7], first_failed: 0 }
# `first_failed` is the lowest nonce that terminated with Failure (strict mode
# poison marker), or 0 if none yet. Auto-clears on full drain.

RubyReactor::OrderedLock.skip!("txs:42", nonce: 5)
# Force-advance past a stuck nonce. Use when you're sure the blocker is dead
# and you don't want to wait for poison_pill_timeout.

RubyReactor::OrderedLock.reset!("txs:42")
# Nuke all counters for a key. Ops escape hatch only — concurrent enqueues
# during reset produce undefined ordering.
```

### Ordered-lock caveats

- **No re-entrancy.** Unlike `with_lock` (which uses the root context id as owner to allow nested reactors to share the lock), a nested reactor with its own `with_ordered_lock` is an independent sequence. This is intentional — nested sequences with their own nonces compose by being independent. See [Composed children](#composed-children) below for the specific case of `compose :foo, ChildWithOrderedLock`.
- **Synchronous nested `Reactor.run` on the same key is silently ignored.** Calling `InnerOrderedReactor.run(...)` from inside a step of `OuterOrderedReactor` when both target the same ordered-lock key would deadlock — the outer nonce holds the slot, the inner gets a fresh nonce that can never advance until the outer completes, but the outer is blocked waiting for the inner. The framework detects this at `Reactor#run` time, **skips** the inner's nonce assignment, and logs a warning. The inner reactor runs without gate/advance — i.e. as a normal Reactor call with no ordering enforcement on this nesting level — and the outer keeps its single slot. Different keys are unaffected; async/Sidekiq paths are unaffected (they execute on a different thread/process and so do not collide).
- **Bypass via raw `perform_async` is unsafe.** Always go through `Reactor.run` on an ordered-lock reactor. Constructing a serialized context by hand and pushing it onto Sidekiq directly skips the enqueue-side INCR, so the worker either runs without a nonce (no gate enforcement) or fails the gate (no nonce in `private_data`).
- **Validation failures don't consume a nonce.** Assignment happens after input validation succeeds.
- **Pub/sub wake is intentionally not used.** The worker-snooze model uses Sidekiq's scheduled set as durable parking; pub/sub adds a fragile second path with no correctness benefit at our throughputs. See the design notes if you need sub-second wake latency at high parked-job counts.
- **`WaitError` bypasses `lock_snooze_max_attempts`.** Unlike lock / semaphore / rate-limit contention, an ordered-lock wait does not count against the snooze cap. The cap would either fail a job prematurely (the legitimate wait window can be `poison_pill_timeout` long) or strand the nonce in `assigned_at` after escalation. Instead, a waiting nonce snoozes indefinitely until either the gate passes or `poison_pill_timeout` auto-advances the cursor past the blocker(s). Set `poison_pill_timeout` to your upper-bound wall-clock for legitimate single-nonce in-flight time.
- **Clustered poison advances in one shot.** If multiple consecutive blockers are dead (e.g. a process crashed mid-batch), `can_proceed` drains all stale prefix blockers in a single Lua call rather than one per snooze round. Recovery time scales with `poison_pill_timeout`, not with the number of stale nonces.
- **Synchronous (non-async) ordered-lock reactors raise `WaitError` to the caller.** The snooze-and-retry machinery lives in the Sidekiq worker. A *synchronous* `Reactor.run` on an ordered-lock reactor (a reactor without `async`) has no worker to park it: if its nonce isn't yet at the front of the line, `Reactor.run` raises `OrderedLock::WaitError` straight to the caller, and the nonce has **already been consumed** at enqueue. If the caller swallows the error and never retries, that nonce never advances and every successor stalls until `poison_pill_timeout` sweeps it. Synchronous ordered locks therefore only make sense when callers submit in already-correct order (so each gate passes first try) or when the caller explicitly retries on `WaitError`. For fan-out across concurrent producers, use an `async` reactor so contention is handled by the durable snooze path. (A single-producer synchronous sequence — one caller submitting strictly in order — drains cleanly; this is the case the `SyncOrderedReactor` integration tests cover.)
- **Stale redeliveries never downgrade a terminal record.** A Sidekiq at-least-once redelivery of a job whose batch already drained is fenced two ways, depending on timing:
  - **After the next batch starts** — the redelivery carries an epoch from the drained generation, so the epoch check resolves it to `:stale_batch`: it runs no steps and mutates no counters.
  - **In the drain gap** (after GC, before the next batch's first assign bumps the epoch) — the epoch still matches, so the gate instead returns `:drained_go`. Here the executor consults the **stored context status**: a genuine late straggler (non-terminal) still runs (poison semantics), but a redelivery of an already-terminal context is short-circuited with `Skipped(reason: :ordered_lock_drained_replay)` and does **not** re-execute its steps.

  In both cases, if the original run had already reached a terminal status (`:completed` / `:failed` / `:skipped`), the short-circuit deliberately skips persistence so the stored outcome is never overwritten with `:skipped`.

### Composed children

When you `compose :foo, ChildReactor` and `ChildReactor` declares `with_ordered_lock`, the child's declaration **is silently ignored** — the child is invoked through the compose machinery, which bypasses `Reactor#run` and never assigns a nonce. A warning is logged at class-load time so this isn't a silent surprise:

```text
RubyReactor: `with_ordered_lock` on ChildReactor is ignored when composed by
ParentReactor#foo. Nested ordered-lock sequences are independent and must run
via top-level `Reactor.run` to be enforced.
```

If you need ordering on the child's work, invoke it as a top-level `Reactor.run` (typically from a step body, with `async`), not via `compose`.

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

Lock, semaphore, rate-limit, period, and ordered-lock config defined on a reactor are propagated to subclasses:

```ruby
class BaseRefund < RubyReactor::Reactor
  with_lock { |i| "order:#{i[:order_id]}" }
  # ...
end

class FullRefund < BaseRefund   # also locks "order:<id>"
end
```

A subclass can call `with_lock` / `with_semaphore` / `with_rate_limit` / `with_period` / `with_ordered_lock` again to override the inherited configuration.

## Observability

- Snooze escalation, release failures, and "release on something we did not actually hold" conditions are logged via `RubyReactor.configuration.logger.warn`.
- The current owner of a lock is in the Redis hash `lock:<key>` under field `owner`.
- The held-tokens set for a semaphore is `semaphore:<key>:held`. Its cardinality plus `LLEN semaphore:<key>` should always equal `limit` at rest.
- The period marker is the plain key `period:<base>:<bucket_id>`. `TTL` on that key tells you when the bucket frees up.
- A `Skipped` result sets context status to `:skipped` (separate from `:completed`/`:failed`).
- Rate-limit counters are at `rate:<base>:<period_name>:<bucket_id>`. `GET` gives the current count for the window; `TTL` gives time until the bucket rolls.
- Ordered-lock state lives at `ordered_lock:{<key>}:next`, `:last_completed`, and `:assigned_at`. Use `RubyReactor::OrderedLock.peek(key)` to inspect all three in one call.

## Limitations

- **Step-level locking** is not yet supported — locks apply to the whole reactor run. Same for `with_period`.
- **Inline retries** do not increment the snooze counter (they are not Sidekiq-scheduled). If you retry inline in a loop, add your own backoff.
- **Multi-Redis** failover is not addressed. The lock is as durable as your Redis deployment; for cross-region critical sections, consider an external locking service.
- **Wait inside a Sidekiq worker** is intentionally disabled. If you want to keep a worker thread parked on `BLPOP`, run that reactor inline instead.
- **`with_period` alone is not a mutex.** Concurrent racers can both run before either has written the marker. Pair with `with_lock` if you need true at-most-one-per-bucket (the gate is re-checked under the lock, so the pairing is strict). The period is calendar-aligned, not "N hours since last run"; if you need sliding semantics, pass an integer `every:`.
- **`with_rate_limit` is fixed-window.** Up to 2× the limit can run across a single window boundary. For strict pacing, use a token-bucket-style external rate limiter or stack a tighter `with_rate_limit(limit: 1, period: <interval>)` for serialized requests.
- **Rate slots are consumed before lock/semaphore acquisition.** This ordering ensures a rate-limited job never grabs a mutex, but the inverse cost is that a run which passes the rate check and then hits lock/semaphore contention has already consumed a slot for an attempt that never ran. The same applies per snooze attempt when an async first run keeps colliding with a held lock. If your quota is tight relative to your contention, prefer keys that don't overlap a contended lock, or widen the window.
- **Semaphores are not re-entrant.** Locks are owner-based and re-entrant across composed reactors; semaphores have no owner concept. A composed reactor acquiring the same semaphore key as its parent consumes a second token — with `limit: 1` and `wait: 0` it fails immediately, and with `wait > 0` it deadlocks until the wait expires. Don't share one semaphore key between a parent and its composed children.
- **`with_ordered_lock` requires `Reactor.run` as the entry point.** Bypassing it (e.g. by hand-rolling a serialized context and pushing onto Sidekiq) skips the enqueue-side INCR and breaks the ordering guarantee. It is also not re-entrant — nested ordered-lock reactors are independent sequences. Both nesting paths (same-thread `Reactor.run` on the same key, and `compose` of a child that declares `with_ordered_lock`) silently skip the inner's ordering and log a warning rather than raise.
