# Research: Reliable Rollback Across Constructs

Baseline `faf90e8d` (0.8.3 + #61, #63). Findings, invariants and scenario ids refer to
[007 analysis](../007-execution-flow-analysis/analysis/). `[R: file:line]` = read in source.

Each decision: **Decision**, **Rationale**, **Alternatives considered**.

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

## R-05 · Compose retry starts a fresh child (F-02, FR-009–FR-012)

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

## R-06 · Argument and condition errors are never-started failures (F-03, F-06, FR-013–FR-015)

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

## R-07 · Any other `StandardError` rolls back and is attributed (FR-016, FR-017)

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

## R-08 · Process-level exceptions mark an inline run `aborted` (FR-018)

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
  still print `MATCH` unchanged.

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
| Compose `retries` re-run the whole child | fix | Child steps with no `undo` run again on retry. |
| Argument, condition and unknown errors roll back and carry `step_name` | fix | The failure message and `exception_class` shape change for these paths. |
| New `aborted` status | additive | Dashboards and filters gain a status. |
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
