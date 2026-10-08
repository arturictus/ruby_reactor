# Feature Specification: Interrupt Inside a Composed Child

**Feature Branch**: `interrupt_inside_composed_child`

**Created**: 2026-10-08

**Status**: Draft

**Input**: User description: "Interrupt inside a composed child. Status: unsupported on main, found
while implementing 009 (US2-AS2). An `interrupt` in a `compose`d child does not pause the root:
`ComposeStep#handle_execution_result` calls `success?` on the child's `InterruptResult`, and the
compose step fails with `NoMethodError`. It fails the same way with or without a fan-out map in the
child. Direction: propagate the child's `InterruptResult` as the compose step's result, so the root
pauses; let `Reactor.continue` and the `be_paused_at` matcher name the nested interrupt (a step path
such as `:fulfil, :approve`); and resume through `ComposeStep#run`, which already re-enters an
admitted child. Spec: `spec/map/map_compose_fan_out_spec.rb` keeps a `pending` example for it."

## Context

What happens today, and what this feature changes:

| Area | Today | After this feature |
| --- | --- | --- |
| Child reaches an `interrupt` | The compose step crashes (`NoMethodError` on the child's pause result); the root fails and rolls back. | The root pauses, stored as `paused`, with the child's completed steps kept. |
| The paused result | (never reached) | Identifies the **root** run (its `execution_id`) and carries the child interrupt's `correlation_id`. |
| Naming the pause | Only the root's own steps can be named. | A nested interrupt is named by its step path from the root, e.g. `[:fulfil, :approve]`. |
| Resuming | (never reached) | `continue` on the root, by id or correlation id, re-enters the child at its interrupt; the child finishes, then the root. |
| Undo / cancel while paused in a child | (never reached) | Work as for a root-level pause; undo also rolls back the steps the child completed. |
| Docs | `composition.md` says an `interrupt` inside a composed child is not supported yet. | Documented as supported, with the path form. |

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Pause the root at an interrupt inside a composed child (Priority: P1)

A developer composes a `Fulfilment` reactor into an `Order` reactor (`compose :fulfil,
Fulfilment`). `Fulfilment` contains `interrupt :approve` waiting for a manager's approval. Running
`Order` must stop at the approval: the root run is stored as `paused`, the steps completed so far in
both the root and the child are kept, and the caller gets a paused result that identifies the
**root** run, so it can be resumed later.

**Why this priority**: Without this the feature is unusable: any reactor that reuses a child with a
human approval or webhook wait fails outright. Every other story depends on the root pausing
correctly.

**Independent Test**: Run a root whose composed child has an interrupt. Verify the root is stored as
`paused`, the result's `execution_id` is the root's id, the child's steps before the interrupt ran
exactly once, no step after the interrupt (in the child or the root) ran, and nothing was rolled
back.

**Acceptance Scenarios**:

1. **Given** a root composing a child with steps `c1`, `interrupt :approve`, `c2`, **When** the root
   runs, **Then** it is stored as `paused`, `c1` ran once, `c2` and every root step after the compose
   did not run, and the returned result reports `paused?` with the root's `execution_id`.
2. **Given** the child interrupt declares a `correlation_id`, **When** the root pauses, **Then** the
   paused result carries that correlation id and it resolves to the root run.
3. **Given** a child that runs a `fan_out` map before its interrupt, **When** the map completes and
   the root's worker resumes the run, **Then** the root is stored as `paused` at the child's
   interrupt (the `pending` example in `spec/map/map_compose_fan_out_spec.rb`).
4. **Given** the interrupt sits two composes deep (root → middle → child), **When** the root runs,
   **Then** the top-level root is stored as `paused`; no intermediate reactor is stored or resumable
   as a run of its own.

---

### User Story 2 - Resume the root by naming the nested interrupt (Priority: P1)

The approval arrives. The developer calls `Order.continue(id:, payload:, step_name: [:fulfil,
:approve])`, or `Order.continue_by_correlation_id(...)` with the same path. The payload becomes the
interrupt's result inside the child, the child runs its remaining steps, and the root carries on
from the compose step to completion, exactly as a root-level interrupt resumes.

**Why this priority**: Pausing without resuming is a dead end. Together with US1 this is the
minimum viable feature.

**Independent Test**: Pause a root at a child interrupt, then continue it with the step path and a
payload. Verify the child step after the interrupt receives the payload, the root completes, and
every step ran exactly once across pause and resume.

**Acceptance Scenarios**:

1. **Given** a root paused at `[:fulfil, :approve]`, **When** `continue` is called with that path
   and a valid payload, **Then** the child's steps after the interrupt run, the root's steps after
   the compose run, the root ends `completed`, and its result equals that of an uninterrupted run
   given the same payload.
2. **Given** a root paused at a child interrupt with a `correlation_id`, **When**
   `continue_by_correlation_id` is called on the root class with the path, **Then** the run resumes
   as in scenario 1.
3. **Given** the child interrupt declares `resume: :background`, **When** `continue` is called,
   **Then** the payload is validated in the calling process and the remainder runs in the root's
   worker, never in a worker for the child.
4. **Given** a root paused at a child interrupt, **When** `continue` names a step that is not the
   pending interrupt (a bare `:approve`, a wrong path, or a root step), **Then** it raises
   `ValidationError` naming the pending path(s) and the run stays `paused`, unchanged.
5. **Given** the child interrupt validates its payload with `max_attempts: 1`, **When** `continue`
   is called with an invalid payload, **Then** the whole run is rolled back from the root (the
   child's completed steps, then the root's) and marked `failed`, as for a root-level interrupt.
6. **Given** a child that pauses at two interrupts in turn, **When** each is continued in order,
   **Then** the root pauses again at the second and completes after the second resume.

---

### User Story 3 - Undo or cancel a run paused inside a child (Priority: P2)

The approval is refused, so an operator undoes or cancels the paused order. `Order.undo(id)` must
roll back every step completed so far, including the child's, and mark the run `cancelled`;
`Order.cancel(id:, reason:)` must stop it so no later `continue` resumes it.

**Why this priority**: Required for saga correctness once pauses exist, but a paused run is
already safe to leave alone, so it ranks after pausing and resuming.

**Independent Test**: Pause a root at a child interrupt, call `undo`. Verify the child's completed
steps were undone once, before the root's, in reverse order, and the run is `cancelled`.

**Acceptance Scenarios**:

1. **Given** a root paused at a child interrupt after `r1` (root) and `c1` (child) completed,
   **When** the root is undone, **Then** `c1` is undone before `r1`, each once, and the root is
   `cancelled`.
2. **Given** a root paused at a child interrupt after a `fan_out` map in the child, **When** the
   root is undone, **Then** the map's elements, the child's earlier steps, then the root's are
   rolled back, as 009 specifies for a completed run.
3. **Given** a root paused at a child interrupt, **When** it is cancelled, **Then** a later
   `continue` with the nested path raises `ValidationError` and runs nothing.

---

### User Story 4 - Test a nested pause with the RSpec helpers (Priority: P3)

A developer testing `Order` writes `expect(subject).to be_paused_at([:fulfil, :approve])` and
resumes it from the test subject with the same path.

**Why this priority**: Developer convenience; the runtime behavior is verifiable without it.

**Independent Test**: In a spec using the library's test subject, run a root that pauses in a
child, assert the matcher passes for the path and fails with a message listing the actual pending
path for any other name, then resume through the test subject.

**Acceptance Scenarios**:

1. **Given** a test subject paused at a child interrupt, **When** asserting `be_paused_at([:fulfil,
   :approve])`, **Then** it passes; `be_paused_at(:approve)` fails with a message listing
   `[:fulfil, :approve]` as the pending step.
2. **Given** the same subject, **When** its ready interrupt steps are listed, **Then** the nested
   interrupt appears as its path.
3. **Given** the same subject, **When** it is resumed with the path and a payload, **Then** it
   completes as in US2.

---

### Edge Cases

- **Root has its own interrupt ready alongside the compose.** The run pauses at whichever it reaches
  first; resuming that one runs on and pauses at the other, as for two root-level interrupts.
- **A second `continue` while the first resume is executing.** Rejected with the existing "not
  paused" `ValidationError` (008 FR-032), whatever path it names.
- **The child's reactor class used directly.** `Fulfilment.continue` or
  `Fulfilment.continue_by_correlation_id` never resumes the child as a run of its own; the root is
  the only run that owns the pause.
- **A `continue` that cannot take the root's `with_lock` or `with_semaphore`.** Raises the
  `AcquisitionError` and leaves the run paused, as for a root-level resume.
- **A process interruption (signal, exit) during the nested resume.** Handled as today for an
  interruption inside a composed child: the run is stored `aborted` with outstanding undo work.
- **An interrupt inside a composed child inside a `map` element.** Out of scope: an interrupt in a
  map element is not supported either; it must fail with a clear error, not a `NoMethodError`.
- **Path names a compose step whose child is not paused, or a non-compose step.** Treated as a
  wrong step name (US2-AS4).

## Requirements *(mandatory)*

### Functional Requirements

**Pausing**

- **FR-001**: When a composed child reaches an `interrupt`, the root run MUST pause: it is stored as
  `paused`, no step after the interrupt in the child or after the compose in the root runs, and
  nothing is rolled back.
- **FR-002**: The pause MUST work at any compose depth, and whether the run reached the interrupt
  in the caller's process or in a worker (including after a `fan_out` map in the child).
- **FR-003**: The paused result returned to the caller MUST identify the root run by its
  `execution_id` and carry the child interrupt's `correlation_id` when it declares one. A result
  rebuilt by `find(id).result` MUST identify the root run, exactly as for a root-level pause (which
  does not rebuild the correlation id either).
- **FR-004**: A child interrupt's `correlation_id` MUST resolve to the root run through the root
  class's correlation lookup.
- **FR-005**: Only the root run owns the pause: an intermediate or child reactor MUST NOT be stored,
  looked up or resumed as a run of its own (single-writer rule).

**Naming and resuming**

- **FR-006**: A nested interrupt MUST be named by its step path from the root: the compose step
  names from the root down, then the interrupt name, as an ordered list (e.g. `[:fulfil,
  :approve]`, or `[:order, :fulfil, :approve]` two levels deep). Symbols and strings MUST both be
  accepted, so a path sent as JSON works.
- **FR-007**: A bare name MUST keep meaning a step of the root itself; it MUST NOT match a nested
  interrupt.
- **FR-008**: `continue` and `continue_by_correlation_id` on the root MUST accept the path, store
  the payload as the nested interrupt's result, re-enter the child at that interrupt, and run the
  child's and then the root's remaining steps.
- **FR-009**: A resumed run MUST produce the same result, and run each step exactly once, as the
  same tree run without the pause given the same payload.
- **FR-010**: Every resume rule that applies to a root-level interrupt MUST apply to a nested one,
  driven by the nested interrupt's own declaration: payload validation and `max_attempts` (rollback
  of the whole run from the root on exhaustion), `resume: :background` (remainder runs in the root's
  worker), the paused-only guard, cancellation, and lock/semaphore contention leaving the run
  paused.
- **FR-011**: A `continue` naming anything other than a currently pending interrupt MUST raise
  `ValidationError` listing the pending step(s) in path form, and change nothing.

**Undo and cancel**

- **FR-012**: `undo` on a root paused inside a child MUST roll back the steps the child completed
  (including any `fan_out` map elements, per 009) before the root's own, each once, and mark the run
  `cancelled`.
- **FR-013**: `cancel` on a root paused inside a child MUST make every later `continue` fail.

**Testing helpers and docs**

- **FR-014**: The `be_paused_at` matcher, the ready-interrupt listing and the test subject's resume
  MUST accept and report nested interrupts in path form; a failure message MUST list the pending
  path(s).
- **FR-015**: The `pending` example in `spec/map/map_compose_fan_out_spec.rb` MUST become a real,
  passing example that pauses at an interrupt after the child's map, then resumes the root to
  completion.
- **FR-016**: `composition.md` and `interrupts.md` MUST describe the nested pause, the path form and
  how undo reaches the child; the "not supported yet" sentence MUST go.
- **FR-017**: An interrupt reached inside a `map` element (directly or through a compose there) MUST
  fail the step with an error that says it is unsupported, not a `NoMethodError`.

### Key Entities

- **Root run**: The top-level execution a caller started. Sole owner of the stored state, the
  `paused` status, the correlation mapping and every resume.
- **Nested pause point**: The interrupt a composed child stopped at, identified by its step path
  from the root.
- **Step path**: Ordered list of compose step names from the root to the child, ending with the
  interrupt name.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: 100% of runs whose composed child (at depth 1 or 2) reaches an interrupt end
  `paused`, with zero failures or rollbacks caused by the pause itself.
- **SC-002**: A paused-then-resumed run ends with the same final result as the equivalent
  uninterrupted run in 100% of tested cases, with every step run exactly once.
- **SC-003**: Undoing a run paused inside a child undoes each completed step exactly once, child
  steps before root steps, in 100% of tested cases.
- **SC-004**: Every wrongly named resume is rejected with a message listing the pending path, and
  leaves the run unchanged.
- **SC-005**: The previously `pending` example passes on every async backend the suite covers,
  with no other example in the suite regressing.

## Assumptions

- The path is an ordered list (array). Passing names as separate arguments is already taken: the
  `be_paused_at` matcher reads `be_paused_at(:a, :b)` as two concurrent root-level interrupts.
- A bare leaf name is not accepted for a nested interrupt even when unique: explicit paths avoid a
  silent change of meaning when a root later adds a step of the same name.
- The web dashboard's display of a nested pause is out of scope; its continue endpoint passes
  `step_name` through, so a JSON array path works there without extra work.
- Interrupt `timeout` behavior is unchanged: whatever a root-level interrupt does with it applies
  equally.
- Interrupts inside `map` elements stay unsupported; this feature only replaces their crash with a
  clear error.
- Builds on 008 (paused-only resume guard, `aborted` runs) and 009 (fan-out map inside a composed
  child, rollback through the root), both on main.
