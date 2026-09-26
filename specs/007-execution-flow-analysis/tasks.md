# Tasks: Execution Flow & Compensation Analysis

**Input**: Design documents from `specs/007-execution-flow-analysis/`

**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/report-structure.md,
quickstart.md

**Tests**: No test tasks. This is documentation-only (FR-011). Evidence probes are research
artifacts under `evidence/` and check themselves (expected vs observed).

**Organization**: Tasks are grouped by user story. `FD` below = `specs/007-execution-flow-analysis`.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: User story the task belongs to (US1–US5)

## Rules for every probe task

- Each probe is a `scenario "S-<area>-<nn>", "<shape>", mode:, expected: [...] do … end` block
  (harness from T002). Step bodies call `rec("run:x")` / `rec("compensate:x")` / `rec("undo:x")`.
- `expected` starts as the hypothesis from research.md. If the probe prints `MISMATCH`, the
  **observation wins**. Update `expected` to the observed sequence and record the deviation in the
  report (a refuted hypothesis is a result, not a failure).
- Use `base_delay: 0` for retries. Drain async work with `drain` (harness).
- Never edit `lib/`, `spec/`, `demo_app/`, `README.md`, `documentation/`.

---

## Phase 1: Setup

**Purpose**: Evidence harness able to run a scenario end to end against real Redis.

- [X] T001 Create `FD/analysis/` and `FD/evidence/probes/`. Confirm test Redis answers `PING` at
  `redis://localhost:6780` (or `RUBY_REACTOR_TEST_REDIS_URL`) and that
  `bundle exec ruby -e 'require "ruby_reactor"'` loads from the repo root.
- [X] T002 Create `FD/evidence/harness.rb`. Configure RubyReactor storage (redis URL from env,
  default 6780) and `async_router = Adapters::Sidekiq::Router`. Put `Sidekiq::Testing.fake!` on.
  Define a global event recorder `rec(event)`. Define a `Recorder` middleware (subclass of
  `RubyReactor::Middleware`) that logs `lock_acquired`, `lock_released`, `semaphore_acquired`,
  `semaphore_released`, `retry_attempt`, `start_compensation`, `start_undo`, and register it
  globally. Define `scenario(id, title, mode:, expected:, &block)`: it FLUSHDBs, clears Sidekiq
  jobs and the recorder, runs the block (the block returns the final result), appends
  `=> success|failure(<step>)|halt|paused`, then prints the block format from
  contracts/report-structure.md and tallies MATCH/MISMATCH. Define `drain` wrapping
  `RubyReactor::RSpec::SidekiqHelpers.drain_async_jobs`, and `outcome(result)`.
- [X] T003 Create `FD/evidence/run.rb`. Require the harness and every `probes/*.rb` in sorted
  order, honour the `PROBE=<substring>` filter, and print a final
  `N scenarios, X match, Y mismatch` line.

---

## Phase 2: Foundational (blocking)

**Purpose**: Establish the plain-step rollback baseline that every other construct is described
against. Refuting it would change every later expectation.

- [X] T004 Create `FD/evidence/probes/01_plain.rb` covering research H1–H6.
  `S-plain-01` a→b(fails)→c. `S-plain-02` b raises vs returns Failure. `S-plain-03` b's
  compensate fails (prior undos still run? rollback_failures?). `S-plain-04` an undo fails
  (remaining undos run?). `S-plain-05` b returns Halt (no rollback). `S-plain-06` a Skipped step
  before the failure (not undone). `S-plain-07` an argument `transform` raises a StandardError
  after a completed step (H5: is `a` undone?). `S-plain-08` an output validation failure (H6).
  `S-plain-09` a DAG with two independent branches (undo order = completion order reversed).
  Run `PROBE=plain`, fix expectations until they MATCH, and save the transcript.
- [X] T005 Write the "Rollback algorithm" section of `FD/analysis/execution-order.md` (generic
  compensate → reverse-undo, never-started exception, Halt/Skipped, error classes that skip
  rollback) with a Mermaid flow and `[R]`/`[O: S-plain-*]` labels.

**Checkpoint**: Baseline confirmed. Construct probes can now be written in parallel.

---

## Phase 3: User Story 1 — Exact rollback order for any failure (P1) 🎯 MVP

**Goal**: A per-construct order matrix with no blank cells (FR-001/002/003/012, SC-001).

**Independent Test**: Pick any matrix row, run its probe id with `PROBE=<id>`, and see `MATCH`.

- [X] T006 [P] [US1] Create `FD/evidence/probes/02_compose.rb` (H10–H13). `S-compose-01` parent
  a → compose(c1→c2 fails) → b. `S-compose-02` a → compose(c1→c2) → b fails (compose undone ⇒
  c2, c1 undone). `S-compose-03` compose X(x1,x2) → compose Y(y1→y2 fails) (**Q2**: X's steps
  undone?). `S-compose-04` compose nested two levels, innermost fails. `S-compose-05` compose with
  `retries max_attempts: 2`, child c2 fails once then succeeds (H12: are undone c1 results reused
  without re-running c1?). `S-compose-06` compose inside background worker (`background all:`),
  failure after it.
- [X] T007 [P] [US1] Create `FD/evidence/probes/03_map.rb` (H14–H18). Element reactor has steps
  e1→e2 with undo on both. `S-map-01` inline fail_fast, element 2 of 4 fails (**Q1**: are elements
  0–1 undone?). `S-map-02` inline `fail_fast false`, one element fails. `S-map-03` inline map ok →
  next parent step fails (map elements undone?). `S-map-04` fan-out fail_fast, one element fails
  (drain; which elements ran, which were rolled back, parent rollback). `S-map-05` fan-out
  `fail_fast false`. `S-map-06` fan-out ok → next parent step fails. `S-map-07` map inside a
  composed child, element fails. `S-map-08` element reactor that composes a child, element fails.
- [X] T008 [P] [US1] Create `FD/evidence/probes/04_async.rb` (H19–H22). `S-async-01` async_step
  fails, no reader (parent outcome? step's compensate?). `S-async-02` async_step fails, reader
  `fail!`s (whose compensate runs? async_step's compensate/undo?). `S-async-03` async_step
  succeeds, later parent step fails (async_step undone?). `S-async-04` async_reactor child fails
  (child's own rollback, parent unaffected). `S-async-05` async_reactor child fails, reader
  `fail!`s. `S-async-06` async_reactor child succeeds, parent fails later (child undone?).
  `S-async-07` async_step with `retries max_attempts: 3` always failing (attempt count,
  compensate calls).
- [X] T009 [P] [US1] Create `FD/evidence/probes/05_background.rb` (H8, H23). `S-bg-01`
  `background all: true`, step 3 fails (same order as inline?). `S-bg-02` `background after: :a`,
  worker step c fails (is caller-side a undone?). `S-bg-03` `background all:` with a retrying step
  that exhausts (re-enqueue per attempt, single compensate at the end). `S-bg-04` `background all:`
  with a retrying step that succeeds on attempt 2 (no compensate at all).
- [X] T010 [US1] Run `bundle exec ruby FD/evidence/run.rb | tee FD/evidence/output.txt`. Reconcile
  every MISMATCH in T006–T009 (observation wins) and re-run until clean. Note refuted hypotheses
  for the report.
- [X] T011 [US1] Write "Construct lifecycles" in `FD/analysis/execution-order.md`: step, compose,
  map inline, map fan-out (dispatcher → element executor → collector → parent resume),
  async_step (dispatch → StepWorker → record → reader), async_reactor, background reactor,
  interrupt. Each is a numbered lifecycle saying where rollback hooks attach and where locks are
  held, with `[R]` citations.
- [X] T012 [US1] Write the "Order matrix" tables in `FD/analysis/execution-order.md`, one table per
  construct, with columns per contracts/report-structure.md. Fill every cell from `output.txt`
  (`[O]`) or reading (`[R]`, labelled *by reading*). Mark unreachable combinations as
  `not reachable: <reason>`.

**Checkpoint**: US1 complete. The matrix alone answers "what runs, in what order, what is left in
place".

---

## Phase 4: User Story 2 — Explicit answers to the open questions (P1)

**Goal**: The three questions each answered in under 5 minutes of reading (FR-005, SC-002).

**Independent Test**: Read `FD/analysis/README.md` "Answers" alone. Each has a verdict line,
conditions, evidence and links.

- [X] T013 [US2] Write `FD/analysis/README.md`: scope & baseline, how to read (vocabulary,
  labels, scales), **Answers** Q1 (map elements), Q2 (earlier composed reactors), Q3
  (compensate_all/compensate_each gap: gap exists? what each shape would/would not fix, with a
  forward link to options). Include per-mode conditions (inline vs fan-out, fail_fast on/off),
  and a file index. Top-findings list is filled in T019.

---

## Phase 5: User Story 3 — Invariants under locks, retries, failures (P2)

**Goal**: Testable invariant catalogue with status, evidence, coverage (FR-006, FR-008).

**Independent Test**: Re-run any `[O]` scenario an invariant cites. A `VIOLATED` one reproduces
its counter-example.

- [X] T014 [P] [US3] Create `FD/evidence/probes/06_coordination.rb` (H2, H7, H24, H25).
  `S-lock-01` reactor `with_lock`, step fails (lock_released after last undo?). `S-lock-02`
  step-class `with_lock` on b, c fails (b's lock released after run, re-acquired around undo:b).
  `S-lock-03` step lock pre-held by another owner, sync run (b never started ⇒ no compensate:b,
  a undone). `S-lock-04` step `with_semaphore limit: 1` same as 02. `S-retry-01` b retries 3× then
  fails (3 run:b, then one compensate:b). `S-retry-02` `fail!(…, retry: false)` inside a retrying
  step (no further attempts). `S-retry-03` a retrying step that succeeds on attempt 2 (no
  compensate).
- [X] T015 [P] [US3] Create `FD/evidence/probes/07_interrupts_manual.rb` (H26–H28). `S-intr-01`
  a → interrupt → c fails after `continue` (a undone?). `S-intr-02` interrupt payload validation
  exhausting `max_attempts` (undo of a?). `S-intr-03` `Reactor.cancel` on a paused reactor (no
  rollback). `S-intr-04` `Reactor.undo(id)` on a completed reactor (reverse undo, reactor lock
  taken or not?).
- [X] T016 [US3] Re-run the full probe set, update `FD/evidence/output.txt`, reconcile mismatches.
- [X] T017 [US3] Map each invariant to existing specs: grep `spec/` (e.g. `compensation_*`,
  `undo_spec`, `compose_spec`, `map/*`, `step_coordination/*`, `retry_*`, `interrupt_*`,
  `async_*`) and record `[T: path:line]` or `none`.
- [X] T018 [US3] Write `FD/analysis/invariants.md`: `INV-nn` entries grouped by area (ordering,
  rollback coverage, never-started, retries, locks, async isolation, interrupts/manual,
  crash/re-drive), each with all data-model fields, ending with the coverage summary (counts by
  status, list of `coverage: none`).

---

## Phase 6: User Story 4 — Predictability & DSL-clarity findings (P2)

**Goal**: A ranked list of findings plus the documentation audit (FR-009). This is the
constitution's documentation task (plan.md Complexity Tracking).

**Independent Test**: Each finding stands alone: scenario, reader expectation, actual, severity,
doc conflict.

- [X] T019 [US4] Write the "Findings" section of `FD/analysis/findings-and-options.md`: `F-nn`
  ranked High → Low with all data-model fields, derived from VIOLATED/CONDITIONAL invariants,
  refuted hypotheses and DSL gaps (e.g. map has no compensate/undo/retries surface, compose has no
  compensate/undo hook, async unit compensate blocks never run). Then fill the Top-findings list
  in `FD/analysis/README.md`.
- [X] T020 [US4] Write the "Documentation audit" table in `FD/analysis/findings-and-options.md`:
  every README.md / `documentation/*.md` claim about ordering or rollback that is contradicted,
  incomplete or unstated. Cover README "Error Handling and Compensation", async_step/async_reactor
  sections, `documentation/composition.md` compose-vs-async_reactor table,
  `documentation/background_and_async.md` "Compensation is opt-in" and "Error Handling and
  Compensation", `documentation/data_pipelines.md` fail_fast, `documentation/core_concepts.md`
  "Compensation Order", `documentation/DAG.md`. Quote the claim and give `file:line`. **No edits to
  those files.**

---

## Phase 7: User Story 5 — Improvement options (P3)

**Goal**: Proposals only, linked to findings (FR-010, SC-004).

**Independent Test**: Every option names its finding(s) and at least one con. Every High finding
has ≥2 options.

- [X] T021 [US5] Write the "Options" section of `FD/analysis/findings-and-options.md`. Include the
  required evaluation of map `compensate_all` vs `compensate_each` (and alternatives, e.g.
  element-reactor undo replay / MapStep#undo over stored element contexts), compared on
  fail_fast on/off, inline vs fan-out, element retries, a later-step failure, and data
  availability. Give ≥2 options per High finding, each with compatibility impact and open
  questions. Close with the "proposals pending later analysis" note.

---

## Phase 8: Polish & Cross-Cutting

- [X] T022 Run the quickstart.md validation. Check for no `TBD|TODO|???` in `FD/analysis/*.md`.
  Check that every `[O: S-…]` label resolves to a block in `FD/evidence/output.txt`. Check that
  every High finding has ≥2 options with cons. Fix gaps.
- [X] T023 Documentation task (REQUIRED, Constitution Development Workflow). Confirm T020's audit
  covers README.md and each relevant `./documentation` file. Per plan.md Complexity Tracking,
  README/documentation are **not edited**: behavior is unchanged, and doc updates ship with the
  chosen remedy. Record that decision in `FD/analysis/README.md` scope.
- [X] T024 Verify zero product diff: `git status --porcelain` / `git diff --stat` show changes
  only under `FD/`, `CLAUDE.md` (agent pointer) and `.specify/feature.json` (SC-005, FR-011).
- [X] T025 Mark all tasks complete in `FD/tasks.md`.

**Constitution Principle VI**: N/A. No public API or user-facing behavior change, so no demo
reactor, rake task or demo spec. Any remedy chosen later carries its own.

---

## Dependencies & Execution Order

- **Setup (T001–T003)** → **Foundational (T004–T005)** → user stories.
- **US1 (T006–T012)**: T006–T009 in parallel (separate probe files). T010 after all four.
  T011–T012 after T010.
- **US2 (T013)**: after US1 (answers cite matrix rows).
- **US3 (T014–T018)**: T014/T015 can start right after Foundational, in parallel with US1 probes.
  T016 after T014/T015 (and T010, since it re-runs everything). T017 is independent. T018 after
  T016+T017.
- **US4 (T019–T020)**: after US1 and US3 (findings derive from matrix + invariants). T020 can
  start any time (reading only).
- **US5 (T021)**: after T019.
- **Polish (T022–T025)**: last.

### Parallel Example

```text
# After T005:
T006 02_compose.rb   T007 03_map.rb   T008 04_async.rb   T009 05_background.rb
T014 06_coordination.rb   T015 07_interrupts_manual.rb   T017 spec coverage grep   T020 doc audit
```

## Implementation Strategy

1. **MVP = Setup + Foundational + US1 + US2**: the matrix plus the three direct answers already
   settle the user's immediate doubts (maps, compose).
2. Add US3 (invariants) for review-safety of future changes.
3. Add US4 + US5 (findings, audit, options) as input to the follow-up decision.
4. Probes stay re-runnable, so any later remedy can re-run them and compare before/after.
