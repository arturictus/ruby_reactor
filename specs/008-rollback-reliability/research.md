# Research: Reliable Rollback Across Constructs

Baseline `faf90e8d` (0.8.3 + #61, #63). Findings, invariants and scenario ids refer to
[007 analysis](../007-execution-flow-analysis/analysis/). `[R: file:line]` = read in source.

Each decision: **Decision**, **Rationale**, **Alternatives considered**.

**Revision 2026-09-27 (PR #65 review)**. The review reversed or narrowed four decisions. They stay
below for the record, each marked with what replaces it:

- R-05 (fresh child per compose attempt) → **superseded by R-14**: nested reactors are never retried
  as a whole.
- R-06, condition half (`ConditionError`) → **superseded by R-15**: `where`/`guard` are removed. The
  argument half (`ArgumentResolutionError`) stays.
- R-07 and R-08 (`StandardError` rolls back, every other exception aborts) → **narrowed by R-16**:
  every exception rolls back except interruptions.
- New: R-17 (what `Skipped` means for rollback), R-18 (rework of the work already on the branch).

---

## R-01 · Refactor direction: how much should the step own?

The user asked whether steps should own more of their own processing, with the reactor
coordination getting simpler. Here is where each lifecycle concern lives today:

| Concern | Today | Duplicated? |
| --- | --- | --- |
| Resolve arguments | `StepExecutor#resolve_arguments` [R: executor/step_executor.rb:438] **and** `StepWorker#resolve_arguments` [R: step_worker.rb:359] | yes, two copies, and neither attributes errors |
| Conditions (`where`/`guard`) | `StepConfig#should_run?` | no |
| Forward body | `StepConfig#call_body` (block / impl / duck-typed) | no |
| Compensate / undo dispatch (block → impl → `Skipped`) | inside `CompensationManager#compensate_step` / `#undo_step` [R: executor/compensation_manager.rb:120-205] | will be, because `StepWorker` now needs compensate (R-09) |
| Is the step's success recorded for undo? | `ResultHandler#async_unit?` special case [R: executor/result_handler.rb:137] | no, but it is construct knowledge held by the coordinator |
| What compensate/undo **mean** for composites | `ComposeStep#compensate`/`undo`, `MapStep#compensate` stub | no |
| Retry delivery (sleep / requeue / element requeue / in-job loop) | `RetryManager`, `StepWorker` | depends on the process the step runs in |
| Coordination (locks etc.) around body and rollback | `StepCoordination`, taken by the executor (005 D2) | no |

**Decision**: adopt a **bounded** version of the direction. "Step" here means the pair
`StepConfig` (the step as declared in a reactor) plus its construct class (`ComposeStep`,
`MapStep`, the user's `Step` subclass).

1. **`StepConfig` owns every per-step lifecycle operation** that is the same wherever the step
   runs: `resolve_arguments(context)`, `should_run?(context)`, `call_body` (exists),
   `call_compensate(error, arguments, context)`, `call_undo(result, arguments, context)` and
   `rollback_tracked?`. `StepExecutor`, `StepWorker` and `CompensationManager` call these and hold
   no step-kind knowledge.
2. **Construct classes own what rollback means**: `ComposeStep` (fresh child per retry, R-05) and
   `MapStep` (element replay, R-02) implement `compensate`/`undo` themselves. Async constructs
   answer `rollback_tracked? == false` (R-10).
3. **The coordinator keeps the orchestration**: dependency order, retry delivery, coordination
   acquisition, the undo stack, rollback ordering, trace, middleware events and
   `rollback_failures`. It applies one rule: a tracked success is pushed, a started-and-failed step
   is compensated, a never-started step is not compensated, and every tracked entry is undone in
   reverse order.

**Rationale**: every move in (1) removes a duplicate that the fixes would otherwise have to patch
twice. Argument attribution (F-03) is needed in both processes. Compensate dispatch is needed in
both `CompensationManager` and `StepWorker`. That is the second real use case Constitution V asks
for. (2) is where F-01 and F-02 have to be fixed anyway. The rest stays put, because it depends on
*where* a step runs, which only the coordinator knows.

**Alternatives considered**:

- *Full "step executes itself"* (`Step#execute(context)` owning retries, coordination, argument
  resolution and result handling). Rejected for this round. Retry delivery differs by process
  (inline `sleep`, worker requeue, element requeue, in-job loop, 007 INV-14). A step that retries
  itself would need to know about queues. 005 D2 deliberately makes the executor take a step's
  inline and class coordination in one fixed order. Moving it back into the step re-splits
  acquisition across two layers. None of the High fixes needs it, and it touches five executors
  (`Executor`, `StepExecutor`, `StepWorker`, `Map::ElementExecutor`, `Map::Collector`).
- *Targeted patches only*. Rejected. `resolve_arguments` and the compensate dispatch would each be
  fixed twice, and the `async_unit?` special case would stay.

---

## R-02 · Map rollback: how succeeded elements are replayed (F-01, FR-001–FR-008)

**Facts**:

- Both modes already persist every element as its own context: inline via the element executor's
  `save_context` [R: executor.rb:163], fan-out via `ElementExecutor`.
- Both modes index the element context ids per map: `store_map_element_context_id(map_id, …)`
  [R: step/map_step.rb:130] [R: map/element_executor.rb:58].
- An element's undo stack is serialized with its context [R: context.rb:173].
- `map_id` is `"#{parent_context_id}:#{step_name}"` in both modes.

**Decision**: `MapStep#undo` and `MapStep#compensate` do the same work (the compose pattern,
`alias undo compensate`):

1. Read the map's element-context index, dedupe it (a parked or retried element re-registers its
   id), and load each element context.
2. Roll back only elements with status `completed`. A `failed` element already rolled itself back
   (INV-21). A `halted` element is not rolled back (`Halt` semantics, F-07 out of scope). An element
   that never ran has no stored context.
3. Order: **descending element index**. Inline this is exact reverse completion order. Fan-out has
   no meaningful completion order, so descending index is the one deterministic choice, and it is
   documented.
4. Per element: `Executor.new(element_class, {}, element_ctx).undo_all`, then save the element
   context. Its undo stack is now empty, so a second rollback (compensate followed by a manual
   `Reactor#undo`) is a no-op.
5. Each element undo runs under that element's `map_element:<map_id>:<index>` liveness lock, taken
   with `wait: 0`. Elements are only ever rolled back after they settled (R-04), so a held lock
   means a live duplicate delivery. That element is not touched and is reported
   (`reason: :element_in_flight`).
6. An element whose context is gone (expired past `context_ttl`) is reported as a rollback failure
   (`reason: :context_unavailable`), never skipped silently.
7. Each element's own rollback failures are flattened into the map's Failure. Each entry is tagged
   with `map_step:` and `element_index:` (FR-005). The other elements still roll back.
8. The element's reactor class is read from the map step's static `mapped_reactor_class` argument,
   the same source `Map::Helpers#resolve_reactor_class` uses for inline classes. Nothing is read
   from the undo record, so the record can stay small (R-03).

`CompensationManager#compensate_step` runs inside `@context.with_step(step_config.name)`, as
`undo_step` already does. Every construct can then rely on `context.current_step` during both
rollback moments. Today `ComposeStep#compensate` only works when the caller happened to set it.

**Single-writer rule**: the map's rollback writes element contexts, the same way `ComposeStep`
writes its child. This is safe here only because it runs after every element is terminal (R-04),
from the one execution that owns the map step, under each element's liveness lock. No live element
execution can be writing at the same time.

**Rationale**: this is the compose-consistent behavior chosen in the spec clarification. No
element data enters the parent blob (FR-008, SC-006). One code path serves both modes.

**Alternatives considered**: embedding element contexts in the parent (`ContextTooLargeError` for
large maps); map-level `undo_each`/`undo_all` blocks (declined in the clarification; can be added
later as an override); parallel rollback fan-out (N jobs). The last is YAGNI. The serial loop
runs in the process that detected the failure, and its ceiling is documented: rollback time grows
linearly with the number of succeeded elements.

---

## R-03 · A fan-out map must enter the undo stack (INV-20)

**Facts**: inline, `ResultHandler#handle_success` pushes the map step like any step. In fan-out,
the collector's success branch only does `set_result` and resumes the parent
[R: map/helpers.rb:97]. The map is never pushed, so a later failure cannot undo it.

**Decision**: the collector's success branch pushes the map step on the parent's undo stack before
it resumes. The record is `{ step: map_step_config, arguments: {}, result: Success(nil) }`.
`MapStep#undo` needs neither field (R-02 §8), so the parent blob grows by a constant, not by N.
The push happens in the collector, which is the parent's owning execution at that moment. It
already writes the parent's result there.

**Rationale**: the same rule for both modes: a completed map is tracked for undo.

**Alternatives considered**: routing the collector through `ResultHandler#handle_step_result`.
That would also push the lazy `ResultEnumerator` value into the undo record, a second serialized
copy of the result. Rejected for size.

---

## R-04 · Fan-out fail-fast must settle before rollback (F-05, FR-003, INV-22)

**Facts**:

- Today the failing element triggers the collector at once [R: map/element_executor.rb:188]. The
  collector's failure branch runs before it checks completeness [R: map/collector.rb:73].
- An element that has not started yet skips itself when the fail-fast marker is set, and
  decrements the counter [R: map/element_executor.rb:155].
- The dispatcher stops dispatching new batches after the marker, and those indices are never
  counted down [R: map/dispatcher.rb:69].
- The map sweeper treats the **results hash** as the authority on completion, not the counter
  [R: map/sweeper.rb:7-12]. Skipped indices never store a result, so the sweeper keeps re-dispatching
  them after a fail-fast failure (a latent loop).

**Decision**:

1. Every index **settles** with a result slot. A skipped element stores `{ _skipped: true }` before
   it finalizes. When the dispatcher sees the fail-fast marker, it atomically claims every index it
   has not dispatched yet (one `increment_map_offset` for the rest), writes `_skipped` slots for
   them, decrements the counter by that amount, and triggers the collector if the counter reaches
   zero.
2. The collector resolves a fail-fast failure only when **no index is missing**, the same
   authority the sweeper uses. Until then it returns, and the last settling element (counter zero)
   or the sweeper re-triggers it.
3. The failure is then applied to the parent as today, and the map's compensate (R-02) runs over
   every `completed` element. That includes elements that were in flight when the marker was set.

**Rationale**: the set of rolled-back elements is always the set of elements that succeeded
(SC-003). It also removes the sweeper's re-dispatch loop for skipped indices.

**Cost**: failure latency grows to the slowest element in flight. This is documented (spec
Assumptions).

**INV-22 rescoped**: *which* elements run after a fail-fast failure still depends on scheduling.
That is inherent to fan-out. *What is left in place* is now deterministic: nothing. SC-001's
"INV-22 HOLDS" applies to the left-in-place clause, and the invariant is restated that way when it
is updated.

**Alternatives considered**: late elements roll themselves back (007 O-05-b). Rejected: it races
with the collector and wastes a whole saga run before undoing it.

---

## R-05 · Compose retry starts a fresh child (F-02, FR-009–FR-012) — SUPERSEDED by R-14

**Facts**: `ComposeStep#run` reuses `composed_contexts[step][:context]`. If that child was admitted,
it calls `resume_execution` [R: step/compose_step.rb:98]. Resume calls
`mark_completed_steps_from_context`, which marks every key of `intermediate_results` as done
[R: executor/graph_manager.rb:19], including steps the failed attempt undid. The child's retry
counters also carry over.

**Decision**: the construct decides. In `ComposeStep#run`, a stored child context whose status is
`failed` belongs to a previous **attempt** that already rolled itself back. The compose starts a
**fresh** child context and appends one entry to the parent's trace:
`{ type: :compose_attempt_discarded, step:, child_context_id:, rollback_failures: }`. That entry
keeps an incomplete rollback of an earlier attempt visible (spec edge case). Any other stored child
(running, paused, parked) is **resumed** as today (FR-011).

**FR-012 audit**: every path that resumes a stored context, and whether it can resume one after
that context rolled back:

| Entry point | Can resume after a rollback? |
| --- | --- |
| `Worker` (root / `async_reactor` child) | no. `failed`/`cancelled` are terminal and skipped [R: worker.rb:11, :66] |
| `Map::Collector` → parent `resume_execution` | no. It resumes the parent before any rollback |
| `Map::ElementExecutor` requeue (retry / park) | no. It requeues before the element rolls back |
| `Reactor#continue` (interrupt) | no. After an undo the context is `cancelled` |
| `ComposeStep#run` on a retry | **yes, today**. Fixed by this decision |

The compose retry is the only path, so no general "rolled-back marks" mechanism is added (YAGNI).
The audit table goes into the updated execution-order documentation.

**Alternatives considered**: 007 O-02-b, where rollback clears completion marks. Rejected: stale
child retry counters remain, and the undone results vanish from the dashboard. 007 O-02-c,
forbidding `retries` on compose, is breaking and loses a real use.

---

## R-06 · Argument and condition errors are never-started failures (F-03, F-06, FR-013–FR-015) — condition half SUPERSEDED by R-15

**Facts**:

- `StepExecutor#execute_step` resolves arguments outside every rescue [R: executor/step_executor.rb:83].
  A raise reaches `Executor#execute`'s `rescue StandardError`, then `build_execution_failure`'s
  "Unknown errors - don't rollback" branch [R: executor/result_handler.rb:68].
- A `where`/`guard` that raises is caught by `safe_execute_step_sync`'s `rescue StandardError` and
  is compensated like a body failure.

**Decision**:

- Add two error classes: `Error::ArgumentResolutionError` and `Error::ConditionError`. Both
  subclass `Error::Base` and carry `step`, `original_error` and the cause's `exception_class`. Both
  are non-retryable (the same inputs fail the same way).
- Add both to `CompensationManager::NEVER_STARTED_ERROR_CLASSES`.
- `StepConfig#resolve_arguments` and `StepConfig#should_run?` wrap any `StandardError` into these
  classes. `Error::ExecutionParked` and its subclasses (for example `AsyncResultPending`, the
  worker's wait on an async result) propagate unchanged, because a park is not a failure.
- `StepExecutor#execute_step` catches `ArgumentResolutionError` and sends
  `Failure(error, step_name:, reactor_name:, …)` through `ResultHandler#handle_step_result`. The
  normal failure path then gives it step attribution, no compensation of the step, and an undo of
  the completed steps.
- `StepWorker` uses the same `StepConfig` methods, so an `async_step`'s worker-side resolution
  follows the same rule (FR-015). A `background before:` hand-off runs the ordinary executor in the
  worker, so it is covered by the executor change.
- The async result-wait timeout (an `Error::Base` raised during resolution) is wrapped as well. It
  keeps its outcome (no compensation, completed steps undone, INV row "Reader's `result(:unit)`
  wait times out") and gains a step name. `exception_class` still reports the original class.

**Rationale**: one never-started rule, as for contention (INV-07). Step attribution fixes the
resolution half of F-13.

**Alternatives considered**: removing the "don't rollback" branch only (007 O-03-b). That rolls
back but still has no attribution, and still compensates on a raising condition.

---

## R-07 · Any other `StandardError` rolls back and is attributed (FR-016, FR-017) — widened by R-16

**Decision**:

- `build_execution_failure`'s `else` branch rolls back the completed steps, like the `Error::Base`
  branch.
- Both branches set `step_name` from `error.step` (the `Error::Base` attribute) or from
  `@context.current_step`, plus `reactor_name`.
- A `CompensationError` already carries `step:` [R: error/base.rb:6], so compensate-failure results
  gain `step_name` (the F-13 compensate half).

**Rationale**: the "may not be reactor-related" concern is outweighed by Constitution II. A partial
saga with no recovery path is forbidden. An unexpected error after completed work is exactly the
case rollback exists for.

**Alternatives considered**: keeping the branch and documenting it. Rejected: it violates INV-06.

---

## R-08 · Process-level exceptions mark an inline run `aborted` (FR-018) — narrowed by R-16

**Facts**:

- A non-`StandardError` passes through `Executor#execute`'s rescues. Its `ensure` persists the
  context with status `running` [R: executor.rb:163].
- The reactor `Sweeper` re-enqueues any top-level context that is `running` with no `async:` lock
  [R: sweeper.rb:51-54]. Inline runs never hold that lock, so a sweeper would silently resume the
  run forward in a worker.

**Decision**:

- `Executor#execute` and `#resume_execution` add `rescue Exception` after the existing rescues.
  For an execution in the caller's process (`!@context.inline_async_execution`), the rescue sets
  status `:aborted`, runs no rollback code, and re-raises the same exception object. The existing
  `ensure` persists it. The save is best effort, since the process may be out of memory.
- Each nested inline executor (compose child) marks its own context the same way on the way out.
- Worker executions are unchanged. `Sidekiq::Shutdown` and similar leave `running`, and the job is
  redelivered (007 INV-32).
- `aborted` is added to the dashboard's known statuses (`determine_status`, web API and UI filters)
  so it is visible (Constitution IV).
- The `Sweeper` only acts on `running`, so it leaves aborted runs alone.
- `Reactor#undo` needs no change: it runs `undo_all` over the persisted undo stack.

**Rationale**: running user undo code during a signal or out-of-memory condition is unsafe.
Recording the state gives the run a recovery path that is visible and explicit (Constitution II),
instead of a silent forward resume.

**Alternatives considered**: rolling back on `Exception` (unsafe). Leaving the run `running`: the
sweeper then resumes forward work the caller believes has failed.

---

## R-09 · `async_step` unit-local compensate (F-04, FR-019–FR-021)

**Decision**:

- In `StepWorker#run_step`, after the retry loop, compensate the unit when the final result is a
  `Failure` whose error is not never-started. Never-started means: not in
  `NEVER_STARTED_ERROR_CLASSES` and not an `InputValidationError`, the same classification the
  executor uses, where validation failures are never compensated.
- The compensate uses `CompensationManager#compensate`. That is the existing private
  `compensate_step` made public. It keeps the coordinated re-take of the unit's own
  locks/semaphores, the middleware events and the rollback-failure recording, all run on the unit's
  in-memory context.
- `StepWorker` never saves the parent context (single-writer rule). The outcome is written to the
  unit's own record as `compensation: { status:, rollback_failures: }`. The unit's `result`
  remains the body's Failure.
- A failed attempt that is then retried is not compensated, because the compensate runs once after
  the loop.
- A `Halt`, `Skipped` or `Success` result is never compensated.

**Reader interaction is unchanged**: a reader that surfaces the failure is compensated, and the
parent's steps are undone. The unit is never on the parent's undo stack, so it is not compensated
twice (acceptance US4-3).

**Definition time (FR-020)**:

- An inline `undo` block inside `async_step` raises `Error::ValidationError`. The message names the
  step and points to the reader's `compensate` or to an `async_reactor` child.
- **Refinement recorded against the spec**: an `undo` inherited from a *step class* used with
  `async_step` emits a definition-time **warning**, not an error. The warning goes through the
  existing `StepBuilder#warn_deprecation` channel, once per site. The same class is legitimately
  reused by ordinary `step`s, where its `undo` does run. Rejecting it would force authors to fork
  a class only to delete a method. The spec's FR-020 and US4-4 are updated to match.

**Alternatives considered**: parent-driven compensate on a surfaced failure, and rejecting all
hooks. Both were declined in the clarification.

---

## R-10 · Async units say "not tracked for undo" themselves (FR-022, FR-023)

**Decision**: `StepConfig#rollback_tracked?` returns `!async_dispatch?`. `ResultHandler#handle_success`
pushes a success only when `step_config.rollback_tracked?`. The `async_unit?` helper is deleted.
`AsyncReactorBuilder`'s config answers the same way through `async_dispatch`.

**Rationale**: the coordinator asks the step instead of knowing its kind. There is no behavior
change: independence (INV-25) is kept.

**Alternatives considered**: pushing async units and giving them a no-op `undo`. That emits
`start_undo`/`complete_undo` events for work that was never undoable, and re-takes the unit's locks
for nothing (`coordinated_rollback`). Rejected.

---

## R-11 · Test strategy (FR-027, SC-001–SC-006)

**Decision**:

- **New specs** under `spec/ruby_reactor/rollback/`, one file per finding group:
  `map_rollback_spec.rb`, `map_fan_out_settle_spec.rb`, `compose_retry_spec.rb`,
  `failure_rollback_spec.rb`, `aborted_execution_spec.rb`, `async_step_compensate_spec.rb`. They
  run against real Redis. Fan-out uses Sidekiq fake mode plus
  `RubyReactor::RSpec::SidekiqHelpers.drain_async_jobs`. `Sidekiq::Testing.inline!` is not allowed
  on async paths (Constitution III).
- **Sequence assertions**: each example records `run:`, `compensate:` and `undo:` events and asserts
  the exact order, mirroring the 007 probes.
- **SC-003**: one example drains element jobs in a shuffled order 100 times (seeded) and asserts
  that no completed element is left with a non-empty undo stack.
- **SC-006**: a 10,000-element inline map example, tagged `:slow` and excluded from the default
  run. It runs in the quickstart and before release.
- **Tighten** `spec/ruby_reactor/dsl/async_step_spec.rb:111` so it asserts that the unit's own
  `compensate` ran.
- **SC-002 regression**: re-run the 007 harness (`specs/007-execution-flow-analysis/evidence/run.rb`).
  Only the `expected:` sequences of in-scope scenarios are updated: S-map-01, 03, 04, 04b, 06, 07,
  08, S-compose-05, 05b, S-plain-07, S-edge-03, 04, S-async-02, 07. Every other scenario must
  still print `MATCH` unchanged. The 2026-09-27 revision changes S-compose-05/05b, S-edge-03/04 again
  and adds S-edge-03b (contracts/rollback-semantics.md §3).

---

## R-12 · Versioning and compatibility (FR-026)

These changes are intentional and visible to users. Each one gets a CHANGELOG entry. Breaking ones
use `feat!`/`fix!` commits with a `BREAKING CHANGE:` footer and a migration note.

| Change | Kind | Migration note |
| --- | --- | --- |
| Element-step `undo` blocks now run when a map is rolled back | breaking (behavior) | Review element `undo`s: they now run on map failure and on later failures. Make them idempotent. |
| `async_step` `compensate` now runs in the unit's job on final failure | breaking (behavior) | The block now runs, possibly with no reader. Move reader-only cleanup into the reader. |
| Inline `undo` inside `async_step` raises at definition time | breaking (API) | Move it to the reader's `compensate` or use `async_reactor`. |
| Class `undo` on an `async_step` class is warned | additive | none |
| `retries` on `compose`/`async_reactor` raises at definition time (R-14) | breaking (API) | Declare `retries` on the child reactor's steps. The child retries them itself. |
| `where`/`guard` removed; declaring them raises at definition time (R-15) | breaking (API) | Return `Skipped` (or call `skip!`) from the step body. A `background before:` hand-off at that step now always fires. |
| Exceptions that are not `StandardError` (except interruptions) fail the step and roll back (R-16) | breaking (behavior) | They no longer propagate out of `Reactor.run`. Test assertion errors raised inside a step body now surface as the step's failure. |
| Argument and unknown errors roll back and carry `step_name` | fix | The failure message and `exception_class` shape change for these paths. |
| New `aborted` status, only for interruptions (R-16) | additive | Dashboards and filters gain a status. |
| `rollback_failures` entries may carry `map_step`/`element_index` and new reasons | additive | none |

The project is 0.x. Release-please picks the number from the commit types. Constitution V only
requires that the breaking items are marked as breaking and carry notes.

---

## R-13 · Documentation to correct (FR-024)

These come from the 007 audit rows tied to in-scope findings:

- **README.md**: lines 16, 25, 35, 545-550, 1309 and 1398, plus the Compensation section.
- **documentation/data_pipelines.md**: 167 (map rollback, fail-fast settle latency).
- **documentation/composition.md**: 184 (compose retry = fresh child).
- **documentation/background_and_async.md**: 279-292 (unit-local compensate, `undo` rejected).
- **documentation/core_concepts.md**: 321-331 (rollback rule and construct table).
- **documentation/DAG.md**: 228-240.
- **documentation/locks_and_semaphores.md**: 777-778 (never-started now includes argument and
  condition errors).
- **documentation/interrupts.md**: 155-157. Mention `aborted` next to manual undo.
- **The 007 analysis**: execution-order.md (failure-kinds table, R-05 audit table) and
  invariants.md (statuses after the fix). Updated so the 007 report stays a correct reference.

**Added by the 2026-09-27 revision**:

- **documentation/composition.md**: the inline example's compose-level `retries` (line ~33), point 5
  "Retries re-run the whole child" (~185-194), and the `retries` row of the compose vs
  `async_reactor` table (~205).
- **documentation/background_and_async.md**: ~159, "A step skipped by a `where`/`guard` never
  triggers the hand-off".
- **documentation/core_concepts.md**: the Rollback Rule (drop `ConditionError`, define `Skipped` per
  R-17, name the interruptions per R-16) and "Skipping a single step".
- **documentation/DAG.md**: ~248, "a `where` condition that raises".
- **documentation/interrupts.md**: ~165, `aborted` only for interruptions.
- **documentation/locks_and_semaphores.md**: ~780, drop `where`/`guard` from the never-started list.
- **README.md**: ~857 (`Skipped` rollback meaning) and ~1432 (drop `ConditionError`, add
  non-standard exceptions).
- **CHANGELOG.md**: rewrite the 008 entries that describe compose retries, `ConditionError` and
  `aborted` for every non-standard exception.
- **007 invariants.md / execution-order.md**: INV-06, INV-07, INV-13 rows; failure-kinds table.

---

## R-14 · Nested reactors are never retried as a whole (FR-009–FR-012, review 2026-09-27)

**Facts**:

- `ComposeBuilder` and `AsyncReactorBuilder` include `Dsl::Retryable`, so `retries` inside their
  block sets the construct's own `retry_config` [R: dsl/compose_builder.rb:7, dsl/async_reactor_builder.rb:13].
- On a compose, that retries the whole child. R-05 then had to start a fresh child per attempt and
  record `compose_attempt_discarded` [R: step/compose_step.rb `discard_failed_attempt`].
- On an `async_reactor`, it retries the dispatching step. That step validates, runs the deadlock
  guard, then enqueues or, in inline mode, runs the whole child [R: step/async_reactor_step.rb:60].
- The documentation shows compose-level `retries` inside an inline compose block as if it
  configured the child's steps (documentation/composition.md:33). It does not.
- Existing removed-DSL pattern: a stub method raising `Error::DeprecatedDslError` with the
  replacement (`ComposeBuilder#async`, `StepBuilder#async`).

**Decision**:

- `ComposeBuilder` and `AsyncReactorBuilder` stop including `Retryable`. Each gets a `retries(*)`
  stub that raises `Error::DeprecatedDslError` at class definition, naming the step and saying to
  declare `retries` on the child reactor's own steps. Their step configs are built without a
  `retry_config`, so they default to one attempt (the existing default).
- Delete `ComposeStep#discard_failed_attempt`, `#attempt_rollback_failures` and the
  `compose_attempt_discarded` trace entry.
- No replacement guard in `ComposeStep#run`. R-05's audit showed the compose retry was the only
  path that re-ran a stored child after it rolled back. With no compose retry, that path is gone,
  and a park or redelivery resumes a child that is still `running` (FR-011, unchanged).

**Rationale**: the child already owns its steps' retry policies (#61, step-scoped retries). A
parent-level retry is a second, conflicting retry layer, and it was the root cause of F-02. Removing
it closes F-02 with less code than R-05 needed (007 option O-02-c).

**Alternatives considered**: keep R-05 (fresh child per attempt). Rejected by the review: the parent
must never retry the child as a whole. Silently ignoring `retries` on a compose: rejected, because it
hides the migration.

---

## R-15 · Remove `where`/`guard` (FR-014, US6, review 2026-09-27)

**Facts**:

- `where`/`guard` are two `StepBuilder` methods feeding `StepConfig#should_run?` [R: dsl/step_builder.rb:81-87, 463].
  `InterruptBuilder` inherits them. The compose, map and async_reactor builders pass empty
  `conditions: []`, `guards: []`.
- `should_run?` is consulted in four places: `StepExecutor#execute_step_sync`,
  `#execute_step_sync_without_result_handling`, `#handoff_at?`, and `StepWorker#run_step`.
- A false condition returns `Success(nil)` before arguments, validation or coordination. The same
  intent is served by returning `Skipped` from the body, which is documented and tested.
- Tests that exercise conditions: `step_contract_enforcement_spec.rb:297`,
  `step_retries/class_policy_spec.rb:112`, `step_coordination/lock_spec.rb:153` (+ fixture
  `GuardedLockedChargeReactor`), `step_coordination/single_site_spec.rb:289` (+ `GuardedAsyncReactor`,
  `ASYNC_GUARD_FLAG`), `dsl/reactor_background_spec.rb:118` (+ `BackgroundSkippedTriggerReactor`),
  `rollback/failure_rollback_spec.rb` (condition examples), 007 probe S-edge-04.

**Decision**:

- `StepBuilder#where` and `#guard` become `DeprecatedDslError` stubs that name the step and say to
  return `Skipped` (or call `skip!`) from the step body. Remove `@conditions`/`@guards`, the
  `conditions`/`guards` config keys and attributes, and `StepConfig#should_run?`.
- Remove the four `should_run?` call sites. A `background` hand-off fires whenever its step is
  reached.
- Delete `Error::ConditionError`, its `NEVER_STARTED_ERROR_CLASSES` entry, and the
  `ConditionError` branches in `StepExecutor`, `StepWorker` and `ResultHandler#never_started_wrapper?`.
- Delete the tests listed above that only test conditions, with their fixtures. Add one spec that
  each of `step`, `async_step` and `interrupt` rejects `where` and `guard`.
- 007 probe S-edge-04 becomes "a step declaring `where` is rejected at definition time".

**Rationale**: a second skip mechanism with its own failure rules (F-06) is the stale code the review
named. `Skipped` covers the use. Removing it deletes a never-started category instead of adding one.

**Alternatives considered**: deprecate with a warning for one release. Rejected: the project is 0.x,
earlier removed DSL (`async`, `retry_defaults`) was removed the same way, and the review asked for
full removal.

---

## R-16 · Every exception rolls back except interruptions (FR-013, FR-016, FR-018, FR-028, review 2026-09-27)

**Facts** (Ruby 3.4.8, timeout 0.5.0):

- Exceptions that are not `StandardError` and can come from reactor code: `NotImplementedError`
  (the library's own `Step#run` default raises it), `LoadError`/`SyntaxError` (lazily loaded code),
  `SystemStackError` (runaway recursion), `SecurityError`, any `class X < Exception`, and test
  assertion errors (`RSpec::Expectations::ExpectationNotMetError`, `Minitest::Assertion`). Today all
  of them skip rollback and mark the run `aborted`.
- Exceptions that come from outside reactor code: `SignalException` (including `Interrupt` and
  `Sidekiq::Shutdown`), `SystemExit`, `NoMemoryError`, and `Timeout::ExitException`. The last one is
  what an enclosing `Timeout.timeout` raises into the running thread. Probed: rescuing it inside the
  block means the caller's `Timeout.timeout` never raises (`:swallowed`).
- `rescue` accepts a module whose `self.===` decides the match (probed: `NotImplementedError`,
  `SystemStackError` and custom `Exception` subclasses are rescued, `Interrupt` and `SystemExit`
  escape).
- User code runs behind these `rescue StandardError` sites: `StepConfig#resolve_arguments`
  (sources, transforms), `StepExecutor#safe_execute_step_sync` (body, validation),
  `CompensationManager#compensate_step`/`#undo_step`, `Executor#execute`/`#resume_execution`,
  `StepWorker#perform` and its body call, `StepCoordination.resolve_key` (key procs), and the map
  collect block (`MapStep#process_results`, `Map::Collector`, `Map::Helpers`). The other
  `rescue StandardError` sites guard infrastructure (release, publish, logging, storage) and stay.
- `CompensationManager#rollback_completed_steps` clears the undo stack only after the whole loop
  [R: executor/compensation_manager.rb:78-87]. An interruption mid-rollback leaves the stack whole,
  so a manual undo would undo the already-undone steps again.

**Decision**:

- Add `RubyReactor::Error::Rescuable`, a module whose `self.===` matches any `Exception` that is not
  an interruption. The interruptions are `SignalException`, `SystemExit`, `NoMemoryError` and
  `Timeout::ExitException` (looked up when first needed, since `timeout` may load later).
- Replace `rescue StandardError` with `rescue Error::Rescuable` at the user-code sites listed above.
  The existing specific rescues (contention, parks, validation) stay first and are unchanged.
- `Executor#execute`/`#resume_execution` keep `rescue Exception` after the `Rescuable` rescue. Only
  interruptions reach it now, and it marks the run `aborted` as R-08 decided.
- `rollback_completed_steps` removes each entry from the undo stack once its undo has returned. An
  interruption during a rollback therefore leaves exactly the entries that were not undone yet
  (the interrupted one included) for a manual undo.
- `aborted_execution_spec.rb` triggers with `Interrupt` instead of a custom `Exception`. The custom
  `Exception`, `NotImplementedError` and `SystemStackError` cases join `failure_rollback_spec.rb`
  as rollbacks. New examples: an enclosing `Timeout.timeout` still fires, and an interruption
  during rollback leaves only the remaining entries.
- 007 probe S-edge-03 (custom `Exception`) becomes a rollback, `run:a run:b compensate:b undo:a =>
  failure(b)`. A new S-edge-03b (`Interrupt`) keeps the `aborted` evidence.

**Rationale**: the review's rule is that every error raised by reactor code rolls back, unless it is
certain the error comes from outside that code. The interruption set is exactly the exceptions Ruby
or its host raises into running code from outside. Everything else is the reactor's own failure.
Keeping the enclosing-timeout exception out avoids breaking the caller's timeouts.

**Alternatives considered**:

- Rescue `Exception` everywhere and roll back even on signals. Rejected: rollback during shutdown or
  out-of-memory is unsafe (R-08), and it swallows the caller's `Timeout`.
- An allow-list of rescued classes (`StandardError`, `ScriptError`, ...). Rejected: it misses custom
  `Exception` subclasses, which the review explicitly wants rolled back.
- Let test assertion errors propagate. Rejected: they are raised by code inside a step body, so by
  the review's rule they are that step's failure. The test still fails, because its assertion on the
  result sees the failure.

---

## R-17 · What `Skipped` means for rollback (FR-029) — SUPERSEDED by R-19

**Facts**: `Skipped` is a `Success` whose step is not pushed on the undo stack [R: lib/ruby_reactor.rb:106-110].
`ResultHandler` checks `skipped?` before pushing. `Step#undo`/`#compensate` default to returning
`Skipped()`, which is a different use (nothing to roll back).

**Decision**: no code change. `Skipped` keeps meaning "this run caused no effect for this step", so
it is never undone or compensated. The documentation says so, and says that a step which finds its
effect already in place and owned by this workflow (for example, a redelivered run whose earlier
attempt created it) returns `Success(value)`, so its `undo` runs on rollback.

**Rationale**: the library cannot tell who created an effect that already exists. The author can.
Option A from the spec clarification: no breaking change, and one sentence resolves the ambiguity.

**Alternatives considered**: undo `Skipped` steps (option B, breaks every `undo` written for "my
effect happened"); a second "already done" result (option C, new public API for what `Success`
already expresses).

---

## R-18 · Reworking the work already on the branch

The first implementation (tasks T001–T0xx, all done) built R-05, the condition half of R-06, and
R-08 for every non-standard exception. What changes:

| Area | Files | Action |
| --- | --- | --- |
| Compose retry (R-14) | `lib/ruby_reactor/step/compose_step.rb`, `dsl/compose_builder.rb`, `dsl/async_reactor_builder.rb` | delete fresh-child code, add `retries` stubs |
| | `spec/ruby_reactor/rollback/compose_retry_spec.rb` | rewrite: rejection, child step retries, no re-run, park/resume |
| | `spec/ruby_reactor/step_retries/declaration_spec.rb:69-84` | the two "validates `retries` in compose/async_reactor block" examples become rejection examples |
| | `demo_app/.../compose_retry_demo_reactor.rb` (+ spec, rake) | child step declares `retries`; no compose-level retries |
| | 007 probes S-compose-05, 05b | rejection, and child-step retry sequence |
| Conditions (R-15) | `dsl/step_builder.rb`, `dsl/interrupt_builder.rb`, `dsl/{compose,map,async_reactor}_builder.rb`, `executor/step_executor.rb`, `step_worker.rb`, `executor/compensation_manager.rb`, `executor/result_handler.rb`, `error/condition_error.rb` (delete), `lib/ruby_reactor.rb` (require) | remove |
| | specs and fixtures in R-15 | delete; add rejection spec |
| Exceptions (R-16) | `error/rescuable.rb` (new), the user-code rescue sites, `executor.rb`, `executor/compensation_manager.rb` | widen; pop per entry |
| | `spec/ruby_reactor/rollback/aborted_execution_spec.rb`, `failure_rollback_spec.rb` | retarget |
| | `demo_app/.../argument_failure_demo_reactor.rb` (+ spec, rake) | add a non-standard exception case |
| Docs | R-13 additions, CHANGELOG | rewrite |

---

## R-19 · `Skipped` is only an instrumentation mark (FR-029, FR-030, review 2026-09-27)

**Facts**: a body's `Skipped` differed from `Success` in three places: `ResultHandler#handle_skipped`
did not enroll it for undo, `StepExecutor#handoff_after?` did not hand off after it, and
`StepCoordination#plain_success?` did not mark a period bucket for it. `handoff_after?` also let a
`Halt` through (probed: `background after: :x` + `Halt` returned a `DispatchResult`).

**Decision** (the review's rule, "`Skipped` is in every effect the same as `Success`"):
`handle_skipped` calls `handle_success` and only adds the trace entry; `handoff_after?` excludes
`Halt` instead of `Skipped`; the period mark treats `Skipped` like `Success`. The library's own
skips (period, ordered lock) come from gates outside the period mark, so they never mark a bucket,
but they are enrolled for undo like any `Skipped`.

## R-20 · Cap a stored failure's backtrace (FR-031)

A real stack overflow stored a ~12,000-frame backtrace (context 2.4 MB). `Failure` keeps the first
100 frames plus a `"... N more frames"` line (probed: 23 KB).
