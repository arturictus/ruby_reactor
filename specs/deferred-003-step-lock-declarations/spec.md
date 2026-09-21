# Feature Specification: Step-Scoped Coordination

**Feature Branch**: `step_validations`

**Created**: 2026-09-10

**Status**: Draft

**Input**: User description: "One more feature to added to steps: Locks should be able to be declared in the class steps

```ruby
class MyStep
   include RubyReactor::Step
   input :id
   with_lock { |i| "k:#{i[:id]}" }
end
```

It should follow the same reentry primitives as the nested reactors do."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - A step class declares the lock it needs (Priority: P1)

A workflow author writes a step that must not run concurrently with another execution of
itself for the same subject — charging one account, updating one inventory row, syncing one
external record. Today the only place to say that is the whole reactor, which locks far more
than the step needs and forces the key to be derived from reactor inputs rather than from the
step's own values.

The author declares the lock inside the step class, next to the inputs it is keyed on. The
lock is taken immediately before the step's work begins and released as soon as the step
finishes.

**Why this priority**: This is the feature. Without it, "lock this one step" is expressible
only by locking the entire reactor.

**Independent Test**: Define a step class with a declared lock keyed on one of its inputs,
run two reactors concurrently with the same key value, and confirm the step bodies never
overlap; run two with different key values and confirm they do overlap.

**Acceptance Scenarios**:

1. **Given** a step class declaring a lock keyed on one of its inputs, **When** two executions
   with the same key value run concurrently, **Then** the second cannot enter the step's work
   until the first has left it.
2. **Given** the same step class, **When** two executions with different key values run
   concurrently, **Then** both enter the step's work at the same time.
3. **Given** a step holding a declared lock, **When** the step's work succeeds, **Then** the
   lock is released before the next step begins.
4. **Given** a step holding a declared lock, **When** the step's work raises or returns a
   failure, **Then** the lock is released rather than held until it expires.
5. **Given** a step whose lock key derives from an input, **When** the reactor supplies that
   input, **Then** the key is computed from the step's own resolved values, not from the
   reactor's inputs.

---

### User Story 2 - Only the step is locked, not the whole workflow (Priority: P1)

An author has a reactor where one step out of eight needs exclusivity. Locking the reactor
serializes all eight and holds the lock across slow, lock-irrelevant work. With a
step-scoped lock, the other seven steps of two concurrent executions run in parallel and only
the one contended step serializes.

**Why this priority**: This is the value the feature delivers over what exists. Without it,
the declaration has moved but the behavior has not improved.

**Independent Test**: Run two executions of an eight-step reactor whose third step declares a
lock on a shared key; confirm the first two steps of both run concurrently and only the third
serializes.

**Acceptance Scenarios**:

1. **Given** a reactor where one step declares a lock, **When** two executions run
   concurrently with the same key, **Then** only that step serializes; the surrounding steps
   overlap.
2. **Given** the same reactor, **When** one execution is waiting on the step's coordination,
   **Then** the other execution's unrelated steps are not blocked by that wait.

---

### User Story 3 - Contention parks the execution instead of failing it (Priority: P1)

Two executions reach the same locked step at the same time. The loser does not fail — its
work has not been attempted and nothing needs compensating. When the execution is running in
a worker, it steps aside and is retried later, the way an out-of-turn ordered execution
already snoozes today. The workflow completes; it simply completes later.

Running synchronously in the calling process there is no queue to step aside into. There, the
step waits up to its configured wait and then fails with a contention error naming the step
and the key.

**Why this priority**: Contention is the normal case a lock exists to handle. Turning routine
contention into failure-plus-rollback would make step locks unusable for the workloads that
most need them.

**Independent Test**: Run two worker-backed executions against the same key and confirm both
eventually complete successfully, the second after the first released; then run the same pair
synchronously and confirm the loser fails with a contention error.

**Acceptance Scenarios**:

1. **Given** two worker-backed executions contending for one step's key, **When** the loser
   cannot take the key, **Then** it is retried later and eventually completes successfully.
2. **Given** the loser is parked for a later attempt, **When** it parks, **Then** no step of
   that execution has been compensated and no side effect of the contended step has occurred.
3. **Given** a parked execution holds other coordination for the same execution, **When** it
   parks and later resumes, **Then** it keeps ownership across the gap and resumes without
   re-competing for what it already held.
4. **Given** a synchronous in-process execution, **When** it cannot take the key within its
   configured wait, **Then** the step fails with a contention error naming the reactor, step,
   and key, and prior steps compensate as any step failure does.
5. **Given** repeated contention, **When** an execution is retried more times than its
   configured ceiling, **Then** it stops being retried and reports the contention rather than
   snoozing forever.

---

### User Story 4 - Re-entrancy behaves exactly as nested workflows already do (Priority: P1)

An execution never blocks on coordination it already holds. A step keyed the same as its own
reactor proceeds; nested work started inside a locked step proceeds; a key is released for
other executions only once the outermost holder within the execution is done with it.

Where ownership genuinely cannot be shared — work handed to another process, which runs
concurrently rather than within the holder — the system refuses at hand-off time with an
actionable message instead of letting the two sides wait on each other forever.

**Why this priority**: Coordination that deadlocks against itself is worse than no
coordination. The existing rules for nested workflows are the rules; step locks must not
introduce a second, different set.

**Independent Test**: Build a reactor that locks a key, containing a step that locks the same
key, containing nested work that locks it again; confirm it completes. Then hand the nested
work to another process and confirm the hand-off is refused with a message naming the key.

**Acceptance Scenarios**:

1. **Given** a reactor holding a key, **When** a step inside it declares the same key,
   **Then** the step proceeds without waiting.
2. **Given** a step holding a key, **When** its work starts nested work declaring the same
   key, **Then** the nested work proceeds without waiting.
3. **Given** nested holds on one key within one execution, **When** the inner holds are
   released, **Then** the key stays unavailable to other executions until the outermost hold
   is released.
4. **Given** an execution holding a key, **When** it tries to hand work declaring that key to
   another process, **Then** the hand-off is refused before dispatch with a message naming
   the key, the holder, and how to restructure.
5. **Given** a step whose work is handed to a worker, **When** the work runs there, **Then**
   the key is taken by that worker — never taken in the dispatching process and carried
   across.
6. **Given** an execution that parks mid-flight while holding coordination, **When** it
   resumes, **Then** it re-adopts what it held without a duplicate acquisition being recorded,
   and falls back to competing normally if the hold lapsed while parked.

---

### User Story 5 - The whole coordination family is available per step (Priority: P2)

Everything a reactor can declare about coordination, a step can declare about itself:
exclusivity, a concurrency ceiling, a rate ceiling, once-per-window deduplication, and strict
ordering. Each keeps the meaning it has at reactor level, narrowed to the step.

**Why this priority**: Parity is what makes the step a real unit of work rather than a
partial one; but exclusivity alone already delivers the primary value.

**Independent Test**: Declare each primitive on a step in turn and confirm the step-scoped
behavior matches the reactor-scoped behavior narrowed to that step.

**Acceptance Scenarios**:

1. **Given** a step declaring a concurrency ceiling of N for a key, **When** more than N
   executions reach it, **Then** at most N are inside the step's work at once and the rest
   contend as US3 describes.
2. **Given** a step declaring a rate ceiling, **When** the ceiling is reached, **Then**
   further executions of that step contend as US3 describes rather than exceeding the rate.
3. **Given** a step declaring once-per-window deduplication, **When** a second execution
   reaches it in the same window with the same key, **Then** that **step** is skipped and the
   rest of the workflow continues — the reactor is not halted.
4. **Given** a step declaring strict ordering, **When** executions reach it out of order,
   **Then** each waits until its turn, and the surrounding steps are unaffected.
5. **Given** a step declaring strict ordering with stop-the-line behavior, **When** an earlier
   position in the sequence ends in failure, **Then** later positions short-circuit at that
   step rather than executing it.

---

### User Story 6 - Coordination is re-taken to undo the work it protected (Priority: P2)

A locked step succeeded; a later step failed; rollback reaches the locked step. The
compensating work touches the same resource the forward work did, so it runs under the same
exclusivity — a refund never races another execution's charge on the same key.

**Why this priority**: Without it, the lock protects the forward path and abandons the
rollback path, which is where correctness problems are hardest to see.

**Independent Test**: Fail a reactor after a locked step succeeded; confirm the compensation
of that step holds the same key, and that a concurrent execution cannot enter the step's
forward work while the compensation runs.

**Acceptance Scenarios**:

1. **Given** a step that declared exclusivity and succeeded, **When** rollback compensates it,
   **Then** the compensation runs holding the same key, computed from the same values.
2. **Given** that compensation is running, **When** another execution reaches the same step
   with the same key, **Then** it cannot enter until the compensation has released the key.
3. **Given** a step declaring a rate ceiling or a deduplication window, **When** it is
   compensated, **Then** the compensation is not gated by those — cleanup is never suppressed
   by a forward-work quota.
4. **Given** compensation cannot take the key, **When** the wait expires, **Then** the
   rollback reports it rather than silently skipping the compensation.

---

### User Story 7 - Operators can see step coordination (Priority: P2)

An operator debugging a stalled workflow needs to know which step is waiting on which key,
and which execution holds it. Step coordination appears in the same surfaces reactor-level
coordination already does — logs, failure records, and the dashboard's coordination view.

**Why this priority**: Required by the project's observability commitments; the feature
functions without it.

**Independent Test**: Start a long-held step lock, inspect the dashboard's coordination view
and the logs for the waiting execution, and confirm the step, key, and holder are
identifiable.

**Acceptance Scenarios**:

1. **Given** a step holding coordination, **When** an operator inspects the running execution,
   **Then** the key, the owning step, and the holder are visible.
2. **Given** a step that could not take its key, **When** the outcome is inspected, **Then**
   it names the reactor, the step, and the key.
3. **Given** coordination is taken and released, **When** instrumentation is enabled, **Then**
   acquisition, release, and failure are observable as distinct events attributed to the step.
4. **Given** an execution parked by contention, **When** an operator inspects it, **Then** it
   is distinguishable from a failed execution and shows what it is waiting on.

---

### User Story 8 - Inline steps can declare coordination too (Priority: P3)

An author writing a short inline step declares its coordination in the step block, using the
same words a step class uses, so moving the step into a class later is a copy rather than a
rewrite.

**Why this priority**: Consistency; class steps are the project's preferred style, so this is
a completeness item.

**Independent Test**: Declare a lock on an inline step, confirm the same behavior as the class
form, then move it into a class unchanged.

**Acceptance Scenarios**:

1. **Given** an inline step declaring a lock, **When** two executions with the same key run,
   **Then** the behavior matches the class form exactly.

---

### Edge Cases

- The key expression raises, or returns an unusable value (nil, empty): the step fails before
  the work runs, naming the step and the cause. Work is never run unprotected because its key
  could not be computed.
- The step's work outlives the coordination's expiry: the hold is kept alive while the work
  runs, so a slow step does not silently lose exclusivity mid-flight.
- The holding process crashes while the step is running: the hold expires on its own so the
  key does not stay locked forever, and the next execution proceeds.
- The step is skipped by a condition or guard: nothing is taken for work that never runs.
- Two steps in one reactor declare the same key: the second takes it after the first released
  it; they do not deadlock, because both holds belong to the same execution.
- A step declares coordination and its work is handed to another process: the hold is taken in
  that process, and the hand-off is refused up front if the dispatching execution already
  holds the key (US4 scenario 4).
- An execution parks at an interrupt while a step's hold is live: the hold is kept through the
  gap bounded by its expiry and re-adopted on resume, without recording a second acquisition.
- Repeated contention: retries are bounded, and an execution that never wins reports the
  contention rather than snoozing indefinitely.
- The coordination backing store is unreachable: the step fails with a clear cause rather than
  proceeding unprotected.
- A step declares more than one primitive: they are taken in a fixed, documented order and
  released in reverse, so two steps declaring the same pair can never deadlock against each
  other.

## Requirements *(mandatory)*

### Functional Requirements

#### Declaration

- **FR-001**: A step class MUST be able to declare coordination for itself, with keys derived
  from the step's own resolved argument values.
- **FR-002**: The full coordination family MUST be declarable at step level — exclusivity, a
  concurrency ceiling, a rate ceiling, once-per-window deduplication, and strict ordering —
  each keeping its reactor-level meaning narrowed to the step.
- **FR-003**: Once-per-window deduplication at step level MUST skip the **step** and let the
  workflow continue, rather than halting the reactor as the reactor-level form does.
- **FR-004**: Strict ordering at step level MUST sequence executions at that step only, and
  its stop-the-line behavior MUST short-circuit that step for later positions rather than the
  whole workflow.
- **FR-005**: An inline step MUST be able to declare coordination with the same vocabulary a
  step class uses, with identical behavior.
- **FR-006**: Declarations MUST be introspectable, so tooling and operational views can report
  which steps coordinate and on what keys.
- **FR-007**: A key that cannot be computed MUST fail the step before its work runs, naming
  the step and the cause.
- **FR-008**: A step declaring multiple primitives MUST take them in a fixed, documented order
  and release them in reverse.

#### Scope and lifecycle

- **FR-009**: Coordination MUST be taken immediately before the step's work begins and
  released when the step finishes — on success, failure, or unexpected error.
- **FR-010**: Coordination MUST be taken in whichever process performs the step's work,
  including background workers, retried attempts, and runs resumed after an interrupt. It MUST
  NOT be held in a process that is only dispatching work elsewhere.
- **FR-011**: A step-scoped hold MUST NOT serialize the steps around it — concurrent
  executions MUST continue to overlap on every step that does not share the key.
- **FR-012**: Nothing MUST be taken for a step that a condition or guard prevents from running.
- **FR-013**: A hold MUST be kept alive while its step's work is still running, and MUST expire
  on its own if the holding process dies.
- **FR-014**: Declaring coordination MUST NOT change which steps run or in what order; it
  changes only when a step may begin.

#### Contention

- **FR-015**: When an execution running in a worker cannot take a step's coordination within
  its configured wait, the execution MUST be parked and retried later rather than failed. No
  step MUST be compensated and no side effect of the contended step MUST have occurred.
- **FR-016**: When an execution running synchronously in the calling process cannot take a
  step's coordination within its configured wait, the step MUST fail with a contention error
  naming the reactor, step, and key, and rollback MUST proceed as for any step failure.
- **FR-017**: Retries caused by contention MUST be bounded; an execution exceeding the ceiling
  MUST report the contention rather than being retried indefinitely.
- **FR-018**: A parked execution MUST keep ownership of coordination it already holds across
  the gap and re-adopt it on resume without recording a duplicate acquisition, falling back to
  competing normally if the hold lapsed while parked.

#### Re-entrancy

- **FR-019**: Holds MUST be owned by the execution, not by the individual step or reactor, so
  that any work within one execution proceeds on a key that execution already holds.
- **FR-020**: Nested holds on one key within one execution MUST be counted, and the key MUST
  remain unavailable to other executions until the outermost hold is released.
- **FR-021**: The keys an execution currently holds MUST be tracked for the execution as a
  whole, so that hand-off decisions and operational views can see them.
- **FR-022**: Ownership MUST NOT be shared across a hand-off to another process. Handing off
  work that declares a key the dispatching execution currently holds MUST be refused before
  dispatch, with a message naming the key, the holder, and how to restructure.
- **FR-023**: A step's declared coordination MUST be honored when the step class is invoked
  directly, not only when a reactor executes it.

#### Rollback

- **FR-024**: Exclusivity and concurrency ceilings declared by a step MUST be re-taken for that
  step's compensation and undo, using the same key computed from the same values.
- **FR-025**: Rate ceilings and deduplication windows MUST NOT gate compensation or undo —
  cleanup MUST never be suppressed by a forward-work quota.
- **FR-026**: Compensation that cannot take its key within the configured wait MUST be reported
  rather than silently skipped.

#### Compatibility and delivery

- **FR-027**: Reactor-level coordination declarations MUST continue to work unchanged; step
  level is additive and independent.
- **FR-028**: Acquisition, release, and acquisition failure MUST be observable as distinct
  events attributed to the step, carrying the key.
- **FR-029**: Step-level coordination MUST appear in the operational views that already show
  reactor-level coordination state, identified by its step, and a contention-parked execution
  MUST be distinguishable from a failed one.
- **FR-030**: The feature MUST ship a runnable demo reactor, a demo task, and a spec using only
  the shipped test surface, demonstrating the serialized path, the contention path, and the
  compensation path.
- **FR-031**: Documentation MUST show the step-scoped forms, state when to prefer them over
  reactor-level declarations, and describe the contention outcome on both execution paths.

### Key Entities *(include if data involved)*

- **Step Coordination Declaration**: what a unit of work declares about when it may run.
  Attributes: primitive kind, key expression (evaluated against the step's resolved
  arguments), limits, expiry, wait tolerance, keep-alive. Owned by exactly one step.
- **Hold**: the runtime fact that one execution holds one key. Attributes: key, owning
  execution, owning step, nesting count, acquired-at, expiry. Ends when the outermost hold is
  released or the expiry lapses.
- **Held-Key Registry**: the set of keys an execution currently holds, tracked for the
  execution as a whole and consulted when work is handed to another process.
- **Contention Outcome**: what an execution gets when it cannot take a key in time — a parked
  execution scheduled for a later attempt, or a contention failure, depending on whether it is
  running in a worker or synchronously.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Two concurrent executions of a reactor whose step declares the same key never
  overlap inside that step's work — 0 overlapping entries across a sustained concurrent run.
- **SC-002**: In the same run, every step that does not share the key overlaps freely; total
  wall-clock time is bounded by the contended step alone, not by the whole workflow.
- **SC-003**: Coordination is released within one step boundary of the step finishing, in 100%
  of outcomes including failures and unexpected errors.
- **SC-004**: 100% of worker-backed executions that lose contention still complete
  successfully on a later attempt, with zero compensations triggered by the contention itself.
- **SC-005**: A step whose work runs in a background worker is protected identically to one
  that runs in the calling process — the same concurrency test passes on both paths.
- **SC-006**: A nested arrangement holding one key at reactor, step, and nested-work level
  completes without waiting on itself, and the key becomes available to other executions only
  after the outermost release.
- **SC-007**: 100% of hand-offs that would deadlock on a held key are refused at dispatch with
  a message naming the key — none are allowed to wait indefinitely.
- **SC-008**: A killed process holding step coordination leaves the key available again
  without operator action.
- **SC-009**: A compensation of a step that declared exclusivity runs under that exclusivity in
  100% of rollbacks, verified by a concurrent execution being unable to enter the step's
  forward work during the compensation.
- **SC-010**: An operator can identify the step, key, and holder of any live step-level hold,
  and can tell a contention-parked execution from a failed one, without reading application
  code.
- **SC-011**: A step whose key cannot be computed never executes its work.
- **SC-012**: Every existing reactor-level coordination test passes unchanged.
- **SC-013**: The demo runs end to end in the project's container setup, showing the
  serialized, contended, and compensated paths.

## Assumptions

- The audience is developers authoring reactors and steps with this library.
- Step-scoped coordination reuses the existing coordination guarantees, expiry semantics,
  keep-alive behavior, and backing store; this feature changes the scope of a hold, not the
  mechanism.
- Re-entrancy reuses the rules nested workflows already follow, unchanged: holds owned by the
  execution, counted nesting, an execution-wide registry of held keys, refusal at hand-off
  when ownership cannot be shared, and keep-ownership-across-parks with re-adoption on resume.
- The key expression receives the step's resolved arguments — the same values the step's work
  receives.
- Contention behavior deliberately differs by execution path: parked-and-retried in a worker,
  wait-then-fail synchronously. This is a consequence of there being no queue to step aside
  into in a synchronous run; it is called out in the documentation so authors know which they
  will get. A synchronous author who wants the parked behavior can run the workflow in the
  background.
- Compensation re-takes only the mutual-exclusion primitives. Rate ceilings and deduplication
  windows gate whether forward work happens, not whether cleanup happens.
- Declaring coordination is opt-in per step; steps that declare none behave exactly as today.
- Reactor-level declarations remain the right tool for "this whole workflow is exclusive"; step
  level is for "this one operation is exclusive". Documentation must say which to reach for.
- This feature composes with steps declaring their own inputs (see
  `specs/002-step-input-contracts/`), since a key expression reads the step's arguments, but
  does not require it — a step wired only with reactor-side arguments can declare coordination.
