# Feature Specification: Rollback and Resume Follow-ups

**Feature Branch**: `rollback_follow_ups`

**Created**: 2026-10-08

**Status**: Draft, revised 2026-10-08 by /speckit-plan:

- **FR-010**: no snooze limit after admission (research R-07).
- **FR-017**: acceptance is keyed on the interrupt, not on why the run is `running` (R-04, R-05).
- **FR-024** and **US6-AS3**: how manual undo reports a failure (R-10).

**Input**: User description: "Rollback follow-ups (008), raised while implementing
specs/008-rollback-reliability; none blocks it. (1) The recovery sweep re-enqueues runs still
executing in the caller's process. (2) A map-level `undo_all { |completed_results| ... }` that
replaces the per-element undo replay. (3) A synchronous caller's final save races a worker resume
after a fan-out map hand-off. (4) A resume for a second pending interrupt while the first is
executing is rejected. (5) An interrupted `compensate` of the failing step is not re-run by manual
undo. (6) A resume contended on the reactor's lock or semaphore raises and is lost if the caller
does not retry. (7) Two resumes in the same instant both pass the `paused` check." Full text:
`specs/future_improvements.md`, §"Rollback follow-ups (008)".

## Context

What happens today, and what this feature changes:

| Area | Today | After this feature |
| --- | --- | --- |
| Recovery sweep vs a run in the caller's process | The sweep treats any `running` run without a live worker as crashed. A run still executing in the caller's process looks crashed, so the sweep enqueues a worker that runs it forward a second time. | A run executing in the caller's process is recognised as live while that process is alive, however long its steps take. It is recovered only once its process is gone. |
| Caller's last save after a fan-out hand-off | A synchronous run that hands off at a fan-out map saves once more on its way out. If the map finished fast and a worker already resumed the run and saved newer progress, that last save overwrites it. | A save from the caller's process never overwrites progress a worker saved after it. |
| Resume while the reactor's lock or semaphore is held | `continue` raises the acquisition error and leaves the run `paused`. A webhook that does not retry loses the resume. | The payload is validated at once. A valid payload is accepted, stored, and handed to a worker that waits for the lock. `continue` returns a hand-off result instead of raising. |
| Two resumes of the same interrupt at the same instant | Both can read `paused` and both run, in modes that skip the per-run lock (inline job testing). | Exactly one is accepted; the other is rejected, in every execution mode. |
| Resume of a second pending interrupt while the first resume executes | Rejected: "the reactor is running". | Accepted and applied once, if that interrupt has not executed and has no accepted payload yet. |
| Manual undo after the failing step's `compensate` was cut off | Undoes the completed steps but never re-runs that `compensate`; the step can stay half-compensated. | Re-runs the cut-off `compensate` first, then undoes the completed steps. |
| Rolling back a map | Always replays each element's own step undos. | A map can declare `undo_all`, called once with the completed elements' results instead. |

## User Scenarios & Testing *(mandatory)*

### User Story 1 - The recovery sweep never runs a live caller-process run twice (Priority: P1)

A developer runs a reactor synchronously (`Reactor.run`, or an inline `continue`) in a web request
or a script. The host also runs the recovery sweep on a schedule. Today, if a sweep happens while
the run is still executing in the caller's process, the sweep decides the run has crashed and
enqueues a worker that runs it forward again. Steps execute twice; side effects (charges, emails)
happen twice. After this feature the sweep leaves such a run alone while its process is alive, even
if one of its steps takes longer than the sweep interval. If the caller's process dies, the run is
still recovered, as today.

**Why this priority**: Duplicate forward execution breaks the one guarantee users rely on most: a
step's side effect happens once per run. It needs nothing unusual to trigger, only a sweep schedule
and a slow synchronous step.

**Independent Test**: Start a synchronous run whose step blocks for longer than the liveness timeout.
Run the sweep several times while it blocks. Verify the sweep enqueues nothing for that run and the
step runs once. Then kill a caller process mid-run and verify the next sweep after the liveness
timeout recovers the run.

**Acceptance Scenarios**:

1. **Given** a synchronous run executing a step in the caller's process, **When** the recovery sweep
   runs, **Then** it does not enqueue that run and the step runs once.
2. **Given** a synchronous run whose step takes longer than the liveness timeout, **When** sweeps run
   throughout, **Then** none enqueues that run.
3. **Given** an inline `continue` executing the steps after an interrupt in the caller's process,
   **When** the sweep runs, **Then** it does not enqueue that run.
4. **Given** a synchronous run whose caller process was killed mid-step (no clean-up ran), **When** the
   liveness timeout has passed and the sweep runs, **Then** the run is recovered as today.
5. **Given** a synchronous run that handed off at a fan-out map and whose caller already returned,
   **When** the sweep runs, **Then** it treats the run as it does today (waiting on background work).

---

### User Story 2 - A caller's last save never overwrites a worker's progress (Priority: P1)

A developer runs a reactor synchronously and it reaches a fan-out map. The caller's process hands
the map to background jobs and returns a hand-off result. If the elements finish fast, the map's
completion resumes the run in a worker, which runs the steps after the map and saves. Today the
caller's process saves once more on its way out, and that save can land after the worker's and
overwrite it: the run loses progress, re-runs steps, or never finishes. After this feature, no save
from the caller's process replaces progress a worker saved after it.

**Why this priority**: Silent loss of saved progress corrupts the run's record and can repeat side
effects. 009 narrowed the window but did not close it.

**Independent Test**: Run a synchronous reactor with a fan-out map followed by steps. Force the
interleaving in which the worker resumes the run and saves before the caller's process makes its
last save. Verify the stored run reflects the worker's progress, each step after the map runs once,
and the run reaches its final state.

**Acceptance Scenarios**:

1. **Given** a synchronous run that handed off at a fan-out map, **When** the worker resumed by the map's
   completion saves before the caller's process finishes, **Then** the caller's process does not
   overwrite that progress.
2. **Given** the same interleaving, **When** all background work is drained, **Then** every step after
   the map ran once and the run ends `completed`.
3. **Given** an inline `continue` that reaches a fan-out map, **When** the same interleaving happens,
   **Then** the same holds.
4. **Given** the ordinary interleaving (the caller's process finishes before the map completes),
   **When** the run proceeds, **Then** the behavior is unchanged from today.

---

### User Story 3 - A resume that meets a held lock is accepted, not lost (Priority: P1)

A developer pauses a reactor at an interrupt and resumes it from a webhook with `continue`. The
reactor declares a reactor-level lock or semaphore, and another run holds it when the webhook
arrives. Today `continue` raises the acquisition error and the run stays `paused`; a webhook sender
that does not retry loses the resume for good. After this feature, the payload is validated at
once, in the calling process. An invalid payload is answered with its validation failure, and
nothing is stored or enqueued. A valid payload is stored and the resume is handed to a worker,
which waits for the lock without spending retries and resumes the run once it is free. `continue`
returns a hand-off result. The worker never re-validates the payload, so a resume the caller was
told was accepted cannot later fail validation.

**Why this priority**: A lost resume strands a run in `paused` forever, with nothing to show the
webhook was ever received.

**Independent Test**: Hold a reactor's lock from another run. Call `continue` with a valid payload:
it returns a hand-off result and does not raise. Release the lock and drain background work: the
run resumes and finishes with that payload. Repeat with an invalid payload: the validation failure
comes back and no work is enqueued.

**Acceptance Scenarios**:

1. **Given** a paused run whose reactor lock is held by another run, **When** `continue` is called with a
   valid payload, **Then** it returns a hand-off result, does not raise, and the run shows `running`.
2. **Given** that hand-off, **When** the lock is released, **Then** the worker resumes the run with the
   accepted payload and the run reaches its final state.
3. **Given** the lock stays held for longer than the worker's retry budget would allow, **When** it is
   finally released, **Then** the resume still happens; waiting spent no retries.
4. **Given** a paused run whose reactor lock is held, **When** `continue` is called with an invalid
   payload, **Then** the validation failure is returned as today, the payload is not stored, no work is
   enqueued, and the run stays `paused`.
5. **Given** a resume handed off on contention, **When** a second `continue` arrives for the same
   interrupt, **Then** it is rejected as for any resume already accepted.
6. **Given** the same scenario with a reactor-level semaphore with no free slot, **When** `continue` is
   called with a valid payload, **Then** the behavior matches scenarios 1–3.

---

### User Story 4 - Two resumes of one interrupt at the same instant: exactly one wins (Priority: P2)

Two callers (a retried webhook, a double-clicked approval) call `continue` for the same interrupt at
the same moment. Today both can read `paused` before either records the resume. The per-run lock
separates them in production, but modes that skip it (inline job testing) run the interrupt and
everything after it twice. After this feature exactly one resume is accepted, in every execution
mode, and the other is rejected without changing the stored run.

**Why this priority**: The production window is narrow and partly covered today, but when it opens
it runs downstream steps twice, and test suites that use inline mode cannot catch the problem.

**Independent Test**: Release two `continue` calls for the same interrupt from a barrier, many times,
in each execution mode. Verify that each time one is accepted, one is rejected, the interrupt's
payload is the accepted one, and the steps after the interrupt run once.

**Acceptance Scenarios**:

1. **Given** a run paused at interrupt A, **When** two `continue` calls for A arrive at the same instant,
   **Then** exactly one is accepted and the other is rejected with a clear "already resumed" error.
2. **Given** the same race in inline job-testing mode, **When** it happens, **Then** the outcome is the
   same.
3. **Given** the rejected call, **When** the run is inspected, **Then** its payload was not stored and
   nothing it did is visible on the run.
4. **Given** a background-resume interrupt (`resume: :background`), **When** two resumes for it race,
   **Then** exactly one is enqueued.

---

### User Story 5 - Resuming several pending interrupts at once (Priority: P2)

A reactor pauses at two ready interrupts, A and B (for example, two independent approvals). Both
approvers answer at about the same time. Today the resume for A marks the run `running`, and B's
resume, arriving while A's executes, is rejected with "the reactor is running"; B's caller has to
retry. After this feature B's resume is accepted as long as B has not executed and has no accepted
payload yet. Its payload is validated in the calling process and stored, and B is applied once:
either by the resume already executing, or right after it. The run never ends paused at an
interrupt whose resume was accepted.

**Why this priority**: The rejection is retryable and the window is short (interrupts have no body).
But callers that answer in parallel hit it routinely, and a caller that does not retry strands the
run.

**Independent Test**: Pause a run at interrupts A and B. Resume A with a step after A that blocks.
While it blocks, resume B. Verify that B's resume is accepted, both payloads are applied once, and
the run finishes without pausing at B.

**Acceptance Scenarios**:

1. **Given** a run paused at ready interrupts A and B and A's resume executing, **When** B's resume
   arrives with a valid payload, **Then** it is accepted and B is applied once.
2. **Given** that sequence, **When** all work finishes, **Then** the run never pauses at B and ends in
   the state it would reach had A and B been resumed one after another.
3. **Given** A's resume executing, **When** a second resume for A arrives, **Then** it is rejected
   ("already resumed").
4. **Given** A's resume executing, **When** a resume for B arrives with an invalid payload, **Then** the
   validation failure is returned, nothing is stored, and B stays pending.
5. **Given** A's resume executing, **When** a resume arrives for an interrupt whose dependencies are not
   complete, **Then** it is rejected as today.
6. **Given** B's resume accepted while A's executes, **When** A's resume fails and the run rolls back,
   **Then** the run ends failed as for any failure. B's payload is not applied, and B's caller can see
   the outcome on the run.

---

### User Story 6 - Manual undo finishes a compensate that was cut off (Priority: P2)

A step fails in a run executing in the caller's process, and its `compensate` starts. The process is
interrupted part-way (a deploy's signal, an exit, out of memory). The run is recorded `aborted`.
An operator then calls `Reactor.undo(id)`. Today that undoes the steps that completed before the
failure but never re-runs the failing step's `compensate`, so its side effect stays half-reversed.
After this feature the aborted run records which step was failing, with what arguments and error,
and whether its `compensate` finished. Manual undo re-runs a `compensate` that did not finish,
before the completed steps' undos.

**Why this priority**: It breaks saga integrity (Constitution II), but only after a process
interruption during that exact window, so it is rare.

**Independent Test**: Make a step fail and interrupt its `compensate` part-way in the caller's process.
Verify the run is `aborted`. Call manual undo. Verify the `compensate` ran to completion, with the
same arguments and failure as the first attempt, before any completed step was undone.

**Acceptance Scenarios**:

1. **Given** an aborted run whose failing step's `compensate` was cut off, **When** manual undo runs,
   **Then** that `compensate` runs again first, then the completed steps are undone in reverse order.
2. **Given** an aborted run whose failing step's `compensate` finished and the interruption came during
   the undos after it, **When** manual undo runs, **Then** the `compensate` does not run again and only
   the outstanding undos run.
3. **Given** the re-run `compensate` fails, **When** manual undo continues, **Then** the completed steps
   are still undone, and the run's execution trace records that compensation failure, attributed to
   the step.
4. **Given** the failing step inside a composed child that ran in the same process, **When** the root is
   undone manually, **Then** the child's cut-off `compensate` is re-run before that child's undos.
5. **Given** an aborted run with a cut-off `compensate`, **When** an operator inspects the run, **Then**
   its status shows which step's `compensate` is outstanding.

---

### User Story 7 - One bulk undo for a whole map (Priority: P3)

A developer maps over 5,000 payments, each element charging a card. On rollback, the payment provider
offers one bulk refund call; replaying 5,000 per-element refunds is slow and rate-limited. The developer
declares `undo_all { |completed_results| ... }` on the map. When the map is rolled back, for any
reason, that block is called once with the results of the elements that completed, instead of each
element's own undos being replayed. Steps before the map are undone after it returns, as today.

**Why this priority**: A new capability, not a fix. Per-element replay already rolls back correctly;
this one is about efficiency and fitting bulk external APIs.

**Independent Test**: Declare `undo_all` on a fan-out map of N elements, fail a step after the map, and
drain background work. Verify that `undo_all` was called once with N completed results, no element's
own undo ran, and the steps before the map were undone afterwards.

**Acceptance Scenarios**:

1. **Given** a map with `undo_all` whose elements all completed, **When** a later step fails, **Then**
   `undo_all` is called once with every completed element's result, no element undo runs, and the
   steps before the map are undone after it.
2. **Given** an atomic map with `undo_all` where one element failed, **When** the map rolls back,
   **Then** `undo_all` receives only the completed elements' results. The failed element rolled itself
   back as today; skipped elements are not included.
3. **Given** a fan-out map with `undo_all`, **When** it rolls back, **Then** no element rollback jobs are
   dispatched, and the results are passed without loading every element's state at once.
4. **Given** `undo_all` raises or returns a failure, **When** rollback continues, **Then** the steps
   before the map are still undone and the run's final failure lists the bulk undo failure,
   attributed to the map step.
5. **Given** no element completed, **When** the map rolls back, **Then** `undo_all` is not called.
6. **Given** a finished run with a map declaring `undo_all`, **When** an operator undoes the run
   manually, **Then** `undo_all` is called once for that map.
7. **Given** a map without `undo_all`, **When** it rolls back, **Then** behavior is unchanged from
   today.

---

### Edge Cases

- **Long synchronous step**: a caller-process step that runs longer than the liveness timeout and
  longer than the sweep interval is never judged dead while its process is alive (US1).
- **Caller process killed with no clean-up**: the run stays `running`; it is recovered once its
  liveness lapses, as today (US1).
- **Inline job-testing mode**: background work runs immediately inside the caller's frame. Every story
  produces the same final outcome there; US4 must hold there specifically.
- **Contended resume, then the run is cancelled**: an operator cancels a run whose resume is waiting
  on the lock. The waiting resume finds the run cancelled and does nothing.
- **Contended resume on a `resume: :background` interrupt**: already handed to a worker; unchanged.
- **Run-level contention (another execution of the same run is live)**: still rejected, as today,
  unless US5 applies (a different interrupt that has not executed).
- **Max attempts on invalid payloads**: an invalid payload still counts toward the interrupt's attempt
  limit, as today; reaching the limit still fails and compensates the run, as today.
- **Several interrupts accepted while one resume executes**: each is applied once (US5).
- **Interrupted `compensate` in a worker run**: a worker run is not recorded `aborted`; its job is
  redelivered as today. US6 covers the caller-process `aborted` path only.
- **Manual undo of an aborted run whose failing step has no `compensate`**: nothing extra runs; the
  undos run as today.
- **`undo_all` interrupted mid-call** (worker killed): rollback recovery calls it again. Like any undo
  under redelivery, it runs at least once and must tolerate a repeat.
- **`undo_all` and element still in flight or with expired state**: reported as a rollback failure per
  element index, as today (009 FR-007), never silently left out of the bulk call.
- **`undo_all` with elements that did not complete but finished some steps** (aborted elements): they
  have no result for the bulk call, so their own completed steps are undone by the per-element
  replay, as today.
- **Map nested inside a map element with `undo_all`**: the inner map's `undo_all` runs inside the outer
  element's rollback.

## Requirements *(mandatory)*

### Functional Requirements

#### Liveness of caller-process runs (US1)

- **FR-001**: The recovery sweep MUST NOT enqueue a run while it is executing in the caller's process
  (synchronous `Reactor.run`, inline `continue`, manual undo) and that process is alive.
- **FR-002**: FR-001 MUST hold however long a single step runs. Liveness MUST be renewed while the run
  executes, not judged from the run's start time.
- **FR-003**: A caller-process run whose process died without clean-up MUST become recoverable by the
  sweep within one liveness timeout, and MUST then be recovered as today.
- **FR-004**: A run that handed off to background work and whose caller already returned MUST be swept
  as today.

#### No lost progress from the caller's last save (US2)

- **FR-005**: A save made by the caller's process MUST NOT replace run state that a worker saved after
  resuming the same run. This covers the save after a hand-off at a fan-out map, from both
  `Reactor.run` and an inline `continue`.
- **FR-006**: After the race in FR-005, every step after the hand-off MUST run once, and the run MUST
  reach its final state.
- **FR-007**: When the caller's process finishes before any worker resumes the run, behavior MUST be
  unchanged.

#### Resume under lock or semaphore contention (US3)

- **FR-008**: `continue` MUST validate the payload in the calling process before anything else. An
  invalid payload MUST return its validation failure as today (the class-level method raises, the
  instance method returns the failure), store no payload, enqueue nothing, and leave the run `paused`.
  Attempt counting is unchanged.
- **FR-009**: When a valid resume cannot take the reactor-level lock or semaphore, `continue` MUST store
  the payload, mark the run `running`, hand the resume to a background worker, and return a hand-off
  result (`DispatchResult`). It MUST NOT raise the acquisition error.
- **FR-010**: The deferred resume MUST wait for the lock or semaphore without spending the job's retry
  budget, and without being failed by the background snooze limit: a run that already passed its
  first admission is never marked failed for waiting. It MUST resume the run once the lock or
  semaphore is free.
- **FR-011**: The deferred resume MUST NOT re-validate the payload. It applies the payload accepted in
  FR-009.
- **FR-012**: While a deferred resume is pending, another `continue` for the same interrupt MUST be
  rejected, as for any accepted resume.
- **FR-013**: A deferred resume that finds the run cancelled or finished MUST do nothing.
- **FR-014**: A resume deferred on contention MUST be logged as one structured entry carrying reactor
  name, run id, interrupt step and the contended lock or semaphore.

#### One accepted resume per interrupt (US4)

- **FR-015**: Of any number of concurrent resumes for the same interrupt, exactly one MUST be accepted.
  Every other MUST be rejected with an "already resumed" error and MUST NOT change the stored run.
- **FR-016**: FR-015 MUST hold in every execution mode, including inline job-testing mode and
  background-resume interrupts.

#### Concurrent resumes of different interrupts (US5)

- **FR-017**: While the run is executing, a resume for an interrupt MUST be accepted if that
  interrupt is ready, has not executed, and has no accepted payload yet. This applies whether the
  run is executing another resume, its first run, or is waiting on background work. Its payload is
  validated per FR-008.
- **FR-018**: An accepted resume MUST be applied once. The run MUST NOT end paused at an interrupt whose
  resume was accepted, whether the executing resume picks it up or it is applied right after.
- **FR-019**: The caller of a resume accepted under FR-017 MUST receive a hand-off result, as in FR-009.
- **FR-020**: A resume for an interrupt that already executed, or already has an accepted payload, MUST
  be rejected ("already resumed"). A resume for an interrupt that is not ready MUST be rejected as
  today. A resume for a run that is finished, cancelled, `aborted` or rolling back MUST be rejected as
  today (008 FR-032).
- **FR-021**: If the run fails before an accepted payload is applied, the payload MUST NOT be applied,
  and the run's outcome is the failure, as for any failure.

#### Re-running a cut-off `compensate` (US6)

- **FR-022**: A caller-process run recorded `aborted` during its failing step's `compensate` MUST record
  which step was failing, the arguments it was called with, its failure (message and error class), and
  whether its `compensate` finished.
- **FR-023**: A manual undo of such a run MUST re-run a `compensate` that did not finish, with the
  recorded arguments and failure, before undoing the completed steps. A `compensate` recorded as
  finished MUST NOT run again.
- **FR-024**: A re-run `compensate` that fails MUST be reported as a compensation failure attributed to
  the step, the way manual undo reports any rollback failure: an execution-trace entry and the
  compensation-failure middleware event. The completed steps MUST still be undone.
- **FR-025**: FR-022–FR-024 MUST apply to a failing step at any depth executed in the same process
  (a composed child, an inline map element).
- **FR-026**: The run's status view and the dashboard MUST show, for an aborted run, which step's
  `compensate` is outstanding.

#### Map-level `undo_all` (US7)

- **FR-027**: The `map` DSL MUST offer an optional `undo_all` taking a block. It may be declared at most
  once per map; a second declaration, or one without a block, MUST raise a definition error.
- **FR-028**: When a map declares `undo_all`, every rollback of that map MUST call the block once with
  the results of the elements that completed, in element index order, instead of replaying those
  elements' own undos. This covers compensation after an atomic map failure, undo after a later step
  failed, and a manual undo of the run.
- **FR-029**: The completed results MUST be readable without loading every element's state at once, for
  inline and fan-out maps. A fan-out map with `undo_all` MUST NOT dispatch element rollback jobs for
  its completed elements.
- **FR-030**: Element coverage MUST otherwise stay as today (009 FR-007): failed elements roll
  themselves back; skipped elements are excluded; an element in flight or with expired state is
  reported as a rollback failure per element index; an element that did not complete but finished
  some steps is undone by its own per-element replay.
- **FR-031**: `undo_all` MUST NOT be called when no element completed.
- **FR-032**: A failure of `undo_all` (raised or returned) MUST be reported as one rollback failure
  attributed to the map step. The steps before the map MUST still be undone afterwards. No new retry
  policy applies.
- **FR-033**: `undo_all` MUST be called once per map rollback despite duplicate triggers or deliveries.
  If its process dies mid-call, it MAY run again (at least once).
- **FR-034**: Map rollback through `undo_all` MUST emit structured log entries for start and outcome,
  carrying reactor name, map step name and the number of completed elements passed.

#### Delivery

- **FR-035**: README and the affected documentation pages (interrupts and resume, background and async,
  data pipelines, durability and recovery) MUST describe the new behaviors: caller-process liveness,
  the contended-resume hand-off and `continue`'s new return value, concurrent interrupt resumes, manual
  undo re-running a cut-off `compensate`, and `undo_all`.
- **FR-036**: CHANGELOG MUST record `undo_all` under Features, the fixes under Bug Fixes, and a migration
  note for `continue` returning a hand-off result where it used to raise an acquisition error.
- **FR-037**: The demo app MUST include an example reactor, rake task and spec (Constitution
  Principle VI) for `undo_all`, for a resume contended on the reactor's lock, and for concurrent
  resumes of two interrupts. Any assertion the shipped RSpec matchers cannot express MUST add the
  missing matcher or helper.

### Key Entities

- **Caller-process run**: a run executing in the process that called `run`, `continue` or `undo`, not
  in a background worker. It is live while that process is alive and executing it. The sweep may
  recover it only after its liveness lapses.
- **Accepted resume**: a resume whose payload passed validation and was claimed for its interrupt.
  Exactly one per interrupt; applied once, or dropped if the run fails first.
- **Deferred resume**: an accepted resume handed to a background worker because the reactor's lock or
  semaphore was held, or because another resume of the run was executing. It waits without spending
  retries and never re-validates.
- **Outstanding compensation**: on an aborted run, the failing step, its arguments, its failure, and
  whether its `compensate` finished. Manual undo consumes it.
- **Bulk undo (`undo_all`)**: a map-level rollback block called once with the completed elements'
  results. It replaces the per-element replay for completed elements.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: In 100 synchronous runs with sweeps running throughout, including steps longer than the
  liveness timeout, no step runs twice. In 100% of runs whose caller process was killed, the run is
  recovered within one liveness timeout plus one sweep interval.
- **SC-002**: In 100 forced interleavings of a worker resume and the caller's last save, no run loses
  saved progress. Every run reaches its final state with each step after the map run once.
- **SC-003**: 100% of valid resumes delivered while the reactor's lock or semaphore is held are applied
  once after it is released, with no retry by the caller. 0 invalid payloads are stored or enqueued.
- **SC-004**: In 1,000 trials of two simultaneous resumes for the same interrupt, in every execution
  mode, exactly one is accepted every time, and the steps after the interrupt run once.
- **SC-005**: For runs paused at 2 to 5 ready interrupts all resumed at the same time, 100% of valid
  resumes are accepted and applied once each. No run ends paused at an accepted interrupt.
- **SC-006**: For a failing step's `compensate` interrupted at any point, followed by manual undo, 100%
  of runs end with that `compensate` finished (re-run only if it had not finished) and every
  completed step undone.
- **SC-007**: Rolling back a map of 10,000 completed elements that declares `undo_all` makes exactly
  one bulk call and zero per-element undo calls. The memory of the process running the rollback does
  not grow with the element count.

## Assumptions

- **Targeted fixes, not the full fence.** The general "Fenced context writes" proposal in
  `specs/future_improvements.md` stays out of scope. This feature closes the windows named in US1
  and US2. One mechanism (for example, a caller-process run holding the run's liveness lock from its
  start) may cover both; the plan decides.
- **Crash recovery of caller-process runs is unchanged.** A run whose caller process died is recovered
  as today, by resuming it forward in a worker, once its liveness lapses.
- **Only the reactor-level lock and semaphore gate a resume.** Resumes skip the rate-limit and period
  gates today; this feature does not change that.
- **`continue` returning a hand-off result is a MINOR change.** Code that rescued the acquisition error
  to retry keeps working: the rescue simply no longer fires. The CHANGELOG carries a migration note.
- **A cut-off `compensate` must tolerate being run again**, as an undo must under redelivery. The
  documentation states this.
- **Worker-path interruptions are unchanged.** A worker run is not marked `aborted`; its job is
  redelivered as today.
- **`undo_all` does not change element self-rollback.** An element that failed still rolls itself
  back with its own steps' `compensate` and undos; `undo_all` only replaces the replay of completed
  elements.
- **`undo_all` gets the elements' results only.** The block receives what each completed element
  returned; anything else it needs (an order id, a batch reference) comes from those results.
- **Inline job-testing mode** must produce the same final outcomes as real background workers for
  every story.
- **Depends on** 008 (aborted runs, FR-032 resume rule, rollback-failure attribution) and 009
  (distributed map rollback, element coverage rules, save-before-release on the worker path).
