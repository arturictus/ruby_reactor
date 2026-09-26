# Feature Specification: Execution Flow & Compensation Analysis

**Feature Branch**: `execution_flow_analysis`

**Created**: 2026-09-26

**Status**: Draft

**Input**: User description: "We need to do a thorough analysis of the execution flow. That means
to figure out all the invariants and paths the execution flows in all conditions. We have to get:
order of execution of reactors and compensation in all the possible conditions.

We have to take into account:
- composed reactors
- maps
- async steps
- async reactors

In all the invariants:
- locks
- retries
- failures

This is important because we have to figure out if compensation is predictable and the DSL helps
clearly understand how everything is gonna be executed.

For example: I'm not very sure how compensation behaves in composed reactors and maps. In maps:
- we are not compensating individually all the maps already executed.
- when composed reactors fail do we compensate all previous composed reactors.

Should we add an entry point for maps to compensate all on failure? for example:

```ruby
map :many_things do
  compensate_all do |all_elements|
    all_elements.destroy
  end
  # or
  compensate_each do |element|
    element.destroy
  end
end
```

This initiative is a research project to later figure out what solutions we could implement based
on data and evidence. We could suggest fixes at the end but they will be later analysed.
ONLY DOCUMENTATION."

## User Scenarios & Testing *(mandatory)*

The "users" of this research are the RubyReactor maintainers who must decide whether (and how) to
change rollback semantics, and reactor authors who need to predict what runs, in what order, when
something fails.

### User Story 1 - Look up the exact rollback order for any failure (Priority: P1)

A maintainer picks a reactor shape (plain steps, a composed reactor, a map, an async step, an async
reactor, or any nesting of these) and a point of failure, and finds the exact ordered sequence of
forward executions, compensations and undos that the library performs — including which already
completed work is **not** rolled back.

**Why this priority**: This is the core question of the initiative ("is compensation
predictable?"). Every later decision depends on knowing current behavior precisely.

**Independent Test**: Take any row of the delivered execution-order matrix, build that reactor
shape, trigger the failure at the stated point, and compare the observed sequence of step events
with the documented sequence. They match.

**Acceptance Scenarios**:

1. **Given** a reactor whose third of four plain steps fails, **When** the maintainer reads the
   matrix, **Then** they find the failing step's compensation followed by undo of steps two and one
   (in that order), and that step four never runs.
2. **Given** a map whose fifth element fails after four elements succeeded, **When** the maintainer
   reads the map section, **Then** they find whether the four succeeded elements are individually
   rolled back, rolled back as a whole, or left in place — for both synchronous and asynchronous
   map execution and for each failure-tolerance setting.
3. **Given** a parent reactor with two composed child reactors where the second child fails,
   **When** the maintainer reads the composition section, **Then** they find whether the first
   child's completed steps are undone, in what order relative to the parent's own steps, and whether
   the second child's own completed steps are undone before the parent learns of the failure.

---

### User Story 2 - Answer the open questions explicitly (Priority: P1)

The maintainer finds a dedicated answer, with evidence, to each question raised in the input:
(a) are already-executed map elements compensated individually; (b) when a composed reactor fails,
are previously completed composed reactors compensated; (c) would a map-level "compensate all" /
"compensate each" entry point close a real gap.

**Why this priority**: These are the concrete doubts that triggered the research; they must be
answered unambiguously, not left implicit in a large matrix.

**Independent Test**: Read the "Answers" section in isolation; each question has a yes/no/depends
answer, the conditions under which it holds, and the evidence that supports it.

**Acceptance Scenarios**:

1. **Given** question (a), **When** the maintainer reads its answer, **Then** it states what
   happens to completed elements when a later element fails and when a step *after* the map fails,
   in every map execution mode.
2. **Given** question (c), **When** the maintainer reads its answer, **Then** it states whether the
   gap exists today and what problem each proposed entry point would and would not solve.

---

### User Story 3 - Catalogue of invariants under locks, retries and failures (Priority: P2)

The maintainer reads a list of invariants — statements that must always hold about execution and
rollback (e.g. "a step whose lock was never acquired is never compensated", "retries are exhausted
before compensation starts", "a lock taken by a step is held while that step is undone") — each
marked as holding, violated, holding only under conditions, or undetermined, with evidence.

**Why this priority**: Locks, retries and asynchrony multiply the paths through the executor. A
tested catalogue of invariants is what makes future changes safe to review.

**Independent Test**: Pick any invariant marked "holds" and reproduce the scenario it names; the
observed behavior agrees. Pick any marked "violated" and reproduce the counter-example.

**Acceptance Scenarios**:

1. **Given** a step that is retried and ultimately exhausts its attempts, **When** the maintainer
   reads the retry invariants, **Then** they learn whether compensation runs once or per attempt,
   and whether it runs synchronously or when the last retry fails in the background.
2. **Given** a step protected by a lock that fails, **When** the maintainer reads the lock
   invariants, **Then** they learn when the lock is released relative to the step's compensation
   and to the undo of earlier steps.

---

### User Story 4 - Predictability and DSL clarity assessment (Priority: P2)

The maintainer reads a ranked list of findings where behavior is surprising, inconsistent between
execution modes (inline vs background), not visible from the reactor definition, or different from
what README/documentation claims.

**Why this priority**: The initiative's stated goal is judging whether "the DSL helps clearly
understand how everything is going to be executed". Findings are the bridge from facts to decisions.

**Independent Test**: Each finding names the scenario, the expected-by-a-reader behavior, the
actual behavior, and a severity; a reviewer can verify it without reading the rest of the report.

**Acceptance Scenarios**:

1. **Given** a documented claim about compensation or ordering, **When** the actual behavior
   differs, **Then** the finding quotes the claim and the location it appears in.

---

### User Story 5 - Evidence-based improvement options (Priority: P3)

For each significant finding, the maintainer reads candidate remedies (including the proposed map
`compensate_all` / `compensate_each` entry points), each with trade-offs, compatibility impact and
open questions — explicitly **not** a decision.

**Why this priority**: The user wants suggestions to analyse later; they are useful but depend on
the facts produced by stories 1–4.

**Independent Test**: Each option references the finding(s) it addresses and states at least one
downside.

**Acceptance Scenarios**:

1. **Given** the map-compensation gap (if confirmed), **When** the maintainer reads its options,
   **Then** they see at least the two proposed shapes compared on failure semantics, async
   behavior, and interaction with retries and failure tolerance.

---

### Edge Cases

- The compensation or undo of a step itself fails (returns failure or raises): does rollback of
  earlier steps continue, and what does the final result report?
- A failure occurs while an async step or async reactor is still pending, and the parent is
  resumed later in a different process.
- A map configured to tolerate element failures (collect results instead of failing fast) versus
  one that fails fast; partially dispatched async maps when the failure happens.
- A composed reactor nested inside a map, and a map nested inside a composed reactor.
- A step that fails because its lock/semaphore could not be acquired (never started) versus a step
  whose body started and then failed.
- A step that returns a halt/skip signal instead of success or failure.
- A reactor that is paused (interrupt) and later resumed, then fails after resume: are steps
  completed before the pause undone?
- A worker crashes mid-execution and the sweeper re-drives it: can any step run or be compensated
  twice?
- Input validation failures on the reactor or a step (before any body runs).
- Steps that define neither compensation nor undo.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The deliverable MUST inventory every execution construct in scope — plain step,
  composed reactor, map (synchronous and asynchronous, fail-fast and failure-tolerant), async step,
  async/background reactor, interrupt step — and describe each one's lifecycle from scheduling to
  terminal state.
- **FR-002**: The deliverable MUST provide an execution-order matrix: for each construct and each
  failure location (before, inside, after the construct; in a nested child), the ordered sequence
  of forward runs, compensations and undos, and the list of completed work that is left in place.
- **FR-003**: The matrix MUST distinguish inline (same process) execution from background
  execution wherever their ordering or rollback coverage differ.
- **FR-004**: The deliverable MUST cover the cross-cutting conditions: locks (reactor-level,
  step-level, ordered locks, semaphores), retries (in-attempt, re-enqueued, exhausted), and failure
  kinds (returned failure, raised error, input validation failure, coordination contention,
  compensation/undo failure, timeout, crash and re-drive).
- **FR-005**: The deliverable MUST answer the three questions of User Story 2 in a dedicated
  section with explicit conditions and evidence.
- **FR-006**: The deliverable MUST state invariants as testable propositions, each with a status
  (holds / violated / conditional / undetermined) and supporting evidence.
- **FR-007**: Every behavioral claim MUST cite evidence: a source location, an existing automated
  test, and/or a reproducible observation. Claims MUST be labelled with the kind of evidence that
  supports them, and claims backed only by reading MUST be distinguishable from observed ones.
- **FR-008**: The deliverable MUST map each invariant to the existing automated tests that cover it
  (or state that none do), so coverage gaps are visible.
- **FR-009**: The deliverable MUST list predictability/DSL-clarity findings, each with scenario,
  expected-by-reader behavior, actual behavior, severity, and any contradicting documentation.
- **FR-010**: The deliverable MUST propose improvement options for significant findings, including
  an evaluation of map-level `compensate_all` and `compensate_each`, with trade-offs and
  compatibility impact, and MUST mark all options as proposals pending later analysis.
- **FR-011**: The initiative MUST NOT change library runtime behavior, the test suite, or the demo
  application; its outputs are documentation only.
- **FR-012**: Ordering descriptions MUST be presented so a reader can follow them without reading
  source (numbered sequences and/or diagrams per scenario).

### Key Entities

- **Execution construct**: a unit the reactor schedules (step, compose, map, async step, async
  reactor, interrupt), with its lifecycle states and rollback hooks.
- **Scenario**: a reactor shape plus a failure location plus cross-cutting conditions (lock,
  retry, execution mode).
- **Execution trace**: the ordered list of forward, compensation and undo events for a scenario.
- **Invariant**: a proposition about ordering or rollback, with status, evidence and test coverage.
- **Finding**: a place where behavior is unpredictable, inconsistent, invisible in the DSL, or
  contradicts documentation; carries severity.
- **Improvement option**: a candidate remedy linked to findings, with trade-offs; not a decision.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: 100% of construct × failure-location cells in the matrix are filled with a sequence
  or explicitly marked "not reachable", with no blank cells.
- **SC-002**: A maintainer unfamiliar with the executor internals can answer each of the three
  input questions from the deliverable in under 5 minutes.
- **SC-003**: 100% of behavioral claims carry an evidence label; at least the headline claims for
  maps, composition, async steps and async reactors (the four constructs named by the user) are
  backed by a reproducible observation, not only by reading.
- **SC-004**: Every finding rated high severity has at least two improvement options, each with at
  least one stated downside.
- **SC-005**: Zero changes to library runtime code, automated tests or demo application result
  from this initiative.

## Assumptions

- "Compensation" follows the library's existing vocabulary: *compensate* is the failing step's own
  cleanup, *undo* is the reverse-order rollback of previously completed steps. The analysis covers
  both and refers to them together as "rollback".
- Interrupts (pause/resume) are in scope only where they change execution or rollback order; they
  were not named by the user but affect "all conditions".
- Reproducible observations may be produced by throwaway probe reactors run against the project's
  real storage; the probes and their recorded outputs are kept alongside the research documents as
  evidence, not added to the library, test suite or demo app.
- README.md and ./documentation are audited for claims that contradict findings, but not edited:
  documenting current behavior as contract before the follow-up decision would lock it in.
  Documentation changes ship with whichever remedy is later chosen.
- Rate limits and periods are treated as a kind of coordination contention (like locks) and not
  analysed separately unless they produce a distinct rollback path.
- The analysis reflects the current `main`-based code at the time of writing (after step-scoped
  retry declarations and inputs protection landed).
