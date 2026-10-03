# Feature Specification: Distributed Map Rollback and Bounded Fan-out

**Feature Branch**: `distributed_map_undo`

**Created**: 2026-09-30

**Status**: Draft, revised 2026-09-30 by /speckit-plan (back-pressure bound, at-least-once window, dispatch order; see research R-02, R-07, R-08) and after /speckit-analyze (started-element coverage, per-throw bound, cancel guard, FR-027)

**Input**: User description: "Improvements to maps execution and undo. (1) It is not clear whether
rollback of a map run in batches executes every element's compensation inline, loading all the
elements in a single thread. When processing a huge list with a declared batch_size, each map
element should be rolled back the same way it was executed: using the batch size, each undo in its
own job, with back pressure. (2) Rename the `fail_fast` configuration; what it really means is
'all or none'. (3) `fan_out` without batch_size fans out every element at once; define a maximum
per throw, i.e. a default batch size (50). (4) Fix 'Fan-out map inside a composed child' from
specs/future_improvements.md."

## Context

What happens today, and what this feature changes:

| Area | Today | After this feature |
| --- | --- | --- |
| Rolling back a fan-out map | One process loads the state of **every** completed element at once and undoes them one after another. Time and memory grow with the element count (10,000 elements take about a minute in the test suite). | Each started element gets its own rollback job, enqueued one batch at a time, the same way the elements ran. |
| Rolling back an inline map | Same single pass, all element states loaded at once. | Still in the executing process (it ran there), but element states are read one bounded chunk at a time. |
| `fan_out` without `batch_size` | Every element is enqueued at once: no back pressure. | A default batch size of 50 applies. |
| `fail_fast` | Name suggests "stop early"; the real contract is "every element succeeds or none is kept". | Renamed `atomic`; `fail_fast` keeps working with a deprecation warning. |
| Fan-out map inside a composed child | The root never finishes: the map's completion resumes the child as a standalone run, and nothing resumes the root. | The root resumes and finishes; rollback through the root also works. |

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Roll back a large fan-out map the way it ran (Priority: P1)

A developer runs a reactor whose `fan_out` map processes a large collection (for example 10,000
payments) with a batch size. A later step fails, or the map itself fails under atomic, or an
operator undoes the run manually. Every completed element must be rolled back. Instead of one
process loading all 10,000 element states and undoing them serially, the rollback is dispatched
like the forward run: one rollback job per started element, enqueued one batch at a time, the next
batch enqueued as the previous batch's last element reports. Only after every element has reported back are the
steps before the map undone.

**Why this priority**: This is the core gap. Today a large map's rollback can exceed job timeouts
and memory limits in one process, so the saga's compensation promise does not hold at the scale
fan-out is meant for.

**Independent Test**: Run a reactor with a fan-out map of N elements and a declared batch size B,
then fail a step after the map. Verify that each completed element was rolled back by its own job,
that no single throw enqueued more than B element rollback jobs, that the steps before the map were
undone only after the last element rollback reported, and that the run ends failed with every
element rolled back exactly once.

**Acceptance Scenarios**:

1. **Given** a completed fan-out map of 1,000 elements with batch size 50, **When** a step after the
   map fails, **Then** 1,000 element rollback jobs run, no throw enqueuing more than 50, and the
   steps before the map are undone after all 1,000 report back.
2. **Given** an atomic fan-out map where element 7 fails while others completed, **When** every
   index has settled, **Then** every element that started gets a rollback job with the same back
   pressure. Only the completed ones undo anything. The failed element's job finds nothing to undo,
   because it already rolled itself back, and reports `not_needed`. Skipped elements never started
   and get no job.
3. **Given** a finished run containing a completed fan-out map, **When** an operator triggers a
   manual undo, **Then** the steps after the map are undone, the map's elements are rolled back
   through distributed jobs, and the steps before the map are undone once those report back; the
   run is not shown as finished until then.
4. **Given** one element's rollback fails, **When** the other element rollbacks complete, **Then**
   the steps before the map are still undone and the run's final failure lists the element's
   rollback failure attributed to the map step and element index.
5. **Given** a worker dies in the middle of an element's rollback, **When** the job is redelivered
   or recovered, **Then** that element's rollback resumes after its last recorded undo (only the step
   whose undo was cut off may run again), and the run still completes its rollback.
6. **Given** a completed inline (non-fan-out) map, **When** it is rolled back, **Then** the rollback
   runs in the executing process as today, reading element states in bounded chunks rather than all
   at once.

---

### User Story 2 - Fan-out map inside a composed child finishes (Priority: P2)

A developer composes a child reactor into a root, and the child contains a `fan_out` map. Today the
root stays `running` forever: when the map completes, the child is resumed as if it were its own
top-level run, finishes in its own record, and nothing resumes the root. After this feature the
root resumes after the map and runs to completion. If the map or a later step fails, rollback
travels through the root: the map's elements, the child's earlier steps and the root's earlier
steps are all undone.

**Why this priority**: A silent hang with no error is the worst failure mode for a workflow engine.
It already exists on main and blocks composing any reactor that uses fan-out.

**Independent Test**: Root composes Child; Child runs a fan-out map with batch size 1. Drain all
background work. The root finishes successfully and returns the expected result. Repeat with a
pause (interrupt) after the map, and with a failing step after the map in the root.

**Acceptance Scenarios**:

1. **Given** a root composing a child with a fan-out map, **When** all element work is processed,
   **Then** the root resumes, runs its steps after the compose step, and finishes `completed`.
2. **Given** the same setup with an interrupt after the map in the child, **When** the interrupt is
   resumed, **Then** the root finishes `completed`.
3. **Given** the same setup where a root step after the compose step fails, **When** rollback runs,
   **Then** the map's completed elements are rolled back (distributed, per User Story 1), then the
   child's earlier steps, then the root's earlier steps, and the root ends `failed`.
4. **Given** the child's map element fails under atomic, **When** every index has settled,
   **Then** the failure is applied to the root's run (not only the child's record) and the root
   rolls back and ends `failed`.
5. **Given** compose nested two levels deep with the fan-out map at the deepest level, **When** the
   map completes, **Then** the top-level root resumes and finishes.

---

### User Story 3 - Fan-out never floods the queue by default (Priority: P2)

A developer writes `fan_out` without a batch size on a map whose source may be large. Today every
element is enqueued at once. After this feature no throw enqueues more than 50 element jobs; the
next throw fires when the previous batch's last element finishes. Declaring a batch size still
overrides the default.

**Why this priority**: One missing option should not be able to enqueue millions of jobs. A safe
default protects queues and storage without any code change by the developer.

**Independent Test**: Run a fan-out map of 500 elements with no declared batch size. Verify that
no throw enqueued more than 50 element jobs and that all 500 results are collected.

**Acceptance Scenarios**:

1. **Given** a fan-out map with no batch size and 500 elements, **When** it runs, **Then** no throw
   enqueues more than 50 element jobs and all 500 outcomes are collected.
2. **Given** a fan-out map with no batch size and 20 elements, **When** it runs, **Then** all 20 are
   dispatched at once, as today.
3. **Given** a fan-out map with an explicit batch size of 200, **When** it runs, **Then** 200 is used,
   not the default.
4. **Given** a fan-out map with no batch size that must be rolled back, **When** rollback runs,
   **Then** it uses the same default of 50 for element rollback jobs.

---

### User Story 4 - The map failure policy says what it means (Priority: P3)

A developer reading or writing a map sees `atomic` instead of `fail_fast`. With it on (the
default), the map succeeds only if every element succeeds; if any element fails, no new element
starts and every completed element is rolled back. With it off, the map completes with a
per-element outcome, failed elements roll back themselves and succeeded ones are kept. Existing
reactors that declare `fail_fast` keep working unchanged and see a deprecation warning pointing to
the new name.

**Why this priority**: A naming fix with no behavior change. It prevents misuse (reading
`fail_fast false` as "keep going but still roll back on failure") but nothing breaks without it.

**Independent Test**: Declare `atomic false` on a map where one element fails: the map
completes with one failure and the other results. Declare `fail_fast false` on the same map: same
outcome plus one deprecation warning naming `atomic`.

**Acceptance Scenarios**:

1. **Given** a map with no failure policy declared, **When** one element fails, **Then** the map fails
   and every completed element is rolled back (`atomic` is the default).
2. **Given** `atomic false`, **When** one element fails, **Then** the map completes with that
   element's failure alongside the other elements' results.
3. **Given** an existing reactor declaring `fail_fast true` or `fail_fast false`, **When** the class
   is loaded, **Then** it behaves exactly as `atomic true` / `atomic false` and a single
   deprecation warning names the replacement.
4. **Given** a map declaring both `fail_fast` and `atomic`, **When** the class is loaded,
   **Then** a definition error explains that only one may be declared.
5. **Given** element jobs enqueued by the previous gem version (carrying the old setting), **When**
   they are processed after an upgrade, **Then** they apply the same policy they were enqueued with.

---

### Edge Cases

- **Nothing to undo**: a fan-out map where no element ever started (all were skipped) dispatches
  no rollback jobs, and the parent continues its rollback at once. A map whose started elements all
  failed or halted still dispatches their jobs; each one reports `not_needed` and undoes nothing.
- **Duplicate trigger**: the same element rollback job delivered twice, two rollback jobs for the
  same element at once, or rollback triggered twice for one run. Each element is undone once
  (FR-006, FR-027).
- **Element still in flight, or its state expired**: reported per FR-007, never skipped silently.
- **Cancel during rollback**: cancelling a run that is `rolling_back` is rejected. Cancelling would
  mark the run finished and strand the steps before the map un-undone.
- **Rollback work lost** (worker killed, job dropped): the existing recovery sweep finds the stalled
  map rollback and re-dispatches the missing element rollbacks, as it does for forward fan-out.
- **Map nested inside a map element** (runs inline): its rollback runs inside the outer element's
  rollback job, inline.
- **Batch size larger than the source**: everything is dispatched at once, forward and rollback.
- **Inline job-testing mode**: distributed rollback produces the same final outcome when background
  jobs run immediately in-process.
- **Failure while the map is still dispatching** (atomic): rollback starts only after every
  index has settled, as today, so elements that were in flight and completed are included.
- **Composed child with a fan-out map that is itself undone manually from the root**: the manual
  undo reaches the map through the root and distributes the element rollbacks.

## Requirements *(mandatory)*

### Functional Requirements

#### Distributed rollback of fan-out maps

- **FR-001**: Rolling back a fan-out map — compensating it after it failed, undoing it after a later
  step failed, or undoing it through a manual undo of the run — MUST roll back each completed
  element in its own background job.
- **FR-002**: Element rollback jobs MUST use the forward run's back pressure (FR-018):
  - no single throw enqueues more than the effective batch size;
  - the next throw fires when the previous throw's last position has reported.

  Jobs still running from earlier throws are not counted. A slow element does not hold back later
  throws, as in the forward run.
- **FR-003**: No job taking part in a map's rollback MUST load the state of more than one element
  at a time. The coordinating execution's memory MUST NOT grow with the element count, except for
  the rollback failures it reports. It MAY read per-element outcome records in bounded chunks.
- **FR-004**: The steps before the map MUST be undone only after every element rollback has
  reported back, preserving reverse-order saga semantics at the step level.
- **FR-005**: Element rollback failures MUST be collected into the run's final failure, each
  attributed to the map step and element index, in the same shape as today's rollback failures.
- **FR-006**: Each completed element MUST be rolled back once despite duplicate delivery or
  duplicate triggers. An element whose rollback was interrupted (worker killed) MUST resume after
  its last recorded undo: a step whose undo completed and was recorded is never undone again; only
  the step whose undo was cut off may run again (at-least-once, as for any background job).
- **FR-007**: Rollback coverage rules MUST stay as today:
  - only completed elements, or aborted ones with completed steps, undo anything;
  - every element that started gets a rollback job, and one that failed (self-rolled-back) or halted
    reports `not_needed` without undoing;
  - skipped elements, which never started, get no job;
  - an element still in flight, or whose state expired, is reported as a rollback failure once per
    element index, never skipped silently.
- **FR-008**: Element rollbacks MUST be dispatched newest-started element first (highest index
  first for an inline map; start order approximates index order for a fan-out map). Completion
  order across elements is not guaranteed; within one element, steps MUST be undone in reverse
  order.
- **FR-009**: While a distributed map rollback is in progress the run MUST NOT be reported as
  finished, and MUST NOT be cancellable. Its status and the dashboard MUST show that rollback is in
  progress, with element rollback counts:
  - total started;
  - settled (reported);
  - outstanding (total minus settled);
  - failed.

  The dashboard shows these counts only while the run is `rolling_back`.
- **FR-010**: A stalled map rollback (lost jobs) MUST be recoverable by the same recovery sweep that
  recovers stalled forward fan-out.
- **FR-011**: Map rollback MUST emit structured log entries for rollback start, each element
  rollback outcome and rollback completion, carrying reactor name, map step name and element index.

#### Inline map rollback

- **FR-012**: An inline map MUST keep rolling back in the executing process (it ran there), reading
  element states in bounded chunks rather than all at once. Coverage, ordering and failure reporting
  are the same as for fan-out rollback.

#### Fan-out map inside a composed child

- **FR-013**: A top-level run whose composed child (at any depth) hands off at a fan-out map MUST be
  resumed when the map settles, and MUST run to its final state, with or without an interrupt after
  the map.
- **FR-014**: A map settling inside a composed child MUST NOT resume the child as a standalone run;
  only the top-level run resumes, and only the execution that owns the top-level run writes its
  state (single-writer rule).
- **FR-015**: On re-entry after the map settled, the map MUST adopt the settled outcome (results or
  failure) and MUST NOT dispatch its elements again.
- **FR-016**: A failure of that map, or of any later step in the child or the root, MUST roll back
  through the top-level run: the map's completed elements (per FR-001–FR-008), the child's earlier
  steps, then the root's earlier steps.

#### Default fan-out batch size

- **FR-017**: A fan-out map without a declared batch size MUST use a default batch size of 50. A
  declared batch size MUST override it, with today's validation (a positive integer).
- **FR-018**: The effective batch size (declared or default) MUST govern both forward element
  dispatch and element rollback dispatch, with one back-pressure rule: no throw enqueues more than
  the effective batch size, and the next throw fires when the previous throw's last position has
  reported.
- **FR-019**: A fan-out map with no more elements than its effective batch size MUST dispatch all of
  them at once, as today.

#### Failure policy rename

- **FR-020**: The map DSL MUST offer `atomic`, on by default, with exactly the semantics of
  today's `fail_fast`:
  - on: any element failure fails the map, no new element starts after it, and every completed
    element is rolled back;
  - off: the map completes with every element's outcome; failed elements roll back themselves and
    succeeded ones are kept.
- **FR-021**: `fail_fast` MUST keep working as a deprecated alias of `atomic`, emitting one
  deprecation warning per declaration, at class definition, naming the replacement.
- **FR-022**: Declaring both `fail_fast` and `atomic` on one map MUST raise a definition error.
- **FR-023**: Work enqueued before an upgrade that carries the old setting MUST keep the policy it
  was enqueued with.
- **FR-024**: Documentation, dashboard labels, error messages and log fields MUST use the new name.

#### Delivery

- **FR-025**: README and the affected documentation pages (data pipelines, background and async,
  composition, core concepts) MUST describe distributed rollback, the default batch size and
  `atomic`; CHANGELOG MUST record the default-batch-size behavior change, the deprecation, and
  the composed-child fix.
- **FR-026**: The demo app MUST include an example reactor, rake task and spec exercising a fan-out
  map's distributed rollback with back pressure and a fan-out map inside a composed child, per
  Constitution Principle VI.

#### Single rollback per run

- **FR-027**: A run's rollback MUST NOT be started twice:
  - a manual undo of a run that is `rolling_back` is rejected;
  - cancelling a run that is `rolling_back` is rejected;
  - a map whose rollback already exists never dispatches its element rollbacks again.

### Key Entities

- **Effective batch size**: the declared batch size of a fan-out map, or 50 when none is declared.
  Caps how many element jobs one throw enqueues, forward and rollback.
- **Element rollback job**: one unit of background work for one started element. If the element
  completed, the job replays its undo stack. Outcome per element: undone, rollback failed (with its
  failures), not needed (nothing to undo), in flight, unavailable.
- **Map rollback**: the tracked rollback of one map in one run: which completed elements remain,
  which are outstanding, which reported and with what failures. When every element has reported,
  the run's rollback continues with the steps before the map.
- **Failure policy** (`atomic`): whether a map requires every element to succeed (on) or
  returns per-element outcomes (off).
- **Top-level run**: the outermost execution that owns the run state; composed children and their
  maps report to it and never resume on their own.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Rolling back a fan-out map of 10,000 completed elements never enqueues more than its
  effective batch size of element rollbacks in one throw. No job loads more than one element's
  state, and the coordinating execution's memory does not grow with the element count.
- **SC-002**: With 10 workers available, rolling back 10,000 completed elements finishes at least 5×
  faster than a serial, in-process rollback of the same elements. That baseline is today's algorithm:
  the inline-map rollback path, which reads in chunks but undoes elements one by one.
- **SC-003**: In fault-injection runs (duplicate deliveries, a worker killed mid-rollback), 100% of
  completed elements are rolled back, and no step whose undo was recorded is undone again.
- **SC-004**: A fan-out map of 1,000 elements with no declared batch size never enqueues more than
  50 element jobs in one throw, and collects all 1,000 outcomes.
- **SC-005**: A root composing a child with a fan-out map reaches its final state in 100% of runs:
  success, success with an interrupt after the map, and failure with rollback.
- **SC-006**: Every existing reactor declaring `fail_fast` keeps its behavior after upgrade with zero
  code changes, and shows one deprecation warning per declaration.

## Assumptions

- **Rollback mirrors execution mode.** Fan-out maps roll back distributed; inline maps roll back in
  process. A `batch_size` declared on an inline map still has no effect, as today.
- **50 is a library default, not a global setting.** The per-map `batch_size` is the override. A
  global configuration knob is out of scope until someone needs a different default everywhere.
- **Order across elements does not matter.** Elements run independently and in parallel forward,
  so their rollbacks may complete in any order. Dispatch is newest-started first (FR-008); within
  an element, reverse step order is kept.
- **Deprecate, don't remove.** `fail_fast` stays as an alias with a warning, so this ships as a
  MINOR release. Removal is a later MAJOR decision.
- **The default batch size changes throughput, not results.** Maps above 50 elements without a
  declared batch size become back-pressured; this is a behavior change noted in the CHANGELOG, not
  an API break.
- **Element rollback failure rules stay as today.** An element's undo that raises is reported as a
  rollback failure for that element, following the same rules as today's inline element rollback;
  this feature adds no new retry policy for undo.
- **Out of scope**: the map-level `undo_all` override and fenced context writes from
  `specs/future_improvements.md`; the other 008 rollback follow-ups.
- **Depends on** 008 rollback reliability: element indexing, rollback-failure attribution, the
  settle-before-apply rule for atomic failures, and the map recovery sweep.
