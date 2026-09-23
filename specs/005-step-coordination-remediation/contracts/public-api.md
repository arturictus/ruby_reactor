# Contract: Public API Changes

**Feature**: [../spec.md](../spec.md) | **Data model**: [../data-model.md](../data-model.md)

All changes are additive or are behavior fixes to documented guarantees. SemVer: **MINOR**.

## 1. DSL: `rollback_wait:` (FR-001, FR-002)

```ruby
class ChargeStep < RubyReactor::Step
  input :account_id

  # rollback_wait defaults to ttl (60 here)
  with_lock(ttl: 60, wait: 0, rollback_wait: nil) { |a| "acct:#{a[:account_id]}" }

  # rollback_wait defaults to 60 for a semaphore
  with_semaphore(limit: 3, wait: 0, rollback_wait: nil) { |a| "gw:#{a[:account_id]}" }
end
```

| Macro | New keyword | Default | Applies to |
|---|---|---|---|
| `with_lock` | `rollback_wait:` | `nil`, meaning `ttl` | the step's `undo` and `compensate` |
| `with_semaphore` | `rollback_wait:` | `nil`, meaning 60 s | the step's `undo` and `compensate` |

- Inline steps (`step :x do … with_lock(…) end`) accept the same keyword, through
  `StepBuilder`'s shared `Lockable::ClassMethods`.
- On a **reactor**, `rollback_wait:` is accepted and ignored, because reactor-level holds are
  not re-taken for rollback. The docs say so.
- Rollback behavior:
  - It waits up to `rollback_wait` for the key, on the synchronous and the worker path alike.
  - It never parks.
  - If the key is still unavailable, the undo does not run and the entry is reported (§2).
- Unchanged: `with_rate_limit`, `with_period` and `with_ordered_lock` are still not applied to
  rollback.

## 2. `RubyReactor::Failure#rollback_failures` (FR-004)

```ruby
result = OrderReactor.run(order_id: 1)
result.failure?            # => true
result.rollback_failures
# => [{ step: :charge, kind: :undo, key: "acct:7",
#       reason: :coordination_unavailable,
#       message: "could not re-acquire lock 'acct:7' for rollback of :charge within 60s" }]
```

- Always an Array, empty when every undo and compensation completed.
- `reason` is one of `:coordination_unavailable`, `:returned_failure` or `:raised`.
- Present in `Failure#to_h` under `:rollback_failures`. It survives the async failure record,
  so a background run's stored `failure_reason` carries it too.
- It covers undos of completed steps, including steps inside composed children (flattened),
  and the failing step's own compensation.
- It does not cover map elements or `async_reactor` children. Those have their own records.

## 3. Step-level strict ordering outcomes (FR-010–FR-016)

| Situation | Before | After |
|---|---|---|
| Synchronous out-of-turn arrival | Contention Failure, and the chain is poisoned: later strict positions are `Skipped(:ordered_lock_chain_failed)` | Contention Failure, and the position is handed back. Later positions run. |
| The step's batch expired (retry after `poison_pill_timeout`) | The body runs unordered | `Skipped(reason: :ordered_lock_stale_batch)`, and the body does not run |
| The step body exits with a `NoMemoryError`, `SystemStackError` or similar | The heartbeat runs until the process exits | The heartbeat stops, and the poison pill releases the position |
| The position reached the head and then failed | The chain is poisoned | Unchanged |

`Skipped#reason` can now be `:ordered_lock_stale_batch` at step level. That value already
exists as a reactor-level `Halt` reason.

## 4. Middleware

| Change | Detail |
|---|---|
| New event `:snooze_step` | `on_snooze_step(step_name, error, context)`. It fires when a step's attempt ends in a park, for contention or an awaited background result, at any nesting depth. `:failed_step` never fires for a park. Middlewares without the method are unaffected. |
| Documented attribution | `context.coordinating_step` names the step for a step-level coordination event, and is `nil` for a reactor-level one, on every run including resumed ones. `context.current_step` is the execution's resume cursor and must not be used for attribution. |
| Direct `Step.run` | Coordination events and `Contended` messages from a directly invoked step class name that class, not the calling step. |
| OpenTelemetry | `on_snooze_step` finishes the step span with `step.status = "parked"` and status OK. |

## 5. Park behavior (FR-006–FR-009)

There is no new API. These are the guarantees now true at every nesting depth, for contention
parks and for background-result parks alike:

- Every workflow level keeps the lock and semaphore it held before the park, and re-adopts them
  on redelivery. There is no duplicate `:lock_acquired`.
- Reactor-level `with_rate_limit` and `with_period` are applied once per execution.
- A background-result wait inside a composed child parks the execution. Before, it failed the
  parent (F10).
- Contention parks keep their own counter and the `lock_snooze_max_attempts` ceiling.

## 6. Internal and not public (named here so a reviewer does not mistake them for API)

- `Error::ExecutionParked`, `Error::StepContentionPark`. These are internal signals. They
  escape only when a caller drives `Executor` directly with `inline_async_execution = true`,
  which is what the gem's own specs do.
- `private_data[:admitted]`, and the Step Result Record fields `ordered_lock` and `waiting`.
- Removed internals: `on_contention_park`, `RetryManager#park_for_contention`, and
  `RetryQueuedResult` as a contention outcome. `RetryQueuedResult` is still returned for
  failure retries.
