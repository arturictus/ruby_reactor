# Public DSL Contract: Step-Scoped Coordination

**Feature**: `specs/003-step-lock-declarations/` | **Date**: 2026-09-10

The gem's external interface is its DSL. This document is what the specs assert against and
what `documentation/locks_and_semaphores.md` must match.

## 1. The five macros, now available on steps

Identical signatures to the reactor-level forms (`Dsl::Lockable`). The only difference is what
the key proc receives: **the step's `inputs`** — resolved arguments with contract defaults
applied, the same hash the instance's `run` reads — where the reactor form receives the
reactor's inputs.

```ruby
class ChargeStep < RubyReactor::Step
  input :account_id
  input :amount

  with_lock(ttl: 60, wait: 0, auto_extend: true) { |args| "acct:#{args[:account_id]}" }

  def run
    Success(charge!(inputs))
  end
end
```

| Macro | Step-scoped meaning |
|---|---|
| `with_lock { \|args\| key }` | At most one execution inside this step's work per key |
| `with_semaphore(limit: N) { \|args\| key }` | At most N executions inside this step's work per key |
| `with_rate_limit(limit:, period:) { \|args\| key }` | At most X executions of this step per window per key. `with_rate_limit(:name)` still references a registered global limit |
| `with_period(every:) { \|args\| key }` | This step runs at most once per bucket per key. **The step is skipped**; the workflow continues |
| `with_ordered_lock { \|args\| key }` | Executions pass through this step in sequence per key |

### `with_period` differs from the reactor form

Reactor-level `with_period` halts the whole reactor when the bucket is marked. At step level
that would kill a workflow over one deduplicated step, so the **step** is skipped and the
following steps run. A step returning `Skipped` behaves as it does anywhere else.

### `with_ordered_lock` provides a weaker guarantee than its reactor namesake

The reactor form assigns its position at enqueue time, so it orders executions by enqueue. A
step's key is computed from arguments that do not exist until the step is reached, so the step
form orders executions **by arrival at that step**. For a step that sits first in its reactor
the two coincide; the deeper the step, the weaker the promise. This is documented on the macro
itself, not only here.

## 2. Inline steps

```ruby
step :charge do
  with_lock { |args| "acct:#{args[:account_id]}" }

  argument :account_id, input(:account_id)
  run { |args, _| charge!(args) }
end
```

Same macros, same behavior as the class form.

## 3. Where it is enforced

Acquisition happens after guards and after argument validation — both the reactor-side
`argument` validators and the step class's own `input` contract — so a step that will be
skipped or will fail validation never takes a hold.

| Order | Taken | Released |
|---|---|---|
| 1 | Ordered-lock gate (nothing else held while waiting for a turn) | last |
| 2 | Dedup window, fast check | — |
| 3 | Exclusive lock | 2nd |
| 4 | Semaphore | 1st |
| 5 | Dedup window, re-check under the lock | marked on success |
| 6 | Rate limit — last, immediately before the work: the one acquisition that cannot be handed back, so no contention can follow a spent slot | — |

A step's EFFECTIVE declarations — on the step class, inline in the reactor's `step` block, or
both — are taken by ONE coordinator in this order. A reactor running a class step calls
`Step.run_without_coordination`; `Step.run` coordinates only direct invocations.

Released in reverse in an `ensure`, on success, failure, or unexpected error.

| Entry point | Coordinated |
|---|---|
| Reactor step execution | ✅ |
| Retried attempt | ✅ each attempt takes and releases |
| `async_step` worker | ✅ taken in the worker, never in the dispatcher |
| `background` hand-off worker | ✅ |
| Resume after interrupt | ✅ |
| Each `map` iteration | ✅ |
| `ChargeStep.run(args)` / `.run(args, nil)` directly | ✅ its own execution: contends with every holder, including running reactors; wait-then-fail |
| `ChargeStep.run(args, context)` from inside a step body | ✅ part of that execution: re-entrant on keys it already holds, contends on any other key. Never parks: losing that contention fails the CALLING step as an ordinary error (compensated, never parked and re-run) |
| `compensate` / `undo` | ✅ exclusion primitives only — see §6 |
| Step suppressed by `where`/guard | ❌ by design |
| Interrupt step | ❌ declaring coordination on one raises |

## 4. Contention

| Execution path | Behavior |
|---|---|
| Running in a worker | The execution is **parked** and retried later. No step compensates; the contended step's work has not been attempted. |
| Running synchronously | Waits up to the configured `wait:`, then fails with a contention error naming reactor, step, and key. Rollback proceeds as for any step failure. |

A park releases everything the contended step took — its work has not started — and keeps only
its ordered-lock position. Coordination the execution held before reaching the step (reactor
level) stays checked out across the gap (§5).

Contention attempts are counted separately from failure retries and bounded by a configurable
ceiling; exceeding it turns the park into a contention failure. A busy key can therefore never
exhaust the retry budget meant for genuine failures, nor snooze forever.

## 5. Re-entrancy

Identical to nested reactors — same primitives, no second rule set:

- Holds are owned by the **execution** (its root context), so a step keyed the same as its own
  reactor, or nested work inside a locked step, proceeds without waiting.
- A step class called directly is coordinated the same way (the lock is taken inside
  `Step.run`). Without a context it is its own execution and gets no re-entrancy; pass the
  current `context` to join the execution. Re-entrancy covers only keys the execution already
  holds — a different key is always contended.
- Nested holds on one key are counted; the key frees for other executions only when the
  outermost hold is released.
- The keys an execution holds are tracked for the execution as a whole.
- **Ownership never crosses a process hand-off.** Dispatching work that declares a key the
  execution currently holds is refused before dispatch, with a message naming the key, the
  holder, and how to restructure. This now covers `async_step` dispatch as well as
  `async_reactor`.
- An execution that parks while holding coordination taken before the contended step re-adopts it on resume without recording a
  second acquisition, falling back to competing normally if the hold lapsed.

## 6. Rollback

| Primitive | Re-taken for compensate/undo |
|---|---|
| `with_lock`, `with_semaphore` | ✅ same key, computed from the same arguments |
| `with_rate_limit`, `with_period`, `with_ordered_lock` | ❌ a forward-work quota must never suppress cleanup |

Compensation that cannot acquire within its wait is reported, never silently skipped. It does
not park — the execution is already mid-failure.

## 7. Errors

| Situation | Outcome |
|---|---|
| Key proc raises, or returns nil/empty | Step fails before its work runs, naming step and cause |
| Contention, synchronous | `Lock::AcquisitionError` / `Semaphore::AcquisitionError` / `RateLimit::ExceededError`, naming reactor, step, key |
| Contention ceiling exceeded | Contention failure with the attempt count |
| Coordination declared on an interrupt step | Raises at declaration, pointing at reactor-level coordination |
| Hand-off would deadlock | Failure at dispatch naming key, holder, and remedies |
| Backing store unreachable | Step fails with the cause; work never runs unprotected |

## 8. Observability

- Acquisition, release, and acquisition failure are distinct events carrying the key and the
  owning step.
- A contention-parked execution is reported distinctly from a failure — a snooze round must not
  read as a phantom failure.
- The dashboard's coordination view shows step-level holds alongside reactor-level ones,
  identified by step.

## 9. Compatibility

- Additive. A step declaring nothing behaves exactly as today.
- Reactor-level declarations are unchanged in syntax and behavior.
- Guidance: reactor level for "this whole workflow is exclusive", step level for "this one
  operation is exclusive". Step level keeps the critical section small, so prefer it when only
  part of the workflow needs protection.
