# Feature Specification: Reliable Rollback Across Constructs

**Feature Branch**: `execution_flow_analysis`

**Created**: 2026-09-26

**Status**: Draft, revised 2026-09-27 after the PR #65 review

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
mode; F-06 (a raising condition compensates a step that never started), closed by removing
`where`/`guard`; and F-13 (failures without step attribution), which follows the same attribution
rule as F-03.

**Revision after the PR #65 review (2026-09-27)**. Four points in the first implementation were
wrong and are corrected here:

| Review point | Before | Now |
| --- | --- | --- |
| A nested reactor must never be retried as a whole by its parent | `retries` on a `compose` started a fresh child per attempt | `retries` on a `compose` or an `async_reactor` is rejected. The child's own steps declare their retries. This closes F-02 by removing the path (007 option O-02-c) |
| `where`/`guard` are an old implementation that may be stale | kept, with raising conditions made "never started" | removed from the DSL. A step that should not run returns `Skipped` from its body. This closes F-06 by removing the path |
| All errors raised by reactor code must roll back | only standard errors rolled back. Every other exception marked the run aborted | every exception raised by reactor code rolls back. Only process-termination exceptions skip rollback |
| `Skipped` can mean "not required" or "already done" | a `Skipped` step was never undone, and it also suppressed an `after:` hand-off and a period mark | `Skipped` is only an instrumentation mark: in every effect it is a `Success`, rollback included (FR-029, FR-030) |

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

### Session 2026-09-27 (PR #65 review)

- Q: Should a `compose` keep `retries`, with a fresh child per attempt? → A: No. A composed reactor
  is never retried as a whole by its parent. The child knows how to retry its own steps. `retries`
  on a `compose` is rejected at definition time (FR-009, FR-010). This replaces the fresh-child
  decision (research R-05). The same rule applies to `async_reactor`, the other construct that runs
  a nested reactor.
- Q: Should `where`/`guard` stay? → A: No. Remove both completely. A step that decides it should
  not run returns `Skipped` from its body (FR-014).
- Q: Which exceptions skip rollback? → A: Only the ones that mean the process is ending: a signal
  (including an interrupt), a request to exit, and out of memory. Any other exception raised by
  reactor code (a `run`, `compensate` or `undo` body, an argument source or transform, a step
  definition) is a failure and rolls back, whether or not it is a standard error (FR-016, FR-018,
  FR-028).
- Q: Is a `Skipped` step undone? → A: *(first defaulted to "no"; superseded by the review answer
  below)*.
- Q (review 2026-09-27): What does `Skipped` change? → A: Nothing. `Skipped` is only an
  instrumentation mark, so an engineer reviewing the execution can see the step did not need to
  run. In every effect it is the same as `Success`: the run continues, a `background` hand-off
  happens as for a completed step, a period bucket is marked, and the step is enrolled for undo
  (FR-029, FR-030).
- Q (review 2026-09-27): Cap a stored failure's backtrace? → A: Yes (FR-031).
- Q (review 2026-09-27): What must happen when a resume arrives while the reactor is compensating?
  → A: The resume fails; a resume is accepted only by a reactor paused at an interrupt step
  (FR-032).

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

### User Story 2 - A nested reactor is never retried as a whole (Priority: P1)

A reactor author wants a sub-workflow to survive a transient failure. They declare `retries` on the
child's steps that can fail transiently. The child retries those steps itself. The parent never
re-runs the child as a whole: a child whose steps ran out of retries has failed, has rolled itself
back, and fails the parent. Declaring `retries` on the `compose` (or `async_reactor`) itself is
rejected, with a message that says where the retries belong.

**Why this priority**: F-02 today returns a success built on a result that was already undone. A
later failure then undoes only part of the child. It is silent data corruption. Retrying the whole
child from the parent is the path that causes it. The child already owns its steps' retry policies,
so the parent-level retry adds nothing but a second, conflicting retry layer.

**Independent Test**: Define a reactor that declares `retries` on a `compose` and check that the
class definition is rejected. Separately, run a composed child `c1 → c2` where `c2` declares
`retries` and fails on its first attempt only. Check that `c1` runs once, `c2` runs twice, the
compose succeeds, and a later parent failure undoes `c2` then `c1` once each.

**Acceptance Scenarios**:

1. **Given** a reactor that declares `retries` on a `compose`, in either the class form or the
   inline block form, **When** the reactor class is defined, **Then** the definition is rejected
   with a message naming the compose step and saying that retries belong on the child's own steps.
2. **Given** a reactor that declares `retries` on an `async_reactor`, **When** the reactor class is
   defined, **Then** it is rejected the same way.
3. **Given** a composed child `c1 → c2` where `c2` declares `retries` and fails on its first attempt
   only, **When** the parent runs, **Then** `c1` runs once, `c2` is retried inside the child, and the
   compose result is the child's result.
4. **Given** the same reactor, where a later parent step then fails, **When** rollback runs,
   **Then** `c2` and then `c1` are each undone exactly once.
5. **Given** a composed child whose step fails after its own retries are exhausted, **When** the
   child fails, **Then** the child rolls back its completed steps, the compose fails, the parent's
   completed steps are undone, and the child is not run again.
6. **Given** a child that is parked mid-run (contention wait or background hand-off) and later
   resumed, **When** it resumes, **Then** the steps it completed before the park are **not** run
   again. A resume is not a retry.
7. **Given** any execution that resumes after a rollback, **When** it continues, **Then** no
   rolled-back step is treated as completed.

---

### User Story 3 - Every failure after completed work rolls back (Priority: P1)

A reactor author writes an argument transform, a dynamic argument source or a result path that
raises. Or a step body raises an exception that is not a standard error: a step class that does not
implement `run`, a runaway recursion, a custom exception class. Step `a` has already completed. The
author expects `a` to be undone and the failure to name the step that failed. Today nothing is
rolled back, and the failure has no step name or is not returned at all.

**Why this priority**: F-03 breaks the README's core promise ("automatically triggers compensation")
for common coding mistakes, and gives the reader nothing to trace.

**Independent Test**: Run `a → b`, where `b`'s argument transform raises. Check that `a` is undone,
`b` is not compensated, and the failure carries the step name `b` and the reason. Repeat with `b`'s
body raising a not-implemented error and a custom exception that is not a standard error: `a` is
undone, `b` is compensated, and the failure names `b`.

**Acceptance Scenarios**:

1. **Given** `a` completed and `b`'s argument transform, dynamic source or result path raises,
   **When** the execution fails, **Then** `a` is undone, `b` is not compensated (its body never
   started), and the failure names reactor, step `b` and the reason.
2. **Given** `a` completed and `b`'s body raises an exception that is not a standard error and is
   not a process-termination exception (for example a not-implemented error, a stack overflow, or a
   custom exception class), **When** the execution fails, **Then** `b` is compensated, `a` is
   undone, and the failure is returned to the caller naming reactor, step `b` and the original
   exception class.
3. **Given** argument preparation that happens in a worker (an async step unit, or the first step
   after a `background before:` hand-off), **When** it raises, **Then** the same rule applies in
   that process.
4. **Given** any other unexpected exception during an execution after at least one step completed,
   **When** it happens, **Then** the completed steps are rolled back and the failure reports any
   rollback that did not complete.
5. **Given** an inline execution interrupted by a process-termination exception (a signal including
   an interrupt, a request to exit, or out of memory), **When** it propagates, **Then** no rollback
   code runs in that process and the exception reaches the caller unchanged. The execution is
   recorded as **aborted** with completed work outstanding, and the existing manual undo rolls it
   back. Worker behavior (redelivery) is unchanged.
6. **Given** a rollback in progress, **When** a `compensate` or `undo` raises an exception that is
   not a process-termination exception, **Then** it is recorded as a rollback failure for that
   step and the remaining rollback continues.
7. **Given** a failing step whose own compensation also fails, **When** the failure is returned,
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

### User Story 6 - One way to skip a step (Priority: P2)

A reactor author wants a step to do nothing under some condition. There is one way to say it: the
step's body returns `Skipped`. The older `where`/`guard` declarations, which decided before the
step started and followed their own failure rules, no longer exist. A reactor that still declares
them is rejected when it is defined, with a message that shows the replacement.

**Why this priority**: `where`/`guard` is an old, barely documented path with its own failure
behavior (F-06). It duplicates `Skipped`, and every rollback rule has to account for it. Removing it
removes a whole failure category instead of classifying it.

**Independent Test**: Define a step that declares `where`, and another that declares `guard`. Check
that each class definition is rejected with a message pointing to `Skipped`. Rewrite the same step
to return `Skipped` from its body and check that the reactor continues past it.

**Acceptance Scenarios**:

1. **Given** a step, async step or interrupt that declares `where` or `guard`, **When** the reactor
   class is defined, **Then** the definition is rejected with a message naming the step and saying
   to return `Skipped` from the step body instead.
2. **Given** a step whose body returns `Skipped`, **When** the reactor runs, **Then** everything
   happens exactly as for `Success` (value, hand-off, period mark, undo on a later failure), and
   only the execution trace records the skip.
3. **Given** the README and `./documentation`, **When** a reader looks for `where`, `guard` or the
   condition error, **Then** the only mentions are in the migration note.

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
- **Existing reactor that declares `retries` on a `compose` or `async_reactor`**: it now fails when
  its class is loaded, with the migration message. It does not silently run with one attempt.
- **Compose inline block that declares `retries` meaning "for the steps inside"**: rejected like any
  compose-level `retries`. The message says to declare `retries` inside each child step.
- **Existing reactor that declares `where`/`guard`**: fails when its class is loaded, with the
  migration message.
- **A `background before:` hand-off at a step that used a `where` condition**: the condition kept
  the hand-off from happening. After migration the step's body returns `Skipped`, so the hand-off
  happens at that step. This is documented in the migration note.
- **A step class that does not implement `run`**: its not-implemented error is a failure of that
  step. Completed steps are undone.
- **A process-termination exception during a rollback that is already running**: the rollback
  stops. The execution is recorded as aborted with the steps not yet undone still outstanding, and
  manual undo finishes the rollback.
- **Awaited async result times out during argument preparation**: this already rolls back. It stays
  unchanged.
- **Process-termination exception in a worker**: the job is redelivered and resumes from its last
  checkpoint. Unchanged.
- **A step that returns `Skipped`, then a later step fails**: its `undo` runs with the skipped
  value, as for any `Success` (FR-029). The library's own skips (`with_period`, `with_ordered_lock`)
  are `Skipped` too, so their `undo` runs with a nil value.
- **`background after: :x` where `:x` returns `Halt`**: the run halts; nothing is handed off.

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

#### Nested reactors are never retried as a whole (F-02)

- **FR-009** *(revised 2026-09-27)*: Declaring `retries` on a `compose` or an `async_reactor` MUST be
  rejected when the reactor class is defined, in both the class form and the inline block form. The
  message MUST name the step and say that retries belong on the child reactor's own steps.
- **FR-010** *(revised 2026-09-27)*: A parent MUST NOT run a failed nested child again. The only
  retries inside a child are its own steps' retries. The compose result, and any later undo of the
  compose, reflect the child's single run.
- **FR-011**: A resume that is not a retry (redelivery after a park, a contention wait, a background
  hand-off) MUST keep resuming without re-running completed, not-rolled-back steps.
- **FR-012**: No execution MUST ever treat a rolled-back step as completed when it resumes.

#### Failures that skip rollback (F-03, F-06, F-13)

- **FR-013**: An exception raised while preparing a step's arguments (argument sources, transforms,
  result paths) MUST fail that step, MUST NOT compensate it, and MUST undo all completed steps.
  This covers every exception except the process-termination ones (FR-018).
- **FR-014** *(revised 2026-09-27)*: The `where` and `guard` step declarations MUST be removed.
  Declaring either on a step, async step or interrupt MUST be rejected when the reactor class is
  defined, with a message naming the step and saying to return `Skipped` from the step body instead.
  With them goes the failure category they created (F-06): a condition that raises.
- **FR-015**: FR-013 MUST also hold when argument preparation happens in a worker process (an async
  step unit, or a `background` hand-off).
- **FR-016** *(revised 2026-09-27)*: Any exception raised during an execution after at least one step
  completed MUST roll back the completed steps, unless it is a process-termination exception
  (FR-018). This includes exceptions that are not standard errors, for example a not-implemented
  error, a load or syntax error from lazily loaded code, a stack overflow, or a custom exception
  class. A step body that raises one of these MUST be compensated, like any step body failure.
- **FR-017**: Every failure produced under FR-013 and FR-016, and every failure whose compensation
  itself failed, MUST carry the reactor name, the step name (when a step was executing), the reason
  and the original exception class, with rollback failures attached as for any other failure.
- **FR-018** *(revised 2026-09-27)*: A process-termination exception MUST propagate to the caller
  unchanged and MUST NOT run rollback code in the same process. Process-termination exceptions are
  exactly: a signal (including an interrupt), a request to exit the process, out of memory, and the
  interruption an enclosing timeout raises into the running code (it is not raised by reactor code,
  and swallowing it would stop the caller's timeout from firing; research R-16). For
  an inline execution, the execution MUST be recorded as **aborted** (distinct from running and
  failed) while the process is still able to record it, and the existing manual undo MUST roll it
  back.

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
  an in-scope finding MUST be corrected in the same change as its fix. The documentation MUST NOT
  describe `retries` on a `compose`/`async_reactor`, `where`, `guard` or the condition error outside
  the migration notes, and MUST describe the aborted status as the result of a process-termination
  exception only.
- **FR-025**: Each user-visible behavior change MUST ship with a demo reactor, a listed demo rake
  task and a demo spec written with the shipped matchers (Constitution VI): map rollback, a compose
  whose child step retries on its own (replacing the compose retry demo), failure rollback for
  argument errors and for an exception that is not a standard error, async step hooks, and a step
  that skips itself by returning `Skipped` (replacing any `where`/`guard` example).
- **FR-026**: CHANGELOG.md MUST record each behavior change under the correct heading. Breaking
  changes MUST include a migration note. The removal of `retries` on `compose`/`async_reactor` and
  of `where`/`guard` are breaking, and each migration note MUST show the replacement.
- **FR-027**: Each invariant this feature makes hold MUST be covered by at least one automated test
  against real infrastructure that fails on the pre-change behavior. The existing async step test
  that passes whether or not the unit's hooks run MUST be tightened.

#### Rollback code and skipped steps (review 2026-09-27)

- **FR-028**: A `compensate` or `undo` that raises any exception other than a process-termination
  exception MUST be recorded as a rollback failure for its step, and the remaining rollback MUST
  continue.
- **FR-029** *(revised 2026-09-27)*: `Skipped` MUST have every effect `Success` has. It is only an
  instrumentation mark (execution trace, `skipped?`, telemetry). A `Skipped` step MUST be enrolled
  for undo, and a later failure MUST run its `undo` with the skipped value.
- **FR-030**: A `background after: :x` hand-off MUST fire when `:x` returns `Skipped`, and MUST NOT
  fire when `:x` returns `Halt`. A `with_period` step whose body returns `Skipped` MUST mark its
  bucket.
- **FR-031**: A stored failure MUST keep at most 100 backtrace frames, so a stack overflow does not
  inflate the stored context.
- **FR-032**: A resume (`continue`) MUST be accepted only while the execution is paused at an
  interrupt step. A resume that arrives while the execution is running or rolling back MUST fail
  without changing it.

### Key Entities

- **Construct**: a unit of work in a reactor: a step, composed reactor, map, async step or async
  reactor. Each defines its own forward run, compensate and undo.
- **Undo record**: what an execution keeps about a completed construct so it can undo it later
  (construct, its arguments, its result). For a map this includes whatever is needed to roll back
  each succeeded element.
- **Element outcome**: per map element: succeeded, failed (self-rolled-back), skipped (never
  started), or in flight. Rollback coverage is decided from this.
- **Attempt**: one try of a retried step. Only steps declare retries. A nested reactor (compose,
  async reactor) has exactly one run per parent step.
- **Rollback failure**: a compensate or undo that did not complete, attributed to its construct
  (and element position for maps), reported on the final failure.
- **Process-termination exception**: a signal (including an interrupt), a request to exit the
  process, out of memory, or an enclosing timeout's interruption. The only exceptions that skip
  rollback.
- **Aborted execution**: an inline execution cut short by a process-termination exception. Its
  completed work is still outstanding, and it can be found and undone manually.
- **Skipped step**: a step whose body returned `Skipped`. A `Success` in every effect, undo
  included; only the trace marks it (FR-029).

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: The invariants tied to in-scope findings change status to HOLDS: INV-06, INV-13,
  INV-19, INV-20 and INV-24 (VIOLATED today), and INV-07 and INV-22 (CONDITIONAL today; for INV-22
  the "left in place" clause, since which fan-out elements run stays scheduling-dependent). Each is
  covered by at least one automated test that fails on the 0.8.3 baseline. After the review, INV-13
  holds because no nested reactor can be retried as a whole (its test is the definition-time
  rejection), INV-07 no longer lists `where`/`guard`, and INV-06 holds for every exception except
  process-termination ones.
- **SC-002**: When the 63 scenarios of the 007 evidence set are re-run, every scenario tied to an
  in-scope finding produces its corrected sequence. Every other scenario produces the same sequence
  as the baseline (0 unintended changes).
- **SC-003**: Across 100 runs of a fail-fast fan-out map with randomized job order, 0 runs leave a
  succeeded element without rollback.
- **SC-004**: In the 007 failure-kinds table, every failure after completed work either rolls
  completed work back or, for process-termination exceptions only, leaves an execution recorded as
  aborted that manual undo rolls back. 0 rows end with nothing rolled back and nothing reported.
- **SC-005**: 100% of failures produced on in-scope paths carry reactor name, step name (where a step
  was executing) and reason.
- **SC-006**: A 10,000-element map can fail and roll back all its succeeded elements without a
  storage size error.
- **SC-007**: Every row of the 007 documentation audit tied to an in-scope finding reads CONFIRMED
  against the new behavior.
- **SC-008**: The rebuilt F-10 coverage table has no "left in place" cell for compose or map.
- **SC-009**: The full test suite, the style checks and the demo acceptance tasks pass.
- **SC-010**: Each exception kind named in FR-016 (not-implemented, load or syntax error, stack
  overflow, custom exception class), raised from a step body and from an argument transform, rolls
  back completed work in an automated test. 0 of them leave the execution aborted.
- **SC-011**: 0 ways remain to retry a nested reactor as a whole or to declare `where`/`guard`: each
  one is rejected at definition time by an automated test, and the README and `./documentation`
  mention them only in migration notes.

## Assumptions

- **Scope**: the four High findings, plus F-05, F-06 and F-13, which the same rules fix. F-02 and
  F-06 are closed by removing the constructs that caused them (compose `retries`, `where`/`guard`),
  not by fixing their behavior. Out of
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
- **Retry ownership**: a child reactor owns the retries of its own steps. The parent never retries
  a nested reactor as a whole (review 2026-09-27). `async_reactor` follows the same rule as
  `compose`: its `retries` could only re-dispatch, or in inline mode re-run, the whole child.
- **`where`/`guard` removal**: they are removed, not deprecated, because they are an old path with
  their own failure rules and `Skipped` covers the use. Code that relied on a condition to prevent a
  `background` hand-off changes behavior and is called out in the migration note.
- **Fan-out failure latency**: waiting for elements in flight is accepted in exchange for
  predictable rollback.
- **Process-termination exceptions**: running user rollback code while the process is being
  signalled, is exiting or is out of memory is unsafe, so FR-018 records the execution for later
  undo instead. Every other exception comes from reactor code (a body, a transform, a definition)
  and is a failure of that code. Rolling it back is what the saga promises (review 2026-09-27).
- **Baseline**: commit `faf90e8d` (0.8.3 + #61, #63). The 007 evidence harness is reused as the
  regression check for SC-002.
- **Versioning**: behavior changes follow Constitution V. Two are knowingly breaking and need
  migration notes: element-step `undo` blocks now run when a map is rolled back (FR-006), and
  `undo` on an `async_step` is now rejected (FR-020). An `async_step`'s `compensate` that never ran
  before now runs (FR-019). The review adds three more breaking changes: `retries` on
  `compose`/`async_reactor` is rejected (FR-009), `where`/`guard` are removed (FR-014), and
  exceptions that are not standard errors now roll back instead of propagating (FR-016). Planning
  decides the SemVer level of each change.
- **Revision of existing work**: the first implementation of this feature is already on the branch.
  Planning updates the research decisions this revision reverses (R-05 fresh child per attempt,
  R-06 condition errors, R-08 aborted on every non-standard exception) and the tasks that
  implemented them.
