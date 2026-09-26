# Feature Specification: Reliable Rollback Across Constructs

**Feature Branch**: `execution_flow_analysis`

**Created**: 2026-09-26

**Status**: Draft

**Input**: User description: "In this investigation specs/007-execution-flow-analysis/analysis/findings-and-options.md
we found issues that we should fix and make the flows predictable and reliable. This round is to at
least fix the High issues. We should consider if some refactor is needed. For example: Now that we
moved more features into the Step we could consider the step holding more logic and functionality
for its own processing and execution and lean the reactor coordination simpler delegating more
logic to the step. This is only a suggestion and maybe that not the solution, but it's worth
exploring."

## Context

The 007 analysis ([findings-and-options.md](../007-execution-flow-analysis/analysis/findings-and-options.md))
found four **High** findings. Each one leaves completed side effects in place without saying so, or
treats rolled-back work as done:

| Finding | Gap | Invariants |
| --- | --- | --- |
| F-01 | Map elements that succeeded are never rolled back, whether the map fails or a later step fails | INV-19, INV-20 |
| F-02 | A retried composed reactor resumes a child whose earlier steps were already undone | INV-13 |
| F-03 | Some failures (argument preparation errors, non-standard exceptions) skip rollback entirely | INV-06 |
| F-04 | An async step's own `compensate`/`undo` are accepted by the DSL but never run | INV-24 |

This feature closes those four. It also closes the Medium/Low findings that the same rules fix:
F-05 (fan-out leftovers depend on scheduling), which has to be solved for F-01 to hold in fan-out
mode; F-06 (a raising condition compensates a step that never started) and F-13 (failures without
step attribution), which follow the same never-started and attribution rules as F-03.

**Readers**: reactor authors, who need to predict what gets rolled back, and RubyReactor
maintainers, who need to change rollback behavior safely.

## Clarifications

### Session 2026-09-26

- Q: How should a map roll back the elements that succeeded? → A: Automatic replay of each
  succeeded element's own step `undo`s, the same as compose. No new map DSL (FR-006).
- Q: When should an `async_step`'s own `compensate` run? → A: Unit-local: once, in the unit's own
  job, when its body finally fails. `undo` on an `async_step` is rejected at definition time
  (FR-019, FR-020). Refined in planning: an `undo` inherited from a step class is warned, not
  rejected (research R-09).

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Succeeded map elements are rolled back (Priority: P1)

A reactor author uses a map to charge a list of orders. If the map fails partway through, or a later
step fails after the map completed, every order that was charged is refunded. This is the same
behavior a composed reactor's completed steps already get.

**Why this priority**: F-01 is the widest gap. Map is the main batch construct, the README promises
automatic rollback for it, and no test covers the case today.

**Independent Test**: Run a reactor `a → map(4 elements) → b` whose element steps record `run` and
`undo`. Check the recorded sequence (a) when element 2 fails and (b) when `b` fails. Do this in
inline mode and in fan-out mode.

**Acceptance Scenarios**:

1. **Given** an inline fail-fast map where elements 0 and 1 succeed and element 2 fails, **When**
   the map fails, **Then** element 2 rolls itself back, then elements 1 and 0 are rolled back, then
   the steps before the map are undone. The failure names the map step and the failing element.
2. **Given** a map that completed, **When** a later step fails, **Then** every succeeded element is
   rolled back at the map's position in the parent's reverse-completion order, before earlier steps
   are undone.
3. **Given** a fan-out fail-fast map where other elements are still running or already finished
   when element 2 fails, **When** the map fails, **Then** every element that succeeded is rolled back,
   including elements that finish after the failure was detected. The set of rolled-back elements
   is the set of succeeded elements, whatever order the jobs ran in.
4. **Given** a map with `fail_fast false` that has both successes and failures, **When** a later step
   fails, **Then** the successful elements are rolled back and the failed elements (already
   self-rolled-back) are not rolled back again.
5. **Given** one element whose rollback fails, **When** the map rolls back, **Then** the other
   elements still roll back, and the final failure's rollback failures list that element's failure
   with the map step and element position.
6. **Given** nesting (a map inside a composed reactor, or a composed reactor inside a map element),
   **When** rollback runs, **Then** it unwinds innermost-first, as composed reactors already do.
7. **Given** an execution containing a completed map, **When** it is undone manually, **Then** the
   map's succeeded elements are rolled back too.
8. **Given** an existing map whose element steps already declare `undo`, **When** a later step
   fails, **Then** those `undo` blocks now run for every succeeded element. No map-level declaration
   is needed.

---

### User Story 2 - A retried composed reactor re-runs rolled-back work (Priority: P1)

A reactor author puts `retries` on a composed reactor to retry the whole sub-workflow after a
transient failure. When an attempt fails, the child rolls back. The next attempt must run the child
again from the start, not skip steps whose effects were already undone.

**Why this priority**: F-02 today returns a success built on a result that was already undone. A
later failure then undoes only part of the child. It is silent data corruption.

**Independent Test**: Run a composed child `c1 → c2`, where `c2` fails on the first attempt only,
with `retries` set to 2. Check that `c1` runs twice, that the result comes from the second attempt,
and that a later parent failure undoes both `c1` and `c2`.

**Acceptance Scenarios**:

1. **Given** a composed child `c1 → c2` with retries, where `c2` fails once, **When** the compose is
   retried, **Then** `c1` and `c2` both run again, and the compose result reflects only the final
   attempt.
2. **Given** the same reactor, where a later parent step then fails, **When** rollback runs, **Then**
   both `c2` and `c1` from the final attempt are undone.
3. **Given** a child that is parked mid-attempt (contention wait or background hand-off) and later
   resumed, **When** it resumes, **Then** the steps it completed before the park are **not** run
   again. A resume is not a retry.
4. **Given** any execution that resumes or retries after a rollback, **When** it continues, **Then**
   no rolled-back step is treated as completed.

---

### User Story 3 - Every failure after completed work rolls back (Priority: P1)

A reactor author writes an argument transform, a dynamic argument source or a result path that
raises. Step `a` has already completed. The author expects `a` to be undone and the failure to
name the step whose arguments failed. Today nothing is rolled back and the failure has no step name.

**Why this priority**: F-03 breaks the README's core promise ("automatically triggers compensation")
for a common coding mistake, and gives the reader nothing to trace.

**Independent Test**: Run `a → b`, where `b`'s argument transform raises. Check that `a` is undone,
`b` is not compensated, and the failure carries the step name `b` and the reason.

**Acceptance Scenarios**:

1. **Given** `a` completed and `b`'s argument transform, dynamic source or result path raises,
   **When** the execution fails, **Then** `a` is undone, `b` is not compensated (its body never
   started), and the failure names reactor, step `b` and the reason.
2. **Given** a `where`/`guard` condition on `b` that raises, **When** the execution fails, **Then**
   `b` is not compensated and `a` is undone.
3. **Given** argument preparation that happens in a worker (an async step unit, or the first step
   after a `background before:` hand-off), **When** it raises, **Then** the same rule applies in
   that process.
4. **Given** any other unexpected error during an execution after at least one step completed,
   **When** it happens, **Then** the completed steps are rolled back and the failure reports any
   rollback that did not complete.
5. **Given** an inline execution interrupted by a process-level exception (not a standard error:
   a signal, out of memory, a custom `Exception` subclass), **When** it propagates, **Then** no
   rollback code runs in that process and the exception reaches the caller unchanged. The
   execution is recorded as **aborted** with completed work outstanding, and the existing manual
   undo rolls it back. Worker behavior (redelivery) is unchanged.
6. **Given** a failing step whose own compensation also fails, **When** the failure is returned,
   **Then** it still carries the reactor and step name.

---

### User Story 4 - An async step's rollback hooks run as declared (Priority: P2)

A reactor author declares `compensate`/`undo` on an `async_step`, as the documentation says works.
Today those blocks never run. They are accepted and silently ignored.

**Why this priority**: fewer reactors use `async_step` rollback hooks than maps or composes, but a
DSL that accepts dead code and documentation that promises it runs are both traps.

**Independent Test**: Run an `async_step` unit whose body always fails and that declares
`compensate`. Drain its job and check that `compensate` ran once, after the last attempt.
Separately, declare `undo` on an `async_step` and check that the class definition is rejected.

**Acceptance Scenarios**:

1. **Given** an `async_step` whose body finally fails (after its retries) and which declares
   `compensate`, **When** the unit fails, **Then** its `compensate` runs once, in the unit's own
   job, after the last attempt. It runs whether or not any step reads the result.
2. **Given** an `async_step` unit whose first attempt fails and whose retry succeeds, **When** it
   completes, **Then** `compensate` never runs.
3. **Given** a unit that compensated itself and a reader that then surfaces the unit's failure,
   **When** the parent rolls back, **Then** the reader is compensated and the parent's completed
   steps are undone, and the unit is **not** compensated a second time.
4. **Given** an `async_step` that declares an inline `undo`, **When** the reactor class is defined,
   **Then** the declaration is rejected with a message explaining why and where to put the cleanup
   instead. If the `undo` comes from the step class, a warning is emitted instead.
5. **Given** the documentation for async steps, **When** a reader follows it, **Then** it matches
   the behavior.

---

### User Story 5 - One rollback rule for every construct (Priority: P3)

A reactor author reads a reactor class and predicts what a failure will roll back from one rule:
*completed work is undone, work that started and failed is compensated, work that never started is
left alone*. Each construct (step, composed reactor, map, async step, async reactor) says what
"undo" and "compensate" mean for itself. A maintainer who changes one construct's rollback changes
it in that construct.

**Why this priority**: this is the structural goal behind the first four stories (the user's "step
owns its own lifecycle" direction). It pays off only once they land, and it is judged by review
more than by any single test.

**Independent Test**: Rebuild the F-10 rollback coverage table from the new behavior. Compose and
map rows read the same. Async rows differ only by the documented independence of async units.

**Acceptance Scenarios**:

1. **Given** the F-10 coverage table, **When** it is rebuilt after this feature, **Then** no cell
   reads "left in place" for compose or map, and the async rows match the documentation.
2. **Given** the coordinator that runs a reactor, **When** a maintainer reviews it, **Then** it
   applies the one rule above to every construct. No construct kind is excluded from rollback by a
   special case in the coordinator. The construct's own definition decides what its rollback does.

---

### Edge Cases

- **Map with zero elements**: nothing to roll back. The map rollback is a no-op, not an error.
- **Every element fails (fail-fast)**: only the first failing element rolled back its own steps.
  There are no succeeded elements to roll back.
- **Collect step raises after all elements succeeded**: the map fails, and every succeeded element is
  rolled back.
- **Large map (10,000 elements)**: rollback must stay possible without the parent's stored state
  growing past existing storage limits.
- **Element rollback under step locks**: element steps re-take their own locks for undo, the same as
  any step undo today (including the `rollback_wait` skip-and-report behavior).
- **Element that returned `Halt`**: `Halt` semantics are unchanged. No rollback (F-07 is out of
  scope).
- **Fan-out failure latency**: a fail-fast fan-out map reports failure only after the elements in
  flight have finished and been rolled back. The latency grows to the slowest element in flight.
  This is documented.
- **Compose retry with child steps that declare no `undo`**: their effect happens again on the
  retry. That is what retry means, and it is documented.
- **An earlier attempt's rollback was incomplete, then the retry succeeded**: the incomplete rollback
  stays visible in the execution's recorded trace and events. A successful final attempt does not
  erase it.
- **Awaited async result times out during argument preparation**: this already rolls back. It stays
  unchanged.
- **Process-level exception in a worker**: the job is redelivered and resumes from its last
  checkpoint. Unchanged.

## Requirements *(mandatory)*

### Functional Requirements

#### Map rollback (F-01, F-05)

- **FR-001**: When a map step fails, every element of that map that had succeeded MUST be rolled
  back before the parent continues its own rollback.
- **FR-002**: When a step after a completed map fails, or the execution is undone manually, every
  succeeded element of that map MUST be rolled back at the map step's position in reverse-completion
  order.
- **FR-003**: Map rollback MUST produce the same set of rolled-back elements in inline and fan-out
  modes. In fan-out mode it MUST include elements that were in flight when the failure was detected,
  so that no succeeded element escapes rollback because of job scheduling.
- **FR-004**: An element that failed and already rolled itself back MUST NOT be rolled back again.
- **FR-005**: A rollback failure for one element MUST NOT stop rollback of the others. It MUST appear
  in the final failure's rollback failures, attributed to the map step and the element position.
- **FR-006**: A succeeded element MUST be rolled back by replaying that element's own completed
  steps' `undo`, in reverse completion order, exactly as a completed composed reactor is rolled back
  today. The map adds no new rollback DSL; the `undo` blocks authors already write on element steps
  become the element's rollback.
- **FR-007**: A map whose collection step fails after its elements ran MUST be treated as a failed
  map. FR-001 applies to its succeeded elements.
- **FR-008**: Making maps rollback-capable MUST NOT make the parent execution's stored state grow per
  element in a way that breaks maps that run today within storage limits.

#### Retried composed reactor (F-02)

- **FR-009**: When a composed reactor is retried after a failed attempt, the retry MUST start the
  child from a state in which no step rolled back by that attempt counts as completed. Those steps
  run again.
- **FR-010**: The compose result, and any later undo of the compose, MUST reflect only the steps
  completed in the final attempt.
- **FR-011**: A resume that is not a retry (redelivery after a park, a contention wait, a background
  hand-off) MUST keep resuming without re-running completed, not-rolled-back steps.
- **FR-012**: No execution MUST ever treat a rolled-back step as completed when it resumes or retries.

#### Failures that skip rollback (F-03, F-06, F-13)

- **FR-013**: A standard error raised while preparing a step's arguments (argument sources,
  transforms, result paths) MUST fail that step, MUST NOT compensate it, and MUST undo all completed
  steps.
- **FR-014**: A standard error raised by a step's `where`/`guard` condition MUST follow FR-013: the
  step is not compensated, and completed steps are undone.
- **FR-015**: FR-013 and FR-014 MUST also hold when argument preparation happens in a worker process
  (an async step unit, or a `background` hand-off).
- **FR-016**: Any other standard error raised during an execution after at least one step completed
  MUST roll back the completed steps. No standard-error path may end the execution without rollback.
- **FR-017**: Every failure produced under FR-013 to FR-016, and every failure whose compensation
  itself failed, MUST carry the reactor name, the step name (when a step was executing) and the
  reason, with rollback failures attached as for any other failure.
- **FR-018**: A process-level exception (not a standard error) MUST propagate to the caller
  unchanged and MUST NOT run rollback code in the same process. For an inline execution, the
  execution MUST be recorded as **aborted** (distinct from running and failed) while the process is
  still able to record it, and the existing manual undo MUST roll it back.

#### Async step rollback hooks (F-04)

- **FR-019**: An `async_step` unit's own `compensate` MUST run in the unit's own job, exactly once,
  when its body finally fails (after its last retry), whether or not any step reads the unit's
  result. This mirrors how an `async_reactor` child rolls itself back. A failed attempt that is then
  retried MUST NOT compensate.
- **FR-020**: An inline `undo` block declared on an `async_step` MUST be rejected when the reactor
  class is defined, because nothing ever undoes an independent unit that succeeded. The message
  MUST say where that cleanup belongs (the reading step's `compensate`, or an `async_reactor` child
  whose steps declare `undo`). A step class that defines `undo` and is used with `async_step` MUST
  produce a definition-time warning saying that `undo` will not run for this use. It is not an
  error, because the same class is legitimately reused by ordinary steps (research R-09).
- **FR-021**: The outcome of an async unit's rollback, including any rollback failure, MUST be
  recorded on the unit's own execution record and emitted through the existing observability events.

#### One rollback rule (F-10)

- **FR-022**: Each construct kind (step, composed reactor, map, async step, async reactor) MUST
  define what its own compensate and undo do. The coordinator MUST apply one rule to all of them:
  completed work is recorded for undo, work that started and failed is compensated, work that never
  started is not compensated.
- **FR-023**: The documented independence of async units from their parent's rollback MUST be
  expressed by the async constructs' own undo definitions, not by a coordinator special case.

#### Documentation, demo and tests

- **FR-024**: Every README.md and `./documentation` claim listed in the 007 documentation audit for
  an in-scope finding MUST be corrected in the same change as its fix.
- **FR-025**: Each user-visible behavior change MUST ship with a demo reactor, a listed demo rake
  task and a demo spec written with the shipped matchers (Constitution VI): map rollback, compose
  retry, argument-failure rollback, and async step hooks.
- **FR-026**: CHANGELOG.md MUST record each behavior change under the correct heading. Breaking
  changes MUST include a migration note.
- **FR-027**: Each invariant this feature makes hold MUST be covered by at least one automated test
  against real infrastructure that fails on the pre-change behavior. The existing async step test
  that passes whether or not the unit's hooks run MUST be tightened.

### Key Entities

- **Construct**: a unit of work in a reactor: a step, composed reactor, map, async step or async
  reactor. Each defines its own forward run, compensate and undo.
- **Undo record**: what an execution keeps about a completed construct so it can undo it later
  (construct, its arguments, its result). For a map this includes whatever is needed to roll back
  each succeeded element.
- **Element outcome**: per map element: succeeded, failed (self-rolled-back), skipped (never
  started), or in flight. Rollback coverage is decided from this.
- **Attempt**: one try of a retried construct. Only the final attempt's completed work is owned by
  the parent afterwards.
- **Rollback failure**: a compensate or undo that did not complete, attributed to its construct
  (and element position for maps), reported on the final failure.
- **Aborted execution**: an inline execution cut short by a process-level exception. Its completed
  work is still outstanding, and it can be found and undone manually.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: The invariants tied to in-scope findings change status to HOLDS: INV-06, INV-13,
  INV-19, INV-20 and INV-24 (VIOLATED today), and INV-07 and INV-22 (CONDITIONAL today; for INV-22
  the "left in place" clause, since which fan-out elements run stays scheduling-dependent). Each is
  covered by at least one automated test that fails on the 0.8.3 baseline.
- **SC-002**: When the 63 scenarios of the 007 evidence set are re-run, every scenario tied to an
  in-scope finding produces its corrected sequence. Every other scenario produces the same sequence
  as the baseline (0 unintended changes).
- **SC-003**: Across 100 runs of a fail-fast fan-out map with randomized job order, 0 runs leave a
  succeeded element without rollback.
- **SC-004**: In the 007 failure-kinds table, every failure after completed work either rolls
  completed work back or, for process-level exceptions only, leaves an execution recorded as aborted
  that manual undo rolls back. 0 rows end with nothing rolled back and nothing reported.
- **SC-005**: 100% of failures produced on in-scope paths carry reactor name, step name (where a step
  was executing) and reason.
- **SC-006**: A 10,000-element map can fail and roll back all its succeeded elements without a
  storage size error.
- **SC-007**: Every row of the 007 documentation audit tied to an in-scope finding reads CONFIRMED
  against the new behavior.
- **SC-008**: The rebuilt F-10 coverage table has no "left in place" cell for compose or map.
- **SC-009**: The full test suite, the style checks and the demo acceptance tasks pass.

## Assumptions

- **Scope**: the four High findings, plus F-05, F-06 and F-13, which the same rules fix. Out of
  scope: F-07 (nested `Halt`), F-08 (manual undo outside the reactor lock), F-09 (async units running
  after their dispatcher rolled back), F-11, F-12, F-14, F-15 and F-16. They stay as documented in
  the 007 analysis.
- **Refactor direction**: planning evaluates the "each step owns its own lifecycle" direction and
  adopts it where it makes these fixes simpler and removes construct-kind special cases from the
  coordinator (FR-022, FR-023). Moving more (retries, coordination, argument preparation) into steps
  is adopted only if it reduces the complexity of these fixes (Constitution V, YAGNI). The decision
  and its alternatives are recorded in the planning research.
- **Async independence stays**: a parent's rollback still does not cancel or undo async units
  (INV-25, documented). FR-023 changes only where that rule lives.
- **Retry semantics**: retrying a composed reactor re-runs child steps that have no `undo`, so their
  effect happens again. This is accepted and documented.
- **Fan-out failure latency**: waiting for elements in flight is accepted in exchange for
  predictable rollback.
- **Process-level exceptions**: running user rollback code while the process is being signalled or
  is out of memory is unsafe, so FR-018 records the execution for later undo instead.
- **Baseline**: commit `faf90e8d` (0.8.3 + #61, #63). The 007 evidence harness is reused as the
  regression check for SC-002.
- **Versioning**: behavior changes follow Constitution V. Two are knowingly breaking and need
  migration notes: element-step `undo` blocks now run when a map is rolled back (FR-006), and
  `undo` on an `async_step` is now rejected (FR-020). An `async_step`'s `compensate` that never ran
  before now runs (FR-019). Planning decides the SemVer level of each change.
