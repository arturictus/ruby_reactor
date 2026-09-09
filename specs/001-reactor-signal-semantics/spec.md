# Feature Specification: Reactor Signal Semantics

**Feature Branch**: `reactor_signals`

**Created**: 2026-09-09

**Status**: Draft

**Input**: User description: "we have to reframe how the signals are named and the sideeffects they produce in the reactor flow. Success: nothing to do, works fine. Failure: nothing to do, works fine. Skipped: should be renamed to `Halt` and produce the same effect currently does Skipped, stop the full reactor without compensation. New signal — Skipped: mark the step as skipped but the reactor continues; the Skipped wrapper must return the same wrapped data that Success returns, very important for following steps that require the `result()` from previous step. Helper methods in steps that stop execution and return the appropriate wrapped result: `success!`, `fail!`, `skip!`. Compensation and undo should return `Skipped` by default, to mark which compensations and undos are really executed or not implemented."

## Overview

A workflow step today can end in three ways: it succeeded, it failed, or it asked
the whole workflow to stop cleanly. That third outcome is currently named
"Skipped", which reads as "this one step was skipped" but actually stops
everything. Workflow authors misread it, and there is no way at all to express
the thing the name promises: *this step had nothing to do, carry on*.

This feature separates the two ideas into two distinctly named outcomes, gives
step authors one-line helpers to emit any outcome and exit the step body
immediately, and makes rollback traces honest about which compensation and undo
logic actually ran versus which was never written.

It also pins down each outcome's relationship to retries, which is currently
implicit: only a failure ever enters the retry machinery, and a failure can say
whether it wants to be retried at all.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Clean halt has an honest name (Priority: P1)

A workflow author writes a step that discovers the remaining work is not needed
at all — the user already opted out, the batch is empty, the period bucket is
already claimed. They want the whole workflow to stop right there, keeping
everything already done, with no rollback. Today they express this with an
outcome named "Skipped"; after this change they express it as **Halt**, and the
behaviour is byte-for-byte the same as before.

**Why this priority**: The rename is the foundation the new "Skipped" meaning
sits on. Until the clean-halt outcome vacates the "Skipped" name, the new
per-step outcome cannot exist. It also stands alone as a deliverable: it is a
pure rename of an existing, working behaviour and ships value (an unambiguous
vocabulary) on its own.

**Independent Test**: Take every existing clean-halt scenario — an explicit halt
from a step body, a period gate that finds the bucket already claimed, an
ordered-lock gate that short-circuits a stale batch — express each with the Halt
outcome, and confirm identical observable results: the workflow stops, no
further steps run, no completed step is rolled back, the halt reason and the
halting step name are reported to the caller.

**Acceptance Scenarios**:

1. **Given** a workflow whose second of four steps emits Halt, **When** the
   workflow runs, **Then** steps three and four never run, step one's work is
   left intact with no rollback, and the caller receives a halted outcome
   carrying the reason and the name of the halting step.
2. **Given** a workflow guarded by a period gate whose bucket is already
   claimed, **When** the workflow runs, **Then** no step runs at all and the
   caller receives a halted outcome naming the period as the reason.
3. **Given** a workflow guarded by an ordered lock that short-circuits (stale
   batch, drained replay, or failed chain predecessor), **When** the workflow
   runs, **Then** the caller receives a halted outcome carrying that specific
   reason.
4. **Given** a test suite asserting clean-halt behaviour, **When** it uses the
   halt assertion helpers, **Then** it can assert both the halt reason and the
   step that halted.
5. **Given** existing code that emits the old clean-halt outcome under its old
   name and shape, **When** that code runs after the change, **Then** it does
   not silently switch to the new per-step meaning — it raises an actionable
   error naming Halt as the replacement.

---

### User Story 2 - A step can be skipped while the workflow continues (Priority: P2)

A workflow author writes a step that has nothing to do this run — the record is
already synced, the notification was already sent, the discount does not apply.
The rest of the workflow is still valid and must continue. The author marks the
step **Skipped** and supplies the value downstream steps expect, so every step
that depends on this one keeps working exactly as if the step had succeeded.

**Why this priority**: This is the capability that does not exist today and the
reason the rename is needed. It is independently testable and independently
valuable: a workflow with an optional step no longer has to fake a success or
split into two workflows.

**Independent Test**: Build a three-step workflow where step two is skipped with
a value and step three reads step two's result. Run it, and confirm step three
runs, sees the supplied value, and the workflow reaches its normal end.

**Acceptance Scenarios**:

1. **Given** a workflow where step two is skipped with a value and step three
   depends on step two's result, **When** the workflow runs, **Then** step three
   runs and reads exactly the value step two supplied.
2. **Given** a workflow whose final (result-returning) step is skipped with a
   value, **When** the workflow runs, **Then** the workflow completes and the
   caller receives that value as the workflow result.
3. **Given** a workflow where a step is skipped with no value, **When** a
   dependent step reads that step's result, **Then** it reads an empty value and
   the workflow still completes rather than erroring.
4. **Given** a workflow where step two is skipped and a later step fails,
   **When** rollback runs, **Then** the skipped step is not rolled back (it
   produced no side effect to undo) while genuinely completed steps are.
5. **Given** a completed workflow containing a skipped step, **When** the run is
   inspected in the execution trace, the dashboard, and the telemetry data,
   **Then** that step is identifiable as skipped rather than as plainly
   succeeded, and the run as a whole is identifiable as completed rather than
   halted.

---

### User Story 3 - One-line outcome helpers that exit the step (Priority: P3)

A workflow author writes a step whose body has several early exits — bail out
successfully when the user is already ready, fail when an action reports errors,
skip when there is nothing to do. Today each exit needs an explicit `return` of
a constructed outcome, which is easy to forget and impossible to do from a
helper method the step body calls. The author instead calls `success!`,
`fail!`, `skip!`, or `halt!` and the step ends right there with the correct
outcome.

**Why this priority**: Pure ergonomics on top of Stories 1 and 2 — valuable but
not blocking. Independently shippable once the outcomes exist.

**Independent Test**: Write one inline-block step and one class-based step, each
calling each helper in turn, and confirm the code that follows the helper call
never runs and the workflow observes the matching outcome.

**Acceptance Scenarios**:

1. **Given** a step body that calls `success!` with a value partway through,
   **When** the step runs, **Then** the remaining lines of the step body do not
   run and the workflow treats the step as succeeded with that value.
2. **Given** a step body that calls `fail!` with an error, **When** the step
   runs, **Then** the remaining lines do not run and the workflow treats the
   step as failed with that error, including rollback of completed steps.
3. **Given** a step body that calls `skip!` with a value, **When** the step
   runs, **Then** the remaining lines do not run and the workflow continues with
   that step marked skipped (Story 2 behaviour).
4. **Given** a step body that calls `halt!` with a reason, **When** the step
   runs, **Then** the remaining lines do not run and the workflow halts cleanly
   (Story 1 behaviour).
5. **Given** the same helper called from inside a method the step body invokes,
   rather than at the top level of the step body, **When** that method runs,
   **Then** the step still ends immediately with the matching outcome.
6. **Given** both authoring styles — an inline step block and a class-based step
   — **When** each uses the helpers, **Then** behaviour is identical.
7. **Given** an author who prefers returning a constructed outcome instead of
   calling a helper, **When** the step runs, **Then** that continues to work
   unchanged.
8. **Given** a retryable step whose body calls `fail!` with retries turned off,
   **When** the step runs, **Then** it is attempted exactly once and rollback
   begins immediately — no backoff wait, no re-enqueue.
9. **Given** a retryable step whose body calls `fail!` without saying anything
   about retries, **When** the step runs, **Then** it retries under the step's
   own retry configuration exactly as returning a failure does today.

---

### User Story 4 - Rollback traces distinguish "ran" from "never written" (Priority: P4)

An operator inspecting a rolled-back workflow needs to know which steps actually
compensated or undid their work and which simply had no such logic defined. With
both cases reporting success today, the trace cannot answer that. After this
change, a compensation or undo that was never implemented reports **Skipped**,
while one an author wrote and ran reports its own outcome.

**Why this priority**: Observability improvement, valuable but not blocking, and
the smallest slice of the four.

**Independent Test**: Roll back a workflow with a mix of steps — some with
compensation and undo logic, some without — and confirm the trace marks the
undefined ones as skipped and the defined ones by their real outcome.

**Acceptance Scenarios**:

1. **Given** a step with no compensation logic that is compensated during
   rollback, **When** the trace is inspected, **Then** its compensation is
   marked skipped, and rollback proceeds to the remaining steps unchanged.
2. **Given** a step with no undo logic that is undone during rollback, **When**
   the trace is inspected, **Then** its undo is marked skipped, and rollback
   proceeds unchanged.
3. **Given** a step whose compensation logic runs and succeeds, **When** the
   trace is inspected, **Then** it is marked as a real success, distinguishable
   from the skipped case.
4. **Given** a step whose compensation logic fails, **When** rollback runs,
   **Then** the failure is surfaced exactly as it is today — a skipped
   compensation must never be mistaken for a failed one.

---

### Edge Cases

- A step emits Skipped and *no* later step depends on it: the workflow completes
  normally and the step is reported skipped.
- Every step in a workflow is skipped: the workflow completes successfully with
  an empty or all-skipped result set rather than halting.
- A skipped step's value fails the step's declared output validation: it is
  treated exactly as a failing success value would be — validation applies to
  skipped values too, since dependants consume them.
- A step emits Skipped inside a mapped (per-element) execution: that element is
  marked skipped and the remaining elements continue.
- A step emits Halt inside a mapped execution: the halt propagates as a clean
  halt of the run, as it does today.
- A helper is called inside a compensation or undo body: the compensation/undo
  ends with the matching outcome and rollback continues.
- A helper's non-local exit crosses a rescue block that catches broadly: the
  step must still end with the intended outcome rather than being swallowed.
- A step with a three-attempt budget fails twice and then emits Skipped: the
  workflow continues with that step marked skipped, its retry counters cleared,
  and no exhaustion failure reported.
- A step with a three-attempt budget fails twice and then emits Halt: the
  workflow halts cleanly with no rollback, not as a retry exhaustion.
- A step that is not configured for retries fails with retries explicitly
  allowed: it is still attempted once — the flag cannot grant retries.
- A halted run is opened in the dashboard: steps that never ran are shown as
  not-run, not as cancelled or rolled back — nothing was rolled back.
- A run recorded before the upgrade, still carrying the old status name, is
  opened in the dashboard: it displays as halted rather than as an unknown
  state.
- A failure with retries turned off is raised inside a mapped element or an
  asynchronous step: that element/step is terminal on its first attempt, with no
  re-enqueue, and the failure path runs as usual.
- A workflow is resumed after a crash and a previously skipped step is replayed:
  the replay yields the same skipped outcome and value as the original run.
- An asynchronous step is skipped or halts: the outcome survives serialisation
  to the background worker and back with reason, step name, and value intact.
- Old code calls the clean-halt outcome by its former name and shape: it raises
  an actionable error naming Halt rather than silently changing behaviour.

## Requirements *(mandatory)*

### Functional Requirements

**Halt (renamed clean halt)**

- **FR-001**: The system MUST provide a **Halt** outcome that stops a workflow
  immediately, runs no further steps, and performs no compensation or undo of
  already-completed steps.
- **FR-002**: A Halt outcome MUST carry the halt reason and the name of the step
  that halted, and MUST report both to the caller of the workflow.
- **FR-003**: All internally-produced clean halts — the period gate and every
  ordered-lock short-circuit — MUST produce Halt, preserving their existing
  reasons unchanged.
- **FR-004**: A halted run MUST remain distinguishable from a completed run and
  from a failed run wherever run outcomes are reported: to the caller, in the
  persisted run state, in the dashboard, and in telemetry.
- **FR-005**: Test assertion helpers MUST allow asserting that a run halted, and
  asserting the halt reason and halting step.
- **FR-006**: Code written against the previous clean-halt name and call shape
  MUST NOT silently acquire the new per-step meaning; it MUST raise an
  actionable error that names Halt as its replacement.

**Skipped (new per-step outcome)**

- **FR-007**: The system MUST provide a **Skipped** outcome that marks a single
  step as skipped while the workflow continues with its remaining steps.
- **FR-008**: A Skipped outcome MUST wrap a value in exactly the same way a
  successful outcome does, so any step reading a skipped step's result receives
  that value with no special handling.
- **FR-009**: A skipped step MUST satisfy its dependants' dependency
  requirements — dependent steps become runnable exactly as they would after a
  success.
- **FR-010**: A skipped step MUST NOT be rolled back if a later step fails,
  since a skipped step performs no side effect.
- **FR-011**: A skipped step MUST be recorded as skipped in the execution trace,
  the dashboard, and telemetry, distinguishably from a succeeded step.
- **FR-012**: A workflow whose result-returning step is skipped MUST complete
  and return that step's value.
- **FR-013**: A skipped step's value MUST be subject to the same output
  validation as a successful step's value.
- **FR-014**: Test assertion helpers MUST allow asserting that a specific step
  was skipped, separately from asserting that a run halted.

**Step outcome helpers**

- **FR-015**: Steps MUST provide helpers `success!`, `fail!`, `skip!`, and
  `halt!` that end the step immediately with the corresponding outcome.
- **FR-016**: Each helper MUST accept the same payload its outcome accepts —
  a value for `success!` and `skip!`, an error for `fail!`, a reason for
  `halt!`.
- **FR-017**: The helpers MUST end the step from any depth of nested calls
  within the step's own execution, not only from the top level of the step body.
- **FR-018**: The helpers MUST be available in both authoring styles — inline
  step blocks and class-based steps — with identical behaviour.
- **FR-019**: The helpers MUST be available in compensation and undo bodies as
  well as run bodies.
- **FR-020**: Returning a constructed outcome instead of calling a helper MUST
  continue to work unchanged.
- **FR-021**: A helper's early exit MUST NOT be swallowed by broad error
  handling inside the step body.

**Compensation and undo defaults**

- **FR-022**: A step with no compensation logic MUST report Skipped when
  compensated, and a step with no undo logic MUST report Skipped when undone.
- **FR-023**: A skipped compensation or undo MUST let rollback continue exactly
  as a successful one does, and MUST NOT be treated as a failure.
- **FR-024**: Compensation and undo logic that an author wrote and that ran MUST
  remain distinguishable in the trace from logic that was never written.

**Retry interaction**

- **FR-025**: A Failure MUST carry a retry flag that says whether the step may
  be retried. Its default MUST be "retry allowed", preserving today's behaviour.
- **FR-026**: `fail!` MUST accept the same retry flag, with the same default,
  and MUST produce an outcome indistinguishable from returning a Failure
  constructed with that flag.
- **FR-027**: A failure with retries turned off MUST be terminal on its first
  attempt: no further attempt, no backoff wait, no re-enqueue — the workflow
  proceeds straight to compensation and rollback.
- **FR-028**: The retry flag MUST only be able to veto retries, never to grant
  them. A step that is not configured for retries, or that has exhausted its
  attempt budget, MUST NOT be retried regardless of the flag.
- **FR-029**: Success, Skipped, and Halt MUST NOT trigger a retry, a backoff
  wait, or a re-enqueue, at any attempt number and under any step retry
  configuration.
- **FR-030**: Success, Skipped, and Halt MUST NOT trigger compensation or undo.
- **FR-031**: When a step emits Success, Skipped, or Halt after one or more
  failed attempts, its accumulated retry state MUST be cleared and the run MUST
  report that outcome — never a retry-exhaustion failure.
- **FR-032**: The retry flag MUST survive the round trip through background
  execution and durable state, so a failure marked non-retryable in a worker is
  still non-retryable wherever it is finally handled.
- **FR-033**: Code passing the retry flag under its existing name MUST continue
  to work unchanged.

**Migration and documentation**

- **FR-034**: All documentation, examples, the demo application, and the README
  MUST use the new vocabulary and show both outcomes, including the retry flag
  on failures.
- **FR-035**: The release notes MUST carry a migration note describing the
  rename, the new outcome, the helpers, and the retry flag.

**Dashboard**

- **FR-036**: The dashboard MUST offer "halted" wherever run status is shown or
  filtered, and MUST keep displaying runs recorded under the legacy status from
  before the rename.
- **FR-037**: The workflow graph MUST render a skipped step distinctly from a
  completed one. A skipped step stores a result value like a successful one, so
  the graph MUST NOT infer "completed" from the presence of a value alone.
- **FR-038**: On a halted run, the graph MUST identify which step halted, and
  MUST NOT present steps that never ran as rolled back — nothing was rolled
  back.
- **FR-039**: The step inspector's rollback list MUST distinguish compensation
  and undo that actually ran from compensation and undo that was never written.
- **FR-040**: The dashboard assets shipped inside the gem MUST be rebuilt from
  source as part of this change, so an installed gem serves the updated
  dashboard rather than the previous vocabulary.

### Key Entities

- **Success**: A step finished and produced a value. Unchanged by this feature.
- **Failure**: A step failed; the step may be retried, then completed steps roll
  back. Carries a retry flag (default: retry allowed) that can veto retries.
  Otherwise unchanged by this feature.
- **Halt**: A clean stop of the whole workflow with no rollback. Carries a
  reason and the halting step's name. Takes over the behaviour previously
  published under the name "Skipped".
- **Skipped**: A single step did nothing this run; the workflow continues.
  Carries a value indistinguishable, to dependants, from a success value.
- **Step outcome helpers**: `success!`, `fail!`, `skip!`, `halt!` — one-line
  early exits from a step body that produce the four outcomes above.
- **Run outcome status**: The reported end state of a workflow run — completed,
  failed, halted, or one of the existing in-flight states — used by the caller,
  the persisted state, the dashboard, and telemetry.
- **Execution trace entry**: The per-step record of what happened, now able to
  express step-skipped, compensation-skipped, and undo-skipped.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: 100% of existing clean-halt behaviours — explicit halts, period
  gates, and all three ordered-lock short-circuits — behave identically under
  the Halt name, verified by the existing scenarios re-expressed against it.
- **SC-002**: A step that is skipped supplies its value to every dependent step
  in 100% of cases, with no dependant needing outcome-specific handling.
- **SC-003**: A workflow author can express any of the four outcomes and exit
  the step in a single line, from anywhere in the step's execution.
- **SC-004**: 0 cases where code written against the old clean-halt name
  silently changes behaviour — every such call site either still halts or fails
  loudly with a message naming Halt.
- **SC-005**: For any rolled-back run, an operator can tell, for every step,
  whether its compensation and undo actually ran or were never written, from the
  trace alone.
- **SC-006**: A run that halts, a run that completes with skipped steps, and a
  run that completes with none are three distinguishable states in the
  dashboard and in telemetry.
- **SC-007**: The full existing test suite passes after the change, with no
  behaviour regression outside the deliberate rename.
- **SC-008**: A step ending in Success, Skipped, or Halt is attempted exactly
  once by the retry machinery in 100% of cases, whatever its retry budget and
  however many earlier attempts failed.
- **SC-009**: A failure marked non-retryable produces exactly one attempt and
  zero backoff waits or re-enqueues, in both synchronous and background
  execution.
- **SC-010**: Every outcome × retry-configuration combination — four outcomes ×
  retries on/off × step retryable/not — has a covering test, so no combination's
  behaviour is left to inference.
- **SC-011**: For a run containing one skipped step, the dashboard graph shows
  exactly one step in the skipped state and zero steps mislabelled as completed
  or failed.
- **SC-012**: An operator can filter the dashboard to halted runs and open one
  to see which step halted, without reading logs.

## Assumptions

- **Pre-1.0 breaking change**: The gem is at 0.5.x. The clean-halt rename is a
  deliberate breaking change shipped with a migration note, not a long
  deprecation cycle. Because the name "Skipped" is *reused* with different
  semantics, an alias cannot preserve the old meaning — so the old call shape
  raises rather than aliasing (FR-006). Ponytail: one guard, not a compatibility
  layer.
- **Skipped steps are side-effect-free by definition**: A step that performed a
  side effect should report Success, not Skipped. Therefore skipped steps are
  not enrolled for rollback (FR-010). Authors needing rollback for partial work
  use Success with an undo.
- **Skipped with no value yields an empty value**: `skip!` with no argument
  gives dependants the same empty value a `success!` with no argument would.
  Dependants that require a real value are expected to validate it as they do
  for any success.
- **Helpers are additive**: Nothing about returning constructed outcomes
  changes. The helpers are sugar over the same four outcomes.
- **Halt keeps its keyword-style reason**: Halt is constructed with a reason (and
  the existing internal fields such as period key), matching how the current
  clean-halt outcome is constructed, so internal producers change name only.
- **Existing status vocabulary extends rather than breaks**: The persisted run
  status previously written for clean halts is renamed to a halted status; the
  per-step skipped marker is new and additive.
- **The retry flag is a veto, not a grant** (FR-028): today a failure is retried
  only when the step is configured for retries *and* the failure permits it.
  That conjunction is preserved — the flag on the failure can only subtract.
- **`retry:` is the author-facing name for the retry flag**: the requester wrote
  `Failure(error, retry: false)` and `fail!(error, retry: false)`, so that is the
  documented spelling. The flag already exists on failures under an older name,
  which keeps working (FR-033) — it is also what durable state already records,
  so renaming it outright would break stored state. If both spellings appear in
  one call, the new one wins. Ponytail: one alias, not a rename cascade.
- **Retry counting is untouched**: attempt budgets, backoff strategy, and
  exhaustion reporting keep their current behaviour. This feature only settles
  which outcomes enter the retry machinery at all (FR-029) and how a failure
  opts out of it (FR-027).
- **Async and durable paths are in scope**: Both outcomes must survive
  background-job serialisation and crash-recovery replay, since the gem's
  asynchronous execution is a first-class path, not an add-on.
- **Map/element execution is in scope**: Skipped applies per element; Halt
  propagates to the run, matching how the outcomes behave in linear workflows.
