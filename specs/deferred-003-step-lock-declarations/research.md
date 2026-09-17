# Phase 0 Research: Step-Scoped Coordination

**Feature**: `specs/003-step-lock-declarations/` | **Date**: 2026-09-10

Findings come from reading the current implementation. File references are to the state of
`step_validations` at the time of writing.

## Current state

| Concern | Where it lives |
|---|---|
| Declaration DSL | `Dsl::Lockable::ClassMethods` — `with_lock`, `with_semaphore`, `with_rate_limit`, `with_period`, `with_ordered_lock`. Included into `Reactor` only. |
| Acquisition | `Executor#acquire_locks` → `check_rate_limit`, `acquire_exclusive_lock`, `acquire_semaphore` (`executor.rb:350-360`) |
| Key derivation | `config[:key_proc].call(@context.inputs)` — reactor inputs |
| Owner | root context id (`executor.rb:501`) — the basis of re-entrancy |
| Held-key registry | `root.private_data[:held_lock_keys]` |
| Deadlock guard | `Step::AsyncReactorStep.detect_lock_deadlock` (`async_reactor_step.rb:65`) — refuses dispatch when the child declares a key the parent holds |
| Park / resume | `park_held_primitives!` + `consume_parked_primitives!`; `Lock#detach` / `#reattach` |
| Contention split | `Executor#contention_wait` (`executor.rb:566`) — `0` inside a worker (snooze instead of blocking), configured wait otherwise |
| Step retry requeue | `RetryManager#requeue_job_for_step_retry` — sets `current_step`, persists root context, `perform_in(delay, …)`, returns `RetryQueuedResult` |
| Ordered lock | `Executor::OrderedLockSupport` — nonce assigned at enqueue in `Reactor#run`, stashed in `private_data[:ordered_lock]`, gate at execute/resume, advance on terminal reactor result, heartbeat thread |
| Compensation | `CompensationManager#compensate_step` / `#undo_step` |
| Dashboard | `Web::CoordinationSerializer` — reads `reactor_class.lock_config` etc. |

### Finding 1 — the DSL needs no redesign, only a second host

`Dsl::Lockable::ClassMethods` is already a self-contained module of five macros whose only
contract is "a key proc that receives a hash". Reactor passes `context.inputs`; a step would
pass its resolved arguments. The declaration surface is reusable as-is, including its
`inherited` hook for subclass propagation.

### Finding 2 — `contention_wait` already encodes the sync/worker split the spec asks for

FR-015/FR-016's split is not new policy: `contention_wait` returns `0` inside a worker so the
job snoozes rather than blocking a thread, and the configured wait outside. Step-level
coordination gets the correct behavior on both paths by reusing it.

### Finding 3 — parking an execution at a step already exists

`requeue_job_for_step_retry` persists the root context with `current_step` set and enqueues a
delayed job; the redelivery resumes at that step. It is reached today only from retry-on-
failure, but nothing in it is failure-specific. Step contention can reuse it verbatim with a
contention delay, which is why FR-015 ("park, don't fail") costs one call rather than a new
mechanism.

### Finding 4 — the deadlock guard is keyed on the registry, not on reactors

`detect_lock_deadlock` reads `held_lock_keys` from the root context and compares against the
*child's* declared keys. Because step-held keys will land in the same registry, the existing
guard covers "a step holds K, its body dispatches an async_reactor that wants K" with no
change. It needs extending only to know about `async_step` dispatch, where the dispatched
step class may itself declare K.

### Finding 5 — ordered lock is structurally reactor-shaped

The nonce is assigned in `Reactor#run` at enqueue time, before any step exists, and the
advance fires on the *reactor's* terminal result. Its guarantee is "executions run in the
order they were enqueued". A step-level equivalent cannot assign at enqueue, because the key
expression reads arguments that are not resolved until the step is reached — so its guarantee
degrades to "in the order executions reached this step", which is a materially weaker promise.
See D8; this is the one primitive whose step-scoped meaning is not a simple narrowing.

### Finding 6 — a step holding coordination across a park is nearly unreachable

Argument resolution (including any blocking wait on an async result) happens *before*
acquisition, and a step whose body is dispatched elsewhere never acquires in the dispatching
process. The one construct that could hold coordination across a park is an interrupt step,
whose body is split across a pause. See D6.

---

## Decisions

### D1 — Steps host the existing `Lockable` macros unchanged

`RubyReactor::Step::ClassMethods` gains the same five macros by reusing
`Dsl::Lockable::ClassMethods`; `Dsl::StepBuilder` gains them for inline steps. The key proc
receives the step's resolved arguments instead of reactor inputs.

**Rationale**: Finding 1. One declaration surface, one set of option semantics, one place to
document. Authors already know the macros.

**Alternatives rejected**: a parallel `step_lock` vocabulary — two names for one concept.

### D2 — Enforcement is driven by the executor, not by a wrapper on the step

A single `StepCoordination` object wraps the step body. The executor drives it, because three
requirements are outside a step class's reach: parking the execution on contention (needs the
requeue path), skipping acquisition for a guard-suppressed step, and re-taking coordination
during rollback.

FR-023 (direct invocation) is served by the same object, entered with `park: false` — with no
execution to park, contention waits and then fails, exactly as the synchronous path does.

**Rationale**: this deliberately differs from `002`'s decision to enforce input contracts in a
prepended `run`. Validation is a pure function of the arguments; coordination is a property of
the execution — it parks it, releases it, and must survive into rollback. The two belong at
different layers, and saying so explicitly is cheaper than discovering it later.

### D3 — Fixed acquisition order, mirroring the reactor's

1. Ordered-lock gate (nothing else held while waiting for a turn — the existing hold-and-wait
   guard in `OrderedLockSupport`)
2. Period gate, fast path
3. Rate limit
4. Exclusive lock
5. Semaphore
6. Period gate, re-check under the lock (closes the both-passed race, same as
   `executor.rb:113`)

Released in reverse. Acquisition happens after guards and after argument validation — a step
that will fail validation must not first take a lock (FR-012, and it keeps the critical
section minimal).

### D4 — Contention parks via the step-retry requeue path

On `Lock::AcquisitionError`, `Semaphore::AcquisitionError`, `RateLimit::ExceededError`, or
`OrderedLock::WaitError`:

- **In a worker** (`context.inline_async_execution`): call the requeue path with a contention
  delay and return `RetryQueuedResult`. The delay uses the primitive's own hint where it has
  one (`retry_after_seconds` for rate limits) and a configured contention backoff otherwise.
- **Synchronously**: `contention_wait` has already blocked for the configured wait, so the
  error propagates as an ordinary step failure and rollback proceeds.

Contention attempts are counted separately from failure retries (`retry_context` gains a
contention counter), bounded by a configurable ceiling; exceeding it converts the park into a
contention failure (FR-017). Counting contention against the step's `retries` budget would let
a busy key exhaust the retries meant for genuine failures.

**Alternatives rejected**: failing on both paths — the user's chosen behavior is park-and-
retry; the sync fallback exists only because there is no queue to park into.

### D5 — Re-entrancy reuses every existing primitive verbatim

- **Owner** is the root context id, so a step's hold nests inside its reactor's hold on the
  same key and inside any ancestor's (FR-019).
- **Nesting count** is the adapter's existing re-entrancy count; the key frees at zero (FR-020).
- **Registry**: step-held keys are pushed to and popped from `root.private_data[:held_lock_keys]`
  exactly as reactor-held keys are (FR-021).
- **Deadlock guard**: covered for `async_reactor` with no change (Finding 4); extended so
  `async_step` dispatch also checks the dispatched step class's declared keys against the
  registry (FR-022).
- **Direct invocation** has no context, so the owner is a per-call UUID and no re-entrancy
  applies.

### D6 — Coordination on an interrupt step is refused at declaration

An interrupt step's body is split across a pause, so it is the one construct where a
step-level hold could span a park (Finding 6). Rather than extend `park_held_primitives!` to
carry step-level holds across gaps — new state, new reattach path, new failure mode — v1
raises at declaration time with a message pointing at reactor-level coordination for that case.

Everything FR-018 requires of parked executions continues to work: it describes coordination
the *execution* holds, which is reactor-level and unchanged.

### D7 — Step-level period skips the step

Reactor-level `with_period` halts the whole reactor when the bucket is already marked. At step
level that would kill workflows over one deduplicated step, so the step returns `Skipped` and
the workflow continues (FR-003). The bucket is marked when the step's work succeeds.

### D8 — Step-level ordered lock: nonce assigned on first arrival, sequenced last

The nonce is assigned when an execution first reaches the step, stashed per-step in
`private_data`, and reused across contention redeliveries. The gate advances when the step
reaches a terminal result. Strict chain failure short-circuits that step with `Skipped` rather
than halting the reactor (FR-004).

**Honest caveat**: per Finding 5 this delivers "ordered by arrival at the step", not "ordered
by enqueue". For a reactor whose first step is the ordered one, the two coincide; the further
into a workflow the step sits, the weaker the guarantee. This must be documented on the macro
itself, not just in a spec.

**Sequencing**: this primitive is roughly the same implementation weight as the other four
combined — per-step nonce state, per-step heartbeat, per-step advance-on-terminal, poison-pill
and strict-chain handling at step granularity. It is the last phase, and it is the piece to
cut first if the schedule tightens: phases 1-6 deliver the whole of US1-US4 and US6-US8 without
it. Recorded in Complexity Tracking.

### D9 — Observability extends the existing surfaces

Middleware events gain the step name; `Web::CoordinationSerializer` learns to read step-level
configs alongside reactor-level ones; a contention-parked execution is reported distinctly
from a failure, reusing the `:snooze_reactor` precedent (`executor.rb:166`) so a snooze round
does not appear as a phantom failure.

## Open risks

| Risk | Mitigation |
|---|---|
| Contention behaves differently sync vs. worker | Inherent to the chosen behavior; `contention_wait` makes it one branch, and it is called out in the macro's own documentation. |
| A busy key snoozes an execution indefinitely | Bounded contention counter (D4), separate from the failure-retry budget. |
| Step-level ordered lock's weaker guarantee is mistaken for the reactor-level one | Documented on the macro; demo shows arrival-order explicitly. |
| Lock TTL shorter than a slow step's work | Auto-extend applies to step holds exactly as to reactor holds. |
| Compensation stalls on a contended key | Compensation waits then reports (FR-026); it never parks, because rollback is already mid-failure. |
