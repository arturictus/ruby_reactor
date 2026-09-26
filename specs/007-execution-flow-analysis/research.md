# Research: Execution Flow & Compensation Analysis

**Phase 0 output for** [plan.md](plan.md). No `NEEDS CLARIFICATION` remained in the Technical
Context. This file records the **method** decisions and the **preliminary hypotheses** that Phase 0
code reading produced. The hypotheses are the targets the implementation must confirm or refute
with evidence. They are not conclusions.

Baseline: commit `faf90e8d` (after #61 step-scoped retries and #63 inputs protection).

## Method decisions

### D1 — Evidence = source citations + executable probes against real Redis

- **Decision**: Each behavioral claim cites `file:line` [R]. Headline claims are also reproduced by
  a probe [O] in `evidence/probes/`, run with Sidekiq in **fake** mode and drained through
  `RubyReactor::RSpec::SidekiqHelpers.drain_async_jobs`. That runs the real `Worker`,
  `MapElementWorker`, `MapCollectorWorker` and `StepWorker` bodies against the real test Redis.
- **Rationale**: Multi-process paths (collector resuming a parent, step worker writing records,
  async reactor child) are hard to order by reading alone. Fake+drain is the same mechanism the
  gem's own async specs use, so the observations match what the suite trusts.
- **Alternatives considered**: New RSpec files under `spec/` (rejected: FR-011, changes the test
  suite). Mocked storage (rejected: Constitution III). Docker demo app (rejected: same code paths,
  far slower to iterate). `Sidekiq::Testing.inline!` (rejected as the default: it re-enters jobs
  synchronously inside the caller's frame and skips liveness locks, so it hides real ordering. Used
  only where a probe needs it explicitly, and labelled).

### D2 — Trace capture: recorder middleware + step-body log

- **Decision**: One recorder collects, in order, (a) body events that probe steps write themselves
  (`run:X`, `compensate:X`, `undo:X`), and (b) middleware events from a registered recording
  middleware (`lock_acquired`, `lock_released`, `semaphore_*`, `retry_attempt`,
  `start_compensation`, `start_undo`, `start_reactor`, `failed_reactor`, …). Probes also dump
  `Failure#rollback_failures` and the context `execution_trace` where useful.
- **Rationale**: Body events show *what ran*. Middleware events show *where locks sit relative to
  rollback*, which US3 AS2 asks for. Both come from shipped surfaces, with no patching.
- **Alternatives considered**: Monkey-patching `CompensationManager` (rejected: evidence must come
  from the public surface). Reading only `execution_trace` (rejected: it omits lock events and
  lives per context, so nested children would have to be stitched together).

### D3 — Execution modes covered

- **Decision**: inline (plain `Reactor.run`). Worker: `background all:` / `after:` / `before:`,
  fan-out map, `async_step`, `async_reactor`, collector resume. Interrupt pause/continue.
  The ActiveJob backend is **not** probed separately. Its adapters delegate to the same shared
  bodies (`Worker`, `Map::ElementExecutor`, `Map::Collector`, `StepWorker`), and the report cites
  that delegation [R].
- **Rationale**: Ordering is decided in the shared bodies. The adapters only enqueue and perform.
- **Alternatives considered**: Probing both backends (rejected: doubles runtime and adds no ordering
  information).

### D4 — Vocabulary

- **Decision**: *compensate* = the failing step's own cleanup (receives the error).
  *undo* = rollback of a previously completed step, walked in reverse completion order (receives
  its result). *rollback* = both. *Left in place* = completed work that no rollback touches.
  *Unit* = an `async_step` or `async_reactor` dispatch.
- **Rationale**: Matches `CompensationManager` and README usage, so readers can map the report
  onto the code.

### D5 — Evidence labels

- **Decision**: `[R: path:line]` read in source. `[O: probe-id]` observed in
  `evidence/output.txt`. `[T: spec/path:line]` covered by an existing spec. A claim with only [R]
  is marked *by reading*.

### D6 — Invariant status

- **Decision**: `HOLDS` (evidence agrees, no counter-example found), `VIOLATED` (a reproducible
  counter-example exists), `CONDITIONAL` (holds only under stated conditions, which are listed),
  `UNDETERMINED` (evidence insufficient; says what would settle it).

### D7 — Finding severity

- **Decision**: **High**: completed side effects silently left in place on failure, a side effect
  that can run twice, or rollback of work that never ran. **Medium**: the behavior is
  defensible but differs by mode (inline vs worker) or contradicts documentation. **Low**:
  clarity/naming. The behavior is predictable, but the DSL gives no hint of it.

### D8 — Deliverable layout

- **Decision**: See plan.md "Project Structure": four report files under `analysis/` plus
  `evidence/`.
- **Rationale**: Readers come with one of three questions (what order? what always holds? what's
  wrong?). One file per question keeps each scannable. The index carries the three direct
  answers so SC-002 (under 5 minutes) holds.

### D9 — Documentation is audited, not edited

- **Decision**: Contradicted or missing claims are listed in `findings-and-options.md` with
  `file:line` and the quoted text.
- **Rationale**: See plan.md Complexity Tracking.

### D10 — Coordination scope

- **Decision**: Reactor-level `with_lock` / `with_semaphore` / `with_ordered_lock` / rate
  limit / period, and step-level `with_lock` / `with_semaphore` / `with_ordered_lock` /
  `with_rate_limit` / `with_period`. Lock and semaphore are probed. Ordered lock, rate limit and
  period are analysed by reading, with probes only where they create a distinct rollback path.

## Preliminary hypotheses (to confirm or refute in implementation)

Each hypothesis becomes a probe and/or an invariant. Source pointers are where reading found it.

### Plain steps

- **H1** Failure of step N: `compensate(N)`, then `undo(N-1 … 1)` in reverse completion order,
  then no further steps run. `executor/compensation_manager.rb` `handle_step_failure`,
  `rollback_completed_steps`.
- **H2** A step whose own lock/semaphore/rate-limit acquisition failed (never started) is **not**
  compensated. Earlier steps are still undone. `compensation_manager.rb`
  `NEVER_STARTED_ERROR_CLASSES`.
- **H3** A compensate that fails still lets prior undos run. The reactor then fails with a
  `CompensationError`-derived message. An undo that fails does **not** stop the remaining undos.
  Both are reported on `rollback_failures`.
- **H4** `Halt` stops without any rollback. `Skipped` steps never enter the undo stack.
- **H5** An exception that is **not** a `RubyReactor::Error::Base` and escapes outside a step body
  (e.g. an argument `transform` or a `where`/guard raising) reaches
  `ResultHandler#build_execution_failure`'s "unknown error" branch, which does **not** roll back.
  Completed steps are left in place.
- **H6** Output-validation failure compensates the step (its side effect exists) and undoes prior
  steps.

### Retries

- **H7** Retries run before any compensation. Compensation runs exactly once, after the last
  attempt (`MaxRetriesExhaustedFailure`). No per-attempt compensation.
- **H8** Inline reactor: retry backoff `sleep`s in-process. In a worker (`background`, map
  element): the retry is a re-enqueue (`RetryQueuedResult`), and compensation happens in whichever
  delivery exhausts the attempts.
- **H9** `async_step` retries are in-worker loops (`StepWorker#run_step`). They never re-enqueue,
  and exhaustion writes a failed record **without** calling the step's `compensate`.

### Compose

- **H10** Child failure: the child rolls itself back first (child compensate + child undos). Then
  the parent treats the compose step as failed. `ComposeStep#compensate` runs, but is a no-op
  because the child undo stack is already cleared, or because `current_step` is not the compose
  name when the compensate runs outside `with_step`. Then the parent undoes its own earlier steps,
  **including earlier compose steps**, whose `undo` replays the child's undo stack in reverse.
- **H11** A parent step failing **after** a completed compose undoes the compose, which undoes all
  child steps in reverse. So yes, earlier composed reactors are rolled back.
- **H12** `compose` with `retries`: after a child failure the child's `intermediate_results` survive
  the rollback. A retry *resumes* the child, and the child treats its already **undone** steps as
  completed. Those steps are not re-run, and the retried step sees stale results.
  Suspected High finding. Must be probed.
- **H13** A composed child's own reactor-level lock is re-entrant with the parent's (same root
  owner).

### Map

- **H14** `MapStep#compensate` is a `TODO` returning `Success()`, and `MapStep` has no `undo`. So
  (a) when element K fails fail-fast, elements 0..K-1 that already succeeded are **left in place**.
  Only element K's own reactor rolls back its own steps. (b) When a step **after** the map fails,
  the map's elements are **not** undone.
- **H15** `fail_fast false`: failed elements roll back individually (inside their own executor, or
  via `executor.undo_all` in `ElementExecutor#handle_result`). Succeeded elements stay. The map
  step itself succeeds and hands a `ResultEnumerator` to the collect block / dependants.
- **H16** Fan-out map, fail-fast: elements already dispatched keep running after the first failure
  (only *not-yet-started* elements check `check_fail_fast?`). The collector fails the parent
  using the first recorded failure, and later-finishing elements are neither compensated nor
  reflected.
- **H17** Inline map: completed element contexts are not retained anywhere the parent could
  reach to undo them. Even a working `MapStep#undo` would need new storage. Fan-out elements'
  contexts are stored by id (`store_map_element_context_id`), so they *are* reachable.
- **H18** Map has no `retries` DSL. Retries are per inner step, inside each element.

### async_step / async_reactor

- **H19** A unit never enters the parent's undo stack. Parent rollback never touches it.
- **H20** A unit's failure does not fail the parent. A reader receives the `Failure` object as an
  argument and must `fail!` explicitly. That fails the **reader** step: the reader's compensate
  runs, then the parent's undos. The async_step's own `compensate`/`undo` blocks **never** run.
  This contradicts `documentation/background_and_async.md` ("they run only if the failure is
  surfaced into the parent's compensation path").
- **H21** An `async_reactor` child is an ordinary reactor. It rolls back its own steps on its own
  failure, in its worker. The parent is not affected unless a reader opts in.
- **H22** Reader wait timeout (`AsyncWaitTimeoutError`) is an `Error::Base` raised during argument
  resolution, so the parent rolls back its completed steps.

### background / worker

- **H23** `background after:/before:` serializes the undo stack. A worker-side failure undoes steps
  that ran in the **calling** process too.
- **H24** Reactor-level lock/semaphore is held from admission to the executor's `ensure`, i.e.
  **through** rollback. It is released on interrupt pause (not a park), and kept across parks.
- **H25** Step-level lock is released after the body and **re-acquired** for that step's
  compensate/undo (`around_rollback`), with `rollback_wait`. There is a window between forward
  release and rollback re-acquire.

### Interrupts / manual

- **H26** After a pause, the undo stack is persisted. A failure after `continue` undoes steps that
  completed before the pause. An interrupt validation exhausting `max_attempts` calls `undo` and
  marks the reactor failed.
- **H27** `Reactor.cancel` does not roll back. `Reactor.undo(id)` rolls back and cancels, and does
  **not** take the reactor-level lock (step-level rollback locks still apply).

### Crash / re-drive

- **H28** Checkpoint after each successful step bounds a crash re-run to at most the one step in
  flight, which can run twice (at-least-once). Its undo is recorded only if its result was
  checkpointed.
