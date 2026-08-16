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

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST provide a reactor-level `background after: <step_name>` declaration that marks the point after which all remaining steps execute via an independent worker process.
- **FR-002**: System MUST reject, at reactor-definition time, any reactor that declares `background after:` more than once, or that names a step not defined in that reactor.
- **FR-003**: System MUST remove the per-step `async` flag/DSL method entirely; reactors still using it MUST fail at definition time with an error that names the deprecated syntax and points to its replacement (`background`, `async_step`, `async_reactor`).
- **FR-004**: System MUST provide an `async_step` declaration whose work executes in an independent worker process, without blocking other same-process steps that do not depend on it.
- **FR-005**: When any step declares `argument :x, result(:name)` referencing an `async_step` or `async_reactor` named `:name` that has not yet completed, System MUST block the executing process/thread in a bounded poll loop against the durable store, without implicitly changing the reactor's synchronous execution mode, up to a single library-wide configurable timeout (set via the existing global `Configuration`, no per-reactor or per-reference override in this feature), then fail that step with a clear timeout error if the bound is exceeded.
- **FR-006**: System MUST persist `async_step` and `async_reactor` results using the existing durable step-result storage and serialization mechanism, so that dependent steps deserialize the same result shape as a same-process step would produce.
- **FR-007**: System MUST provide an `async_reactor` declaration that dispatches a nested reactor to run in an independent worker process.
- **FR-008**: System MUST link an `async_reactor`'s execution id to the parent reactor's execution/context for traceability (logs, dashboard) without adding that nested execution to the parent's compensation graph.
- **FR-009**: System MUST NOT automatically trigger parent-reactor compensation when an `async_reactor`'s execution fails; the parent's own steps MUST remain the only place compensation for that parent is decided.
- **FR-010**: A step in the parent reactor MUST be able to reference an `async_reactor`'s result via `result(:name)` the same way it references an `async_step`'s result, subject to the wait/timeout policy in FR-005, and inspect that result's success/failure to decide whether to return `Success` or `Failure` itself.
- **FR-011**: If an `async_step` fails in its independent worker, System MUST NOT automatically trigger the owning reactor's saga compensation — the same fire-and-forget compensation model as `async_reactor` (see FR-009). Compensation for an `async_step` failure MUST only happen when a later step explicitly reads its result via `result(:name)` and itself decides to return `Failure`.
- **FR-012**: System MUST emit structured log entries (reactor name, step name, execution id) for: background hand-off, `async_step` dispatch and completion, and `async_reactor` dispatch and completion.
- **FR-013**: System MUST document the breaking change (removal of the per-step `async` flag) with a migration note, per the project's semantic-versioning policy for public API changes.

### Key Entities

- **Background Hand-off Point**: The single `background after: <step_name>` declaration in a reactor that marks where remaining execution moves from the calling process to an independent worker.
- **Async Step**: A step whose unit of work executes in an independent worker process, producing a durably stored result that other steps in the same reactor may depend on and wait for.
- **Async Reactor**: A nested reactor execution dispatched to an independent worker, linked to its parent by execution id for traceability, but excluded from the parent's automatic compensation graph.
- **Step Result Record**: The durable, serialized record of a completed step's or nested reactor's output, keyed for lookup by any step that references it via `result(:name)`.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Reactor authors can express a background hand-off with exactly one declarative line per reactor, and zero reactor definitions in the codebase reference the old per-step async flag after migration.
- **SC-002**: In a reactor with an `async_step`, same-process steps that do not depend on it complete without waiting on it, while a step that explicitly depends on its result always receives the correct, fully-deserialized result once available.
- **SC-003**: An `async_step`'s or `async_reactor`'s failure never causes the parent reactor's completed steps to be rolled back unless a later step explicitly reads its result and triggers compensation itself — verified across repeated failure-injection runs with zero unintended rollbacks.
- **SC-004**: 100% of reactor definitions still written against the old per-step async flag fail fast at definition time with an actionable error, rather than silently running with incorrect behavior.
- **SC-005**: A step waiting on an async result is never left hanging indefinitely — it either receives the result or a clear timeout failure within the configured bound, in all tested scenarios.

## Assumptions

- Sidekiq remains the independent worker backend for background hand-off, `async_step`, and `async_reactor` dispatch, consistent with the project's existing core dependency on Sidekiq.
- Redis remains the durable store for step/reactor results, consistent with the project's existing durability model.
- "Independent process" means a separate worker job (a new Sidekiq job), not a thread or fiber within the originating process.
- This is a breaking (MAJOR, per SemVer) change to the public step DSL; updating `README.md`, `CHANGELOG.md`, and `demo_app/` to the new syntax is required delivery work but not itself a testable acceptance criterion of this spec.
- The wait timeout for `result()` references to async work (FR-005) is a single library-wide value exposed via the existing global `Configuration`; per-reactor or per-reference overrides are out of scope for this feature.
