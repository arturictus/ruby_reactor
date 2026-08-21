# Feature Specification: Background Execution & Real Async Steps

**Feature Branch**: `001-background-async-steps`

**Created**: 2026-08-16

**Status**: Draft

**Input**: User description: "I want to rename to fix some confusing naming and create a feature for proper async steps. The current async naming doesn't makes much sense, it should be renamed to background... The other change is to for real do async steps and reactors. Understanding an async step running in an independent process, sidekiq worker in this case..."

## Clarifications

### Session 2026-08-16

- Q: When an `async_step`'s independent worker fails and nothing in the parent reactor is waiting on its result, should the parent's saga compensation trigger automatically? → A: No. `async_step` and `async_reactor` share the same compensation model — a failure only surfaces, and compensation only happens, if a later step explicitly reads that step's/reactor's result via `result(:name)` and itself decides to return `Failure`. An async unit's own failure never automatically compensates its parent.
- Q: When a step still running in the calling process reaches a `result(:name)` reference that isn't ready yet, how should the wait be implemented? → A: The calling thread blocks in a bounded poll loop against the durable store until the result appears or the timeout elapses. The reactor's existing synchronous `.run` call contract is unchanged — waiting never implicitly hands remaining execution off to a worker.
- Q: How should the FR-005 wait timeout be configured? → A: A single library-wide default set via the existing global `Configuration` is sufficient for v1; no per-reactor or per-`result()` override syntax is introduced by this feature.

### Session 2026-08-20

- Q: Is a tight poll loop good enough for the FR-005 wait, or should completion be pushed to the waiter? → A: Revised (supersedes the "bounded poll loop" mechanism from the 2026-08-16 session; the blocking-on-the-calling-thread contract and the timeout bound are unchanged): the primary wake-up is a completion notification — the finishing worker durably writes the result record **first**, then publishes a completion signal; the waiter subscribes **before** checking the record (closing the completed-before-subscribe race), then blocks on the notification with a coarse periodic fallback re-check of the record (notifications are at-most-once and may be missed on reconnect — the durable record remains the sole source of truth, so a missed signal degrades to fallback-poll latency, never to a wrong answer). The FR-005 timeout still bounds the total wait.
- Q: Should locks be reentrant across the `async_reactor` boundary, to avoid deadlocks when parent and child declare the same lock key? → A: No. Owner-based reentrancy stays as-is for `compose` (sequential, same logical thread of control), but an `async_reactor` child runs concurrently with its parent — sharing the lock owner would put both inside the critical section at once, silently breaking mutual exclusion, which is worse than the deadlock. Instead the deadlock is made impossible to hit silently: at dispatch time, if the child's lock key collides with a lock the parent execution currently holds, the dispatch step fails immediately with a clear error (see FR-015) rather than guaranteeing a wait-timeout later.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Unambiguous background hand-off (Priority: P1)

A reactor author currently marks a step `async: true` to hand execution off to a background worker, but if several steps carry that flag only the first one actually takes effect — the rest are silently ignored. The author wants one clear, reactor-level declaration that says "everything after this step runs in the background," with no ambiguity about which point is the real hand-off.

**Why this priority**: This is a correctness and clarity fix on an existing, already-shipped capability. It removes a footgun that silently produces wrong behavior today, and it is the foundation the other stories build on.

**Independent Test**: Define a reactor with `step :first`, `step :second`, `background after: :second`, `step :third`. Confirm `:first` and `:second` run in the calling process, and `:third` runs after hand-off to a worker process. Confirm the reactor definition has no remaining per-step async flag.

**Acceptance Scenarios**:

1. **Given** a reactor with `background after: :second` declared once, **When** the reactor executes, **Then** steps before and including `:second` run in the current process and steps after `:second` run via an independent worker.
2. **Given** a reactor definition that still uses the old per-step `async: true` flag, **When** the reactor class is loaded/defined, **Then** the system raises a clear definition-time error identifying the deprecated syntax instead of silently accepting it.
3. **Given** a reactor with a `background after:` declaration naming a step that is not defined in that reactor, **When** the reactor class is defined, **Then** the system raises a clear definition-time error.

---

### User Story 2 - Async steps that truly run independently (Priority: P2)

A reactor author wants a single step (e.g. `send_email`) to execute in an independent worker process while the rest of the reactor keeps running in the current process. A later step in the same reactor needs to consume that async step's output once it is ready.

**Why this priority**: This is the first genuinely new capability — running one unit of work off the critical path while the reactor continues — and it is the dependency other in-reactor steps rely on via `result(...)`. Compensation for an `async_step`'s failure is opt-in via that same `result(...)` read, not automatic (see Clarifications).

**Independent Test**: Define a reactor with `async_step :send_email`, followed by `step :do_something_same_thread`, followed by `step :check_email` that declares `argument :email, result(:send_email)`. Confirm `:do_something_same_thread` can complete without waiting on `:send_email`, and `:check_email` receives the correct, fully-formed result of `:send_email` once it becomes available.

**Acceptance Scenarios**:

1. **Given** a reactor with `async_step :send_email` followed by a same-process step with no dependency on it, **When** the reactor executes, **Then** the same-process step is not blocked waiting for `:send_email` to finish.
2. **Given** a later step that declares `argument :email, result(:send_email)`, **When** that step is reached before `:send_email` has completed, **Then** the reactor waits for `:send_email`'s durable result before running the step, and injects the deserialized result as the argument.
3. **Given** an `async_step` that raises/fails in its independent worker, **When** the failure occurs and no later step reads its result, **Then** the owning reactor's saga compensation is NOT automatically triggered; the failure is recorded/logged only. Compensation only happens if a later step reads `result(:send_email)` and, on seeing a failure, itself returns `Failure`.

---

### User Story 3 - Fire-and-forget async reactors (Priority: P3)

A reactor author wants to kick off an entire nested reactor (e.g. `create_profile`) to run independently, tracked for observability but explicitly outside the parent reactor's compensation graph — its failure should never automatically roll back the parent. For cases where the parent does care about the outcome (e.g. `create_account`), a later step should be able to read the async reactor's result and decide for itself whether to trigger compensation.

**Why this priority**: This extends story 2's independent-execution model from a single step to a whole nested reactor, and is the most involved because it touches the saga/compensation boundary between parent and child.

**Independent Test**: Define a reactor with `async_reactor :create_profile` and no step referencing its result — confirm a forced failure of `create_profile` does not compensate the parent. Separately, define `async_reactor :create_account` followed by `step :verify_all` with `argument :account, result(:create_account)` and a `run` block that inspects success/failure — confirm the block receives the account reactor's outcome and can choose to return `Failure` (triggering parent compensation) or `Success`.

**Acceptance Scenarios**:

1. **Given** an `async_reactor :create_profile` with no downstream step reading its result, **When** `create_profile`'s execution fails, **Then** the parent reactor's already-completed steps are not compensated as a result of that failure.
2. **Given** an `async_reactor :create_account` and a later step that declares `argument :account, result(:create_account)`, **When** the parent reaches that step before `create_account` has finished, **Then** the parent waits for `create_account`'s durable result before running the step.
3. **Given** the `run` block of `:verify_all` inspecting `args[:account]` and explicitly returning `Failure`, **When** that block executes, **Then** the parent reactor's compensation is triggered as it would be for any other step returning `Failure`.
4. **Given** an `async_reactor` execution, **When** it starts, **Then** its execution id is linked to the parent reactor's execution for traceability (e.g. in logs/dashboard), without adding it to the parent's compensation graph.

---

### Edge Cases

- What happens when a reactor declares `background after:` more than once? → System MUST reject the reactor definition at definition time with a clear error (see FR-002); only a single hand-off point is permitted.
- What happens when a step waiting on `result(:async_step_name)` never receives a result because the independent worker crashed or never ran? → Governed by the wait policy in FR-005.
- What happens when `async_step`/`async_reactor` is declared but nothing ever references its result? → It still executes to completion in its independent worker; no waiting occurs anywhere in the parent.
- What happens when an `async_step` is declared after a `background after:` hand-off point? → The async step's work is already off the calling process by virtue of the hand-off; it still runs in its own independent worker and follows the same result/wait/failure semantics.
- What happens if a reactor is recovered/resumed (crash recovery) while one of its `async_step`/`async_reactor` results is still pending? → Recovery MUST re-attach to the still-pending async work rather than re-dispatching it, consistent with existing durability/recovery guarantees.
- What happens when `returns` names an `async_step` or `async_reactor`? → Rejected at definition time with a clear error: the reactor's return value must come from a same-process step. A reactor that needs an async unit's outcome as its return value must read it through an ordinary step (`argument :x, result(:name)`) and return that step instead. (Allowing it would make reactor completion itself block or return an absent value — out of scope for v1.)
- What happens when a reactor marked with the whole-reactor async flag also declares `background after:`? → Rejected at definition time: the entire reactor already runs in a worker, so a hand-off point inside it is meaningless and would otherwise be silently ignored — the exact silent-no-op failure mode this feature exists to eliminate.
- What happens when an awaited `async_reactor`'s child pauses at an interrupt step instead of finishing? → Paused is not terminal, so the reader's wait continues and, if the child is not resumed within the bound, ends in the FR-005 timeout failure. Documented behavior, not an error: an operator resumes the child (existing interrupt mechanism) and a retry of the reading step then finds the result.
- What happens when an `async_reactor`'s child declares the same exclusive-lock key its parent currently holds? → The dispatch step fails immediately with a clear error (FR-015). Without this guard the pattern is a guaranteed deadlock-until-timeout: the parent holds the lock for its whole execution (including any wait on the child's result) while the child snoozes waiting for that same lock. A child that genuinely needs to share the parent's critical section belongs in `compose`, not `async_reactor`.
- What happens when the completion notification is lost (waiter reconnecting, signal published before subscribe)? → Nothing is lost but latency: the durable record is written before the signal is published, the waiter checks the record after subscribing, and a coarse fallback re-check catches any missed signal within the FR-005 bound.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST provide a reactor-level `background after: <step_name>` declaration that marks the point after which all remaining steps execute via an independent worker process.
- **FR-002**: System MUST reject, at reactor-definition time, any reactor that declares `background after:` more than once, or that names a step not defined in that reactor.
- **FR-003**: System MUST remove the per-step hand-off `async` flag/DSL method entirely — both on regular steps and on `compose` steps (which carry the same flag) — and reactors still using it MUST fail at definition time with an error that names the deprecated syntax and points to its replacement (`background`, `async_step`, `async_reactor`). The `async` option inside a `map` block is NOT covered by this removal: it is a map-internal element-dispatch mode, a different mechanism with different semantics, and stays as-is.
- **FR-004**: System MUST provide an `async_step` declaration whose work executes in an independent worker process, without blocking other same-process steps that do not depend on it.
- **FR-005**: When any step declares `argument :x, result(:name)` referencing an `async_step` or `async_reactor` named `:name` that has not yet completed, System MUST block the executing process/thread — without implicitly changing the reactor's synchronous execution mode — until the durable result is available or a single library-wide configurable timeout (set via the existing global `Configuration`, no per-reactor or per-reference override in this feature) is exceeded, then fail that step with a clear timeout error. The wait MUST be notification-driven (completion signal published by the finishing worker after the durable record is written; waiter subscribes before checking the record) with a coarse periodic fallback re-check of the durable record, so that the common case completes with near-zero added latency and a missed notification degrades only to fallback-poll latency, never to a wrong or lost result (see Clarifications, Session 2026-08-20).
- **FR-006**: System MUST durably persist `async_step` and `async_reactor` outcomes using the existing serialization mechanism — an `async_reactor`'s outcome through the nested execution's own persisted state, an `async_step`'s outcome in a durable per-step record — so that a dependent step deserializes the same result shape a same-process step would produce.
- **FR-007**: System MUST provide an `async_reactor` declaration that dispatches a nested reactor to run in an independent worker process.
- **FR-008**: System MUST link an `async_reactor`'s execution id to the parent reactor's execution/context for traceability (logs, dashboard) without adding that nested execution to the parent's compensation graph. This link MUST be recorded on the parent's own context (in the same structural location the system already uses to reference other child executions, e.g. `compose`/`map`), not only in an external log line, so it survives independently of logging configuration and can be reloaded/queried later.
- **FR-009**: System MUST NOT automatically trigger parent-reactor compensation when an `async_reactor`'s execution fails; the parent's own steps MUST remain the only place compensation for that parent is decided.
- **FR-010**: A step in the parent reactor MUST be able to reference an `async_reactor`'s result via `result(:name)` the same way it references an `async_step`'s result, subject to the wait/timeout policy in FR-005, and inspect that result's success/failure to decide whether to return `Success` or `Failure` itself.
- **FR-011**: If an `async_step` fails in its independent worker, System MUST NOT automatically trigger the owning reactor's saga compensation — the same fire-and-forget compensation model as `async_reactor` (see FR-009). Compensation for an `async_step` failure MUST only happen when a later step explicitly reads its result via `result(:name)` and itself decides to return `Failure`.
- **FR-012**: System MUST emit structured log entries (reactor name, step name, execution id) for: background hand-off, `async_step` dispatch and completion, and `async_reactor` dispatch and completion.
- **FR-013**: System MUST document the breaking change (removal of the per-step `async` flag) with a migration note, per the project's semantic-versioning policy for public API changes.
- **FR-014**: The existing web dashboard MUST render `async_step` and `async_reactor` as distinct, recognizable step types (not fall back to a generic/unknown type), and MUST let an operator drill into an `async_reactor`'s linked execution the same way it already lets them drill into a `compose`d or `map`ped child, using the FR-008 link recorded on the parent's context.
- **FR-015**: Exclusive-lock ownership MUST NOT be shared across the `async_reactor` boundary (parent and child run concurrently — shared ownership would break mutual exclusion). Instead, at dispatch time, if the child reactor declares an exclusive lock whose resolved key equals a lock currently held by the dispatching execution, the dispatch step MUST fail immediately with an error naming both the lock key and the parent/child reactors — never proceed into a wait that can only end in timeout. Lock reentrancy for `compose` (same logical thread of control) is unchanged.
- **FR-016**: Dispatching an `async_reactor` MUST apply the same pre-enqueue safeguards as a top-level asynchronous reactor run — child input validation and, where the child declares ordered locking, enqueue-time ordering assignment — so a child never starts with invalid inputs or silently lose ordering guarantees. A dispatch-time validation failure fails the dispatching step itself (normal saga handling in the parent), distinct from a failure during the child's independent execution (which follows FR-009).

### Key Entities

- **Background Hand-off Point**: The single `background after: <step_name>` declaration in a reactor that marks where remaining execution moves from the calling process to an independent worker.
- **Async Step**: A step whose unit of work executes in an independent worker process, producing a durably stored result that other steps in the same reactor may depend on and wait for.
- **Async Reactor**: A nested reactor execution dispatched to an independent worker, linked to its parent's context by execution id (in the same structural location `compose`/`map` already use, so the dashboard can render and drill into it) for traceability, but excluded from the parent's automatic compensation graph.
- **Step Result Record**: The durable, serialized record of a completed async step's output, keyed for lookup by any step that references it via `result(:name)`. (An async reactor's output is reached through that nested execution's own durable record rather than a separate copy.)

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Reactor authors can express a background hand-off with exactly one declarative line per reactor, and zero reactor definitions in the codebase reference the old per-step async flag after migration.
- **SC-002**: In a reactor with an `async_step`, same-process steps that do not depend on it complete without waiting on it, while a step that explicitly depends on its result always receives the correct, fully-deserialized result once available.
- **SC-003**: An `async_step`'s or `async_reactor`'s failure never causes the parent reactor's completed steps to be rolled back unless a later step explicitly reads its result and triggers compensation itself — verified across repeated failure-injection runs with zero unintended rollbacks.
- **SC-004**: 100% of reactor definitions still written against the old per-step async flag fail fast at definition time with an actionable error, rather than silently running with incorrect behavior.
- **SC-005**: A step waiting on an async result is never left hanging indefinitely — it either receives the result or a clear timeout failure within the configured bound, in all tested scenarios.
- **SC-006**: An operator viewing a running reactor in the dashboard can identify every `async_step` and `async_reactor` it launched and, for `async_reactor`, open the linked execution — with zero manual log-correlation required.

## Assumptions

- The project's existing pluggable job backend (Sidekiq or ActiveJob, selected via `configuration.async_router`) remains the independent worker mechanism for background hand-off, `async_step`, and `async_reactor` dispatch — this feature does not hardcode Sidekiq and must work identically on either configured backend.
- Redis remains the durable store for step/reactor results, consistent with the project's existing durability model.
- "Independent process" means a separate worker job (a new Sidekiq or ActiveJob job, per the configured backend), not a thread or fiber within the originating process.
- This is a breaking (MAJOR, per SemVer) change to the public step DSL; updating `README.md`, `CHANGELOG.md`, and `demo_app/` to the new syntax is required delivery work but not itself a testable acceptance criterion of this spec.
- The wait timeout for `result()` references to async work (FR-005) is a single library-wide value exposed via the existing global `Configuration`; per-reactor or per-reference overrides are out of scope for this feature.
