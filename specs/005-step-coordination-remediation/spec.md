# Feature Specification: Step Coordination Review Remediation

**Feature Branch**: `independent_step_locks`

**Created**: 2026-09-23

**Status**: Draft

**Input**: User description: "specs/step-coordination-review-remediation.md" — the `/speckit-review`
of `003-step-lock-declarations` at `ca963444` returned **BLOCKED** with 4 blockers (F1–F4) and
5 findings (F5–F9). This feature restores the guarantees that feature promised. It fixes the two
root causes behind five of the findings once, and fixes the rest individually.

## Context

Step-scoped coordination (feature 003) is implemented and its test suite passes. The review
found defects in paths the suite does not cover:

- a contention park inside a nested workflow,
- rollback while another execution holds the key,
- a synchronous out-of-turn arrival at a strictly ordered step,
- a step or retry that outlives the ordering timeout.

Five of the nine findings come from two design flaws:

- **Parks do not behave the same at every nesting level.** This causes F2 and F4.
- **Step-level strict ordering has its own copy of the reactor-level rules, and the copy has
  drifted.** This causes F3, F7 and F8.

This round fixes each flaw once instead of patching each symptom. The branch has already been
through four review rounds, and patching symptoms kept exposing the next defect. The parts of
003 that passed review stay as they are: one enforcement point per invocation, one argument
derivation, a park releasing the contended step's own holds, the retry gate and the validation
gate.

## User Scenarios & Testing *(mandatory)*

The actors are the people who use the gem:

- **Workflow authors** declare coordination on steps and read the results of executions.
- **Operators** debug stalled or failed executions.
- **Instrumentation authors** write middleware that attributes coordination events.
- **Maintainers** carry the regression suite forward.

### User Story 1 - An undo is not dropped because the key is busy (Priority: P1) — F1

A step that took an exclusive lock succeeded, then a later step failed. Rollback reaches the
locked step while another execution is inside the same step for the same key. That is the
contention the lock exists for. Today the undo gives up at once and the refund never runs. The
caller's failure names only the downstream error, so nobody learns that cleanup was skipped.

After this change, the undo waits for the key for a bounded time, long enough for the other
holder to finish or for its hold to expire. If an undo still does not run, the failure returned
to the caller says which undo did not run and why.

**Why this priority**: A dropped undo leaves application state wrong, and nothing reports it.
The trigger is contention, which is the normal case for a lock. This breaks Principle II (saga
integrity).

**Independent Test**: Run a synchronous workflow. Its locked step has an undo, and a later
step fails while another owner holds the same key and releases it shortly after. Confirm the
undo ran. Then keep the key held past the rollback wait, and confirm the failure lists the undo
that did not run.

**Acceptance Scenarios**:

1. **Given** a locked step succeeded and a later step fails while another execution holds the
   same key, **When** the other holder releases within the rollback wait, **Then** the undo
   runs while holding the key, and the workflow's failure reports no skipped undo.
2. **Given** the same situation, **When** the key stays held past the rollback wait, **Then**
   the failure returned to the caller lists the undo that did not run, with the step, the key,
   and the reason.
3. **Given** an undo raises an error, **When** the execution's failure is returned, **Then**
   that undo is listed as not completed, with the step and the error. Today it appears only in
   the trace.
4. **Given** a step declares no rollback wait, **When** rollback meets a held key, **Then** the
   wait defaults to the declared hold's expiry, not the forward-work wait (which defaults to
   zero).
5. **Given** a step declares a rollback wait explicitly, **When** rollback meets a held key,
   **Then** that wait is used.

---

### User Story 2 - A park at any depth keeps outer holds and charges quotas once (Priority: P1) — F2, F10

A background workflow holds its own lock and applies its own rate ceiling. It runs a nested
workflow whose step contends for a key and parks. Today the outer workflow releases its lock
at the park, so another execution can enter the protected section during the gap. On
redelivery, the outer rate ceiling is charged a second time.

After this change, a park anywhere on the execution's stack behaves the way a park at the top
level already does:

- every level keeps the coordination it held before the park,
- every level re-adopts that coordination on redelivery,
- workflow-level quotas are charged once per execution.

This holds for contention parks and for parks that wait on a background result.

**Why this priority**: Exclusion that lapses partway through an execution defeats the lock.
Charging the ceiling twice throttles legitimate work. Both contradict what 003 documents.

**Independent Test**: Use a background workflow that holds a lock and a rate ceiling and runs
a nested workflow whose first step is locked. Hold the nested key from outside, perform once
(the execution parks), release the key, and perform again. Confirm that the outer lock stayed
held between the two attempts and that the rate ceiling was charged once.

**Acceptance Scenarios**:

1. **Given** a nested workflow's step parks on contention, **When** the park happens, **Then**
   the outer workflow's lock stays held until redelivery and no other execution can take it
   in between.
2. **Given** the same park, **When** the execution is redelivered and completes, **Then** the
   outer workflow's rate ceiling was charged once and its period gate was applied once.
3. **Given** the parked step is the first step of the outer workflow, or the first step of
   the nested workflow, **When** the execution is redelivered, **Then** it is not treated as a
   fresh start and no workflow-level quota is charged again.
4. **Given** a nested workflow holds its own lock and parks while waiting on a background
   result, **When** the park happens, **Then** the nested workflow's lock also stays held
   across the gap.
5. **Given** the hold lapsed while parked, **When** the execution is redelivered, **Then** it
   competes for the key normally, as in 003 FR-018, and still charges no quota again.
6. **Given** a nested park keeps happening, **When** the contention ceiling is reached,
   **Then** the execution reports the contention as it does at the top level, and releases its
   holds the way any failure does.
7. **Given** an element of a parallel map parks on contention, **When** the key frees, **Then**
   the element is retried and completes, as it does today.
8. **Given** a nested workflow running in a worker reads the result of a background step that
   has not finished, **When** it reaches that read, **Then** the whole execution parks and
   later completes. Today the outer workflow fails instead. This was found during planning
   (F10) and is already on `main`.

---

### User Story 3 - Step-level strict ordering follows the reactor-level rules (Priority: P1) — F3, F7, F8

A step declares strict ordering. Three executions arrive in order. The first holds its turn.
The second arrives synchronously, out of turn, and fails with a contention error, which is
expected. The third runs later with no contention. Today it reports success, but the ordered
step was silently skipped: the body never ran and the step has no value. This continues for
every later position until the batch drains.

The step-level gate also disagrees with the reactor-level gate in two other ways:

- A step whose ordering batch has expired runs its body anyway, unordered, alongside the new
  batch's current holder.
- The keep-alive for an ordering position keeps running after an abnormal exit. The key's
  sequence then stalls until the process restarts.

After this change, the step level and the reactor level make the same decision for every
ordering state.

**Why this priority**: A workflow that reports success while skipping its core work is silent
data loss. Running a body out of order defeats the reason for declaring strict ordering.

**Independent Test**: Run three executions against one strictly ordered step: the first holds
its turn, the second arrives synchronously out of turn, and the third arrives after the first
finishes. Confirm the third runs the step body and gets its value.

**Acceptance Scenarios**:

1. **Given** a synchronous execution arrives out of turn at a strictly ordered step, **When**
   it fails with a contention error, **Then** it gives up its position without marking it
   failed, and later executions run the step body normally.
2. **Given** an execution reached the head of the line and then failed, **When** later
   executions arrive, **Then** they are skipped with the ordering-chain-failed reason. Strict
   chain semantics for a real failure are unchanged.
3. **Given** a step's retry arrives after its ordering batch expired, **When** the gate
   evaluates it, **Then** the step is skipped with a distinct stale-batch reason and its body
   does not run.
4. **Given** a late straggler arrives after the batch drained, **When** the gate evaluates it,
   **Then** it runs, as it does at the reactor level.
5. **Given** a step's body ends in a way that is not an ordinary application error (for
   example, the process runs out of memory or the stack overflows), **When** the step ends,
   **Then** the keep-alive for its ordering position stops, and the position is released no
   later than the ordering timeout.
6. **Given** a reader of the step-level ordering documentation, **When** they read it, **Then**
   it warns, as the reactor-level section does, that strict ordering is meant for background
   execution.

---

### User Story 4 - A background step's park state does not clobber its parent (Priority: P2) — F5

A step dispatched to its own background job parks on contention. It records its ordering
position and its waiting marker by overwriting the parent execution's whole saved state, while
the parent may still be running sibling steps and saving that same state.

- **If the parent saves last**, the step loses its place in line. The old position then blocks
  everyone behind it for the ordering timeout, which is 10 minutes by default.
- **If the step saves last**, the parent's newer progress is lost. A crash before the parent's
  next save re-runs steps that already completed.

**Why this priority**: The window is real but narrow: sibling steps must run while an async
step parks. Other paths already partly limit the damage. It still breaks 003 FR-018 and
Principle II.

**Independent Test**: Park a background-dispatched ordered step while the parent saves newer
progress. Confirm that the step's ordering position survives, that the parent's progress
survives, and that the dashboard still shows the step as waiting.

**Acceptance Scenarios**:

1. **Given** a background-dispatched step parks on contention, **When** its park state is
   saved, **Then** it is saved with that step's own record and the parent's saved state is
   not written.
2. **Given** the parent saves progress after the step parked, **When** the step is redelivered,
   **Then** it resumes at its original ordering position.
3. **Given** the step parked after the parent saved, **When** the parent is later recovered
   from its saved state, **Then** no step that already completed runs again.
4. **Given** a parked background step, **When** an operator opens the dashboard, **Then** the
   step shows as waiting, not failed.

---

### User Story 5 - Instrumentation attributes coordination to the right step (Priority: P2) — F4, F9

A middleware author wants to tag each coordination event with the step it belongs to, or
with none for a workflow-level hold. The documentation tells them to use "the current step".
That is wrong in two cases:

- After a park and redelivery, a workflow-level release event reports the step that parked.
- When one step calls another step class directly, events and contention messages name the
  calling step instead of the step that was called.

A dedicated attribution already exists and is correct in both cases, but the documentation
does not point to it.

**Why this priority**: Wrong attribution misleads operators during incidents (Principle IV).
The first case is a documentation error that can ship on its own.

**Independent Test**: Use a background workflow with a lock, a locked step and a recording
middleware. Park the step once, then let it complete. Confirm that every workflow-level event
is attributed to no step. Then call a step class directly from inside another step, and
confirm the invoked class is named.

**Acceptance Scenarios**:

1. **Given** a workflow-level coordination event on any run, including a resumed or
   redelivered run, **When** a middleware reads the event's step attribution, **Then** it is
   empty.
2. **Given** a step-level coordination event, **When** a middleware reads the step
   attribution, **Then** it names the coordinating step.
3. **Given** a step class is invoked directly from inside another step, **When** it takes
   coordination, contends, or fails to acquire, **Then** the events and the contention message
   name the invoked step, not the caller.
4. **Given** the middleware and coordination documentation, **When** an author reads how to
   attribute events, **Then** it names the dedicated attribution, and the example uses it.

---

### User Story 6 - Authors are warned about cross-level livelock (Priority: P3) — F6

Workflow X holds key A at the workflow level and needs key B at a step. Workflow Y holds key B
at the workflow level and needs key A at a step. A step park keeps the workflow-level hold, so
each waits on the other:

- with the default snooze ceiling, both give up after about 20 attempts;
- with an unbounded ceiling, they wait forever.

**Why this priority**: The behavior is intended. Keeping the outer hold is what User Story 2
guarantees. The fix is guidance, not runtime change.

**Independent Test**: Read the coordination documentation. Confirm that it says a step park
keeps the workflow-level hold, and that it gives a single rule for nesting order.

**Acceptance Scenarios**:

1. **Given** the step coordination documentation, **When** an author reads the park section,
   **Then** it states that a step park keeps the workflow's own holds across the gap.
2. **Given** the same documentation, **When** an author combines keys at the workflow and step
   levels, **Then** it tells them to nest keys in one global order across both levels, and it
   shows the A→B / B→A example and what happens with a bounded and an unbounded snooze
   ceiling.

---

### User Story 7 - Regression coverage is organized by behavior (Priority: P3)

Maintainers need the next review to group problems by root cause, not by review round. Each
defect in this round gets a permanent regression test named for the behavior it protects. The
tests from earlier review rounds are reorganized by behavior: park, rollback, ordering and
observability.

**Why this priority**: This does not change runtime behavior. It keeps the review loop from
restarting.

**Independent Test**: List the regression suite. Confirm that no file is named after a review
round, and that every finding F1–F10 maps to a named behavior test.

**Acceptance Scenarios**:

1. **Given** the regression suite after this change, **When** it is listed, **Then** its tests
   are grouped by behavior and no file is named after a review round.
2. **Given** each finding F1–F10 that can be reproduced, **When** its regression test runs
   against the code before the fix, **Then** the test fails, and after the fix it passes.
3. **Given** the reorganization, **When** coverage is compared before and after, **Then** no
   test case from the earlier review rounds has been lost.

---

### Edge Cases

- **Forward holder crashes during a rollback wait.** Its hold expires at the declared expiry,
  and the undo proceeds within the rollback wait, which defaults to that expiry.
- **Forward holder keeps renewing past the rollback wait** (a long step). The undo is listed
  as not run on the failure. It is never dropped silently.
- **Several undos fail in one rollback.** All of them are listed, in rollback order.
- **An undo that does not run is on a step with no exclusivity.** It is still listed, with no
  key.
- **A park two or more levels deep** (a nested workflow inside a nested workflow). Every level
  keeps its holds, and no level charges its quota again.
- **A park followed by a second park at a different depth** in the same execution. Quotas are
  still charged once.
- **A nested workflow reaches the contention ceiling.** The contention is reported. Outer
  holds are released and rollback proceeds as for any failure.
- **A synchronous out-of-turn arrival when the position was already at the head.** This is not
  out-of-turn. A failure there still marks the chain failed.
- **A retry's backoff is longer than the ordering timeout.** The later retry is skipped as
  stale. Its body does not run.
- **A background step's worker crashes between parking and saving its record.** The
  redelivery takes a new position, and the old position is released by the ordering timeout.
  This is the same outcome as a crash before any park.
- **A direct step invocation with no execution passed.** It is still its own execution and is
  attributed to the invoked step (003 FR-023, unchanged).

## Requirements *(mandatory)*

### Functional Requirements

#### Rollback under contention (F1)

- **FR-001**: When the undo or compensation of a step that declared exclusivity finds its key
  held by another execution, it MUST wait for the key up to a rollback wait. The rollback wait
  is separate from the step's forward-work wait tolerance.
- **FR-002**: The rollback wait MUST default to the expiry of the declared hold. A concurrency
  ceiling has no hold expiry, so its rollback wait MUST default to 60 seconds, the default
  expiry of an exclusive lock. A step declaration MUST be able to set it explicitly.
- **FR-003**: Rollback MUST still never park (003 behavior, unchanged). The rollback wait is
  the only way it tolerates contention.
- **FR-004**: The failure returned to the caller MUST list every undo or compensation that did
  not complete. This covers an undo that could not acquire its key within the rollback wait and
  an undo that raised an error. Each entry names the step, the key (if any) and the reason.
- **FR-005**: Existing trace entries and failed-undo hooks for these cases MUST keep working.
  The documentation MUST name the trace entry type and the hook correctly.

#### Parks at any nesting depth (F2, F10)

- **FR-006**: When an execution parks at any nesting depth, every workflow level on its stack
  MUST keep the coordination it held before the park and re-adopt it on redelivery. This
  extends 003 FR-018 to nested levels. It applies to contention parks and to parks that wait
  on a background result.
- **FR-007**: Workflow-level rate ceilings and period gates MUST be charged once per
  execution. This holds for any number of parks at any depth, including a park in the first
  step of the outer workflow or of a nested workflow.
- **FR-008**: Whether an execution is starting fresh MUST NOT depend on which step it is
  positioned at. This applies both to charging quotas and to deciding whether a strict-ordering
  position is new. A redelivered execution is never fresh.
- **FR-009**: The behavior of contention parks MUST NOT change: retry later, a budget separate
  from failure retries, and a bounded ceiling (003 FR-015, FR-017). This includes parks in
  parallel map elements and in background-dispatched steps.

#### Step-level strict ordering (F3, F7, F8)

- **FR-010**: Step-level strict ordering MUST make the same gate decision as reactor-level
  strict ordering for every ordering state: in turn, out of turn, predecessor failed, batch
  expired, and batch drained. Each decision is then mapped to its step-level outcome (run,
  wait, skip, or run as a late straggler).
- **FR-011**: A synchronous execution that arrives out of turn and fails with contention MUST
  give up its position without recording it as failed. Later executions MUST proceed without
  waiting for that position's timeout, and MUST NOT be skipped because of it.
- **FR-012**: A position that reached the head of the line and then failed MUST still be
  recorded as failed. Later positions are then skipped with the ordering-chain-failed reason
  (unchanged).
- **FR-013**: A step whose ordering batch expired MUST be skipped with a distinct stale-batch
  reason, and its body MUST NOT run.
- **FR-014**: The keep-alive for a step's ordering position MUST stop on every exit from the
  step, including exits caused by process-level errors that are not application errors.
- **FR-015**: A step's ordering position MUST be released once per attempt, based on one
  decision about how the attempt ended: success, failure, retry pending, parked, or
  synchronous contention.
- **FR-016**: The step-level ordering documentation MUST warn that strict ordering is meant
  for background execution, as the reactor-level documentation does.

#### Background step park state (F5)

- **FR-017**: A background-dispatched step's park state MUST be saved with that step's own
  result record. Park state here means its ordering position and its waiting marker. The
  step's worker MUST NOT write the parent execution's saved state to record a park.
- **FR-018**: A background-dispatched step MUST resume at its saved ordering position on
  redelivery, whatever the parent saved in the meantime.
- **FR-019**: Operational views MUST still show a parked background step as waiting, not
  failed, using that step's own record.

#### Attribution (F4, F9)

- **FR-020**: Every coordination event MUST expose a step attribution that names the
  coordinating step for step-level events and is empty for workflow-level events. This MUST
  hold on first runs and on resumed or redelivered runs.
- **FR-021**: When a step class is invoked directly, the step attribution and the contention
  messages MUST name the invoked step, not the calling step.
- **FR-022**: The middleware documentation and the coordination documentation MUST tell
  authors to use the dedicated step attribution, not the current step, and their examples MUST
  use it.

#### Guidance (F6)

- **FR-023**: The coordination documentation MUST state that a step park keeps the workflow's
  own holds across the gap.
- **FR-024**: The coordination documentation MUST tell authors to nest keys in one global
  order across the workflow and step levels. It MUST show the cross-level A→B / B→A livelock
  and its outcome with a bounded and with an unbounded snooze ceiling.

#### Design record

- **FR-025**: Before implementation starts, three decisions MUST be recorded in the design
  record of feature 003, each with its rationale:
  - rollback waits with a bounded wait of its own (D-F1),
  - a synchronous out-of-turn arrival does not poison the ordering chain (D-F3),
  - every executor on the stack keeps its holds on a park (D-A2).
- **FR-026**: The design record MUST also correct three items:
  - 003 FR-026, to require bounded waiting and reporting on the failure;
  - the open-risk row in 003's research, which claims compensation waits then reports;
  - decision D4, which describes the park mechanism.

#### Verification and delivery

- **FR-027**: Each finding F1–F10 that can be reproduced MUST get a permanent regression test,
  named for the behavior it protects and confirmed failing before its fix. R1–R5 in the input
  describe the setups.
- **FR-028**: The regression tests from earlier review rounds MUST be reorganized into files
  named by behavior (park, rollback, ordering, observability), without losing any test case.
- **FR-029**: Reactor-level coordination behavior MUST NOT change, except where this
  specification says so. No existing test may change its expectation unless it encodes one of
  the defects fixed here.
- **FR-030**: The step-coordination demo MUST demonstrate that an undo runs under contention,
  and how the failure reports an undo that did not run. Its spec MUST use only the shipped test
  surface. If a helper or matcher is missing, it MUST be added to that surface (Principle VI).
- **FR-031**: README, the affected documentation files and the changelog MUST be updated in
  the same change, under Bug Fixes for the corrected behavior and under Features for the
  rollback wait and the failure listing.

### Key Entities

- **Rollback Wait**: how long rollback tolerates a key held by another execution before it
  gives up on an undo. It belongs to the step's exclusivity declaration and defaults to that
  declaration's hold expiry. It is independent of the forward-work wait.
- **Unrun Undo Entry**: an undo or compensation that did not complete. It records the step,
  the key (if any), the reason (could not acquire, or raised) and its position in rollback
  order. The caller receives these entries on the execution's failure.
- **Execution Admission**: the saved fact that an execution has passed its workflow-level
  quotas and gates. Once set, it survives every park and redelivery. It replaces inferring a
  fresh start from the step the execution is positioned at.
- **Ordering Position**: an execution's place in a strict-ordering line. It has a key, a
  batch, a turn number and a state: waiting, at head, completed, failed, or given back. Its
  keep-alive belongs to exactly one attempt.
- **Step Result Record (background step)**: the record a background-dispatched step owns. It
  already holds the time the step is parked until and its contention attempt count. It now
  also holds the step's ordering position and waiting marker. The step's worker is its only
  writer.
- **Step Attribution**: the step a coordination event belongs to, or none for a
  workflow-level event. It is independent of where the execution is positioned.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: When a locked step's undo meets a key that another execution releases within the
  rollback wait, the undo runs in 100% of runs.
- **SC-002**: 100% of undos that do not complete appear on the failure returned to the caller.
  None is visible only in traces.
- **SC-003**: A background workflow with a rate ceiling that parks N ≥ 1 times, at any nesting
  depth, is charged exactly once. The same holds for its period gate.
- **SC-004**: While an execution is parked at any nesting depth, no other execution acquires
  any key that an outer level of the parked execution held before the park, in 100% of runs.
- **SC-005**: After a synchronous out-of-turn arrival fails at a strictly ordered step, 100% of
  later in-turn executions run the step body. None reports success with the step skipped.
- **SC-006**: A strictly ordered step whose batch has expired runs its body 0 times.
- **SC-007**: After any abnormal exit from a strictly ordered step, the key's sequence
  advances within the ordering timeout. It never stalls until the process restarts.
- **SC-008**: 100% of workflow-level coordination events are attributed to no step, including
  events on resumed runs. 100% of events from a directly invoked step name the invoked step.
- **SC-009**: When a background step parks while its parent saves progress, 0 ordering
  positions are lost and 0 completed steps run again.
- **SC-010**: Every finding F1–F10 that can be reproduced maps to a behavior-named regression
  test that failed before its fix and passes after. No regression test file is named after a
  review round.
- **SC-011**: The full test suite, the lint check, the step-coordination demo task and the
  demo spec all pass with 0 failures and 0 new lint offenses.

## Assumptions

- **Decisions.** The review's recommended option is taken for each open decision:
  - **D-F1 (a):** rollback waits up to its own bound, which defaults to the hold's expiry, and
    any undo that did not run is reported on the failure.
  - **D-F3 (a):** a synchronous out-of-turn arrival gives its position back without poisoning
    the chain, which allows a gap. The reactor level already reaches the same result after the
    ordering timeout.
  - **D-A2 (a):** every executor on the stack keeps its holds on a park.

  If any of these is reversed, the matching requirements change: FR-001 to FR-004, FR-011 and
  FR-006.
- **Mechanism.** Contention parks and background-result parks may move to one shared
  mechanism. The step-level gate may reuse the reactor-level gate logic. How to do either is a
  planning decision. This specification fixes only the behavior. Removing the old park
  mechanism is allowed if FR-009 still holds.
- **Unchanged.** Rollback never parks, and the rollback wait is its only contention tolerance.
  Rate ceilings, period gates and strict ordering still do not gate rollback (003 FR-025).
- **F6 is guidance only.** No runtime detection of cross-level livelock is added. Keeping the
  outer hold across a step park is intended behavior.
- **Versioning.** The rollback wait setting and the failure listing are additions to the
  public API, so the release is a MINOR version. Nothing is removed.
- **Delivery.** This work lands on the same branch as feature 003 and must be done before 003
  merges. The first delivery is the documentation-only corrections: the F4 attribution text,
  the name of the failed-undo trace entry, and the F6 nesting rule.
- **Out of scope.** These are pre-existing on `main` and were noted during the review:
  - The completion path of the background step worker also overwrites the parent's saved
    state. It has the same two-writer risk as F5, for the completion record. It may be folded
    in if it falls out of the FR-017 change at no extra cost, but it is not required.
  - The reactor-level release event reports the key with a storage prefix, while every other
    coordination event uses the bare key.
  - There is one lint offense in a map spec file that this branch does not touch.
