# Feature Specification: Cross-Service Reactor Sagas

**Feature Branch**: `001-cross-service-reactor-sagas`

**Created**: 2026-06-24

**Status**: Draft (Investigation)

**Input**: User description: "The developer should be able to connect multiple microservices using reactors, all microservices manage their sagas with ruby reactor and the developer can trigger ruby_reactor sagas in other microservices as part of the local reactor saga. The local reactor will not be the coordinator of the others microservices reactor sagas, it will just receive the result and continue with the local saga."

> **Investigation Scope**: This specification captures requirements and constraints for a cross-service saga triggering capability. No implementation decisions are made here. The goal is to define WHAT the feature must do so that planning can determine HOW.

---

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Trigger External Saga as Step (Priority: P1)

A developer building a local saga needs to call a saga in another microservice as one of their saga's steps. The local saga should pause, wait for the remote saga to complete, then continue with the result — exactly as it would with a slow async step.

**Why this priority**: This is the core capability. Without the ability to trigger and receive results from remote sagas, all other stories are moot.

**Independent Test**: Can be tested by defining a local reactor with one step that triggers a remote reactor saga, and verifying that the local saga correctly resumes with the remote saga's output when the remote signals completion.

**Acceptance Scenarios**:

1. **Given** a local reactor with a step configured to trigger a remote service's saga, **When** the step executes, **Then** the remote saga is triggered and the local saga enters a waiting state
2. **Given** a local saga waiting for a remote saga, **When** the remote saga completes successfully, **Then** the local saga resumes and the remote saga's output is available to subsequent steps
3. **Given** a local saga waiting for a remote saga, **When** the remote saga completes, **Then** the remote service has managed all of its own compensation and step orchestration independently

---

### User Story 2 - Handle Remote Saga Failure (Priority: P2)

A developer's local saga must respond correctly when a remote saga fails. The remote service handles its own rollback; the local saga receives a failure signal and runs its own compensation logic.

**Why this priority**: Saga integrity depends on knowing when a remote operation failed. Without failure propagation, the local saga cannot compensate correctly, violating the Saga Pattern Integrity principle.

**Independent Test**: Can be tested by configuring a remote saga that is expected to fail, verifying the local saga receives the failure, and confirming that the local saga's compensation steps execute while the remote service handles its own internal compensation.

**Acceptance Scenarios**:

1. **Given** a local saga waiting for a remote saga, **When** the remote saga fails, **Then** the local saga receives a failure result containing enough context to make compensation decisions
2. **Given** a local saga that received a remote failure, **When** the local saga triggers compensation, **Then** the local compensation steps run with access to the remote failure details
3. **Given** the remote saga failed, **When** the local saga compensates, **Then** the remote service is solely responsible for its own internal rollback — the local reactor does not orchestrate remote compensation

---

### User Story 3 - Multiple External Sagas in One Local Saga (Priority: P2)

A developer can define multiple external reactor steps within a single local saga, calling different remote services as part of a broader workflow.

**Why this priority**: Real microservice workflows span more than two services. A single-service limitation would make the feature too narrow for production use cases.

**Independent Test**: Can be tested by defining a local reactor with two independent steps each targeting a different remote service, and verifying both complete before the local saga continues.

**Acceptance Scenarios**:

1. **Given** a local saga with two steps, each triggering a different remote service's saga, **When** both remote sagas complete, **Then** the local saga has results from both and can continue
2. **Given** two independent external saga steps, **When** they have no declared dependency on each other, **Then** they may execute concurrently (consistent with DAG-based execution)
3. **Given** a local saga where external step B depends on external step A, **When** step A completes, **Then** step B is triggered and receives step A's result

---

### User Story 4 - Observe Cross-Service Execution (Priority: P3)

A developer or operator can see in the local service's dashboard that a step is waiting on a remote saga, and can identify which remote service and saga are involved.

**Why this priority**: Observability is a core principle. A "waiting" step with no context is undiagnosable in production.

**Independent Test**: Can be tested by triggering a cross-service step and inspecting the local web dashboard to confirm the step's state, the remote service identifier, and the remote saga reference are all visible.

**Acceptance Scenarios**:

1. **Given** a local saga with a waiting external step, **When** an operator views the local dashboard, **Then** the step is shown as waiting with the remote service identifier and remote saga reference
2. **Given** a completed cross-service step (success or failure), **When** an operator reviews the local dashboard history, **Then** the remote saga outcome and any returned data are visible

---

### Edge Cases

- What happens when the remote service is unreachable at trigger time?
- What happens when the local saga is waiting and the local service restarts (crash recovery)?
- What happens when the remote saga takes longer than an expected deadline?
- What happens if the remote service sends a completion signal that cannot be matched to a waiting local saga (stale or duplicate signal)?
- What happens when the remote saga's schema changes and the returned data no longer matches what the local step expects?
- What happens if the same local saga step triggers the same remote saga twice due to retry logic?

---

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: Developers MUST be able to define a step in a local reactor that triggers a saga in a remote RubyReactor-powered service
- **FR-002**: The local saga MUST automatically pause execution and wait when an external saga step is reached
- **FR-003**: The external saga step MUST resume the local saga when the remote service signals saga completion (success or failure)
- **FR-004**: The remote service's saga MUST manage its own lifecycle — including compensation, retries, and step orchestration — without direction from the local reactor
- **FR-005**: On remote saga success, the local saga MUST make the remote saga's output available to subsequent local steps
- **FR-006**: On remote saga failure, the local saga MUST receive enough failure context to make local compensation decisions
- **FR-007**: The cross-service step definition MUST follow the standard RubyReactor step authoring style (consistent with gem-first design, no host-application coupling)
- **FR-008**: A local saga MUST support multiple external saga steps, including independent steps that may execute concurrently per the DAG
- **FR-009**: Cross-service step execution MUST be recoverable after a local service crash (consistent with existing durability guarantees)
- **FR-010**: The local web dashboard MUST display external saga step status, including the remote service identifier and remote saga reference
- **FR-011**: All cross-service communication events MUST produce structured log entries (machine-parseable) consistent with the existing observability requirements

### Key Entities

- **External Reactor Step**: A standard RubyReactor step that, instead of executing local logic, triggers a saga in a named remote service and waits for its result
- **Remote Saga Reference**: An identifier for the saga instance running in the remote service, used to correlate the completion signal back to the waiting local step
- **Cross-Service Result**: The outcome payload returned by the remote service — includes success/failure status and any data the remote saga produced
- **Remote Service Descriptor**: A named, configured reference to an external RubyReactor-powered service (transport endpoint, identity, schema contract)

---

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A developer can add a cross-service saga step to an existing local reactor with no more lines of code than a standard local step definition
- **SC-002**: A local saga correctly resumes after a remote saga completes, with remote output accessible to the next step, in 100% of success scenarios
- **SC-003**: A local saga's compensation executes when a remote saga fails, and remote failure details are available to compensation logic, in 100% of failure scenarios
- **SC-004**: A local saga waiting on a remote saga correctly resumes after the local service crashes and restarts (durability preserved for cross-service waits)
- **SC-005**: An operator can identify any waiting cross-service step — including which remote service and what remote saga reference — within 30 seconds of checking the dashboard
- **SC-006**: No changes are required to the remote microservice's saga definition to make it triggerable from another service (remote sagas are unmodified)

---

## Assumptions

- All participating microservices run RubyReactor at a compatible version (exact version compatibility range is a planning concern)
- The transport mechanism between services (HTTP callback, message queue, Redis pub/sub, etc.) is an implementation detail to be decided during planning — this spec deliberately does not constrain it
- The remote saga is owned entirely by the remote service; the local reactor has no visibility into the remote saga's steps, compensation chain, or internal state beyond the final result
- The existing RubyReactor interrupt mechanism (pause/resume) is the natural foundation for waiting on external signals, but how it is adapted is a planning decision
- Remote service descriptors (how the local reactor knows where and how to reach a remote service) will be defined in gem configuration, not scattered across step definitions
- The feature targets Ruby gem consumers who already use RubyReactor for local saga orchestration — no new runtime or infrastructure requirement is introduced beyond what RubyReactor already requires (Sidekiq + Redis)
- This investigation does not presuppose a specific transport; the spec is valid regardless of whether the final implementation uses HTTP webhooks, a shared Redis channel, or a message broker
- The remote saga author does not need to know their saga will be called cross-service; the external trigger is transparent to the remote service
