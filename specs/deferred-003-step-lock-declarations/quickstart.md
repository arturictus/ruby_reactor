# Quickstart: Step-Scoped Coordination

**Feature**: `specs/003-step-lock-declarations/` | **Date**: 2026-09-10

How to run and verify this feature. DSL details: [contracts/dsl-surface.md](./contracts/dsl-surface.md).
Design rationale: [research.md](./research.md).

## Prerequisites

Every claim here is a concurrency claim, so real infrastructure is mandatory — mocked Redis or
`Sidekiq::Testing.inline!` cannot prove any of it. Inline testing mode is actively wrong for
this feature: it re-enters the worker synchronously inside the frame that already holds the
lock.

```bash
docker compose up -d redis-test              # gem suite (port 6780)
docker compose up -d demo-redis sidekiq      # demo app + a real worker
```

## Scenario 1 — one step serializes, the workflow does not (US1, US2)

```ruby
class ChargeStep
  include RubyReactor::Step

  input :account_id
  input :amount

  with_lock { |args| "acct:#{args[:account_id]}" }

  def self.run(args, _ctx)
    Success(charge!(args))
  end
end

class PaymentReactor < RubyReactor::Reactor
  input :account_id
  input :amount

  step :audit,  AuditStep       # unlocked
  step :charge, ChargeStep      # locked on the account
  step :notify, NotifyStep      # unlocked
end
```

**Expected**: two concurrent runs with the same `account_id` never overlap inside `:charge`;
`:audit` and `:notify` of both runs overlap freely. Two runs with different `account_id`
overlap everywhere.

```bash
bundle exec rspec spec/ruby_reactor/step_coordination/lock_spec.rb
```

## Scenario 2 — contention parks instead of failing (US3)

```ruby
# Two worker-backed executions, same key:
PaymentReactor.run(account_id: 1, amount: 10)   # via background dispatch
PaymentReactor.run(account_id: 1, amount: 20)

# => both complete successfully; the second after the first released.
#    No compensation ran. The second was requeued, not failed.
```

Synchronously there is no queue to park into:

```ruby
PaymentReactor.run(account_id: 1, amount: 20)   # in-process, key held elsewhere
# => Failure(Lock::AcquisitionError, reactor:, step: :charge, key: "acct:1")
#    prior steps compensated, as with any step failure
```

```bash
bundle exec rspec spec/ruby_reactor/step_coordination/contention_spec.rb
```

Also asserted there: contention attempts are bounded, counted separately from failure retries,
and an execution over the ceiling reports contention rather than snoozing forever.

## Scenario 3 — re-entrancy matches nested reactors (US4)

```ruby
class OuterReactor < RubyReactor::Reactor
  input :id
  with_lock { |i| "k:#{i[:id]}" }        # reactor holds it
  step :work, LockingStep                 # step declares the same key
end
```

**Expected**: completes without waiting on itself; the key becomes available to other
executions only after the outermost release.

Where ownership cannot cross a process boundary, the hand-off is refused up front:

```ruby
# execution holds "k:1", then dispatches work that declares "k:1"
# => Failure at dispatch naming the key, the holder, and how to restructure.
#    Never a silent wait.
```

```bash
bundle exec rspec spec/ruby_reactor/step_coordination/reentrancy_spec.rb
```

## Scenario 4 — rollback runs under the same exclusivity (US6)

```ruby
# :charge succeeds holding "acct:1", a later step fails, rollback reaches :charge
# => the compensation runs holding "acct:1"
# => a concurrent execution cannot enter :charge's forward work while it runs
```

Rate ceilings and dedup windows are deliberately *not* applied to compensation — cleanup is
never suppressed by a forward-work quota.

```bash
bundle exec rspec spec/ruby_reactor/step_coordination/rollback_spec.rb
```

## Scenario 5 — the other primitives (US5)

```bash
bundle exec rspec spec/ruby_reactor/step_coordination/primitives_spec.rb
```

Asserts, one per primitive:

- semaphore: at most N inside the step's work per key
- rate limit: further executions of the step contend rather than exceed the rate
- dedup window: the **step** is skipped and the workflow continues — the reactor is not halted
- ordered lock: executions pass through the step in sequence; stop-the-line short-circuits that
  step for later positions

## Scenario 6 — end to end against real infrastructure

```bash
docker compose run --rm demo-app bin/rails demo:step_lock
```

**Expected output**: the serialized path (two executions, non-overlapping step bodies), the
contended path (one parked and retried, both completing), and the compensated path (rollback
holding the same key).

## Full suite

```bash
docker compose up -d redis-test
bundle exec rspec
bundle exec rubocop

docker compose run --rm demo-app bundle exec rspec spec/reactors/step_lock_demo_reactor_spec.rb
docker compose run --rm demo-app bin/rails demo:step_lock
```

## Acceptance checklist

| # | Claim | Verified by |
|---|---|---|
| SC-001 | Same-key step bodies never overlap | Scenario 1, sustained concurrent run |
| SC-002 | Unrelated steps still overlap | Scenario 1 |
| SC-003 | Released within one step boundary, all outcomes | Scenario 1 + failure/raise cases |
| SC-004 | Contention costs zero compensations | Scenario 2 |
| SC-005 | Worker path protected identically to in-process | Scenarios 1 and 6 |
| SC-006 | Nested holds on one key complete without self-waiting | Scenario 3 |
| SC-007 | Deadlocking hand-offs refused at dispatch | Scenario 3 |
| SC-008 | Killed holder frees the key without operator action | kill-process test in lock_spec |
| SC-009 | Compensation runs under the same exclusivity | Scenario 4 |
| SC-010 | Operator can see step, key, holder; park ≠ failure | dashboard + log assertions |
| SC-011 | Uncomputable key never runs the work | lock_spec |
| SC-012 | Existing reactor-level coordination tests unchanged | full suite |
| SC-013 | Demo shows serialized, contended, compensated | Scenario 6 |
