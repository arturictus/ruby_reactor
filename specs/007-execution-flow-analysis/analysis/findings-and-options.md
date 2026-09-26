# Findings, Documentation Audit & Options

Severity (research D7): **High** = completed side effects silently left in place, work that can
run twice, or rollback of work that never ran. **Medium** = defensible but differs by
mode/nesting, or contradicts documentation. **Low** = clarity/observability; predictable, but the
DSL or telemetry gives no hint.

All options are **proposals pending later analysis**, not decisions.

- [1. Findings](#1-findings)
- [2. Documentation audit](#2-documentation-audit)
- [3. Options](#3-options) (includes [the map `compensate_all` / `compensate_each` evaluation](#o-01-evaluation-compensate_all-vs-compensate_each))

---

## 1. Findings

### F-01 · High · Map elements that already succeeded are never rolled back

- **Resolved by 008**: map rollback replays every completed element's undo stack, highest index first, in inline and fan-out mode (008 R-02, R-03). See `spec/ruby_reactor/rollback/map_rollback_spec.rb`.

- **Scenarios**: [O: S-map-01] [O: S-map-03] [O: S-map-04] [O: S-map-04b] [O: S-map-06] [O: S-map-07] [O: S-map-08]
- **Reader expects**: a map is "a step that happens N times". When the map fails, or a later step
  fails, the elements that completed are rolled back the way a `compose` child is (README: "automatic
  rollback of completed steps").
- **Actual**: only the **failed** element rolls back its own steps. Succeeded elements keep
  their effects in both cases:
  1. **The map fails** (fail_fast): elements before the failure are left in place, including their
     nested composes (S-map-08). `MapStep#compensate` is a stub
     (`# TODO: Implement compensation for map steps` → `Success()`)
     [R: lib/ruby_reactor/step/map_step.rb:29-31].
  2. **A later step fails**: every element is left in place. Inline, the map step's `undo` is the
     base `Skipped` [R: lib/ruby_reactor/step.rb:57], and the element contexts are discarded. Fan-out,
     the collector never even pushes the map step on the undo stack
     [R: lib/ruby_reactor/map/helpers.rb:97].
  3. There is no DSL surface to fix it locally: `MapBuilder` builds `compensate_block: nil,
     undo_block: nil` [R: lib/ruby_reactor/dsl/map_builder.rb:130-131]. `undo` blocks written on the
     element reactor's steps run only when **that element** fails.
- **Rollback reporting**: `rollback_failures` is empty. Nothing was attempted, so nothing is reported.
- **Doc conflict**: README.md:16, :25, :1309, :1398; documentation/data_pipelines.md:167;
  documentation/DAG.md:228-240 (see §2).
- **Related**: INV-19, INV-20 (both VIOLATED, no spec coverage).

### F-02 · High · `compose` with `retries` resumes a child whose earlier steps were already undone

- **Resolved by 008**: a compose retry after a failed attempt starts a fresh child (008 R-05). See `spec/ruby_reactor/rollback/compose_retry_spec.rb`.

- **Scenarios**: [O: S-compose-05] [O: S-compose-05b]
- **Reader expects**: `retries` on a compose retries the sub-saga. After a failed attempt that
  rolled the child back, the next attempt starts the child again.
- **Actual**: the failed attempt undoes `c1` (its effect is gone). The retry reuses the same child
  context and `resume_execution`s it. `c1`'s result is still in `intermediate_results`, so `c1` is
  treated as completed and **not re-run**. `c2` then runs against the result of an undone step, and
  the reactor returns `c1`'s stale value. If a later parent step fails, only `c2` is undone
  (S-compose-05b). The child ends "successful" with its first step's side effect missing.
  [R: lib/ruby_reactor/step/compose_step.rb:97] [R: lib/ruby_reactor/executor/graph_manager.rb (mark_completed_steps_from_context)]
- **Doc conflict**: documentation/composition.md:184 ("can be configured with different retry
  strategies") is silent on this.
- **Related**: INV-13 (VIOLATED, no coverage).

### F-03 · High · Some failures skip rollback entirely

- **Resolved by 008**: argument, condition and unknown `StandardError`s roll back and carry `step_name`; a non-`StandardError` marks a caller-process run `aborted` for a manual undo (008 R-06–R-08). See `spec/ruby_reactor/rollback/failure_rollback_spec.rb`, `aborted_execution_spec.rb`.

- **Scenarios**: [O: S-plain-07] [O: S-edge-03]
- **Reader expects**: "if any part of your workflow fails … automatically triggers compensation"
  (README.md:16).
- **Actual**: two failure classes roll back nothing:
  1. A `StandardError` raised while **resolving a step's arguments** (a `transform:` lambda, a
     dynamic source, a `result(:x, path)` that raises). Resolution runs outside the step's rescue
     [R: lib/ruby_reactor/executor/step_executor.rb:83]. The error reaches
     `ResultHandler#build_execution_failure`, whose non-`Error::Base` branch is
     "Unknown errors - don't rollback" [R: lib/ruby_reactor/executor/result_handler.rb:68-70].
     The result is `Failure("Execution failed: …")` with no step name and an empty `rollback_failures`.
  2. A non-`StandardError` exception in a body (e.g. `Timeout::ExitException`-like, custom
     `Exception` subclasses) propagates to the caller with no rollback. A worker would redeliver
     (INV-32); an inline caller gets partial effects.
- **Related**: INV-06 (VIOLATED, no coverage).

### F-04 · High · An `async_step`'s own `compensate` / `undo` never run; the docs say they do

- **Resolved by 008**: an `async_step` unit compensates itself once, in its own job, after its final attempt; an inline `undo` is rejected, a class `undo` warned (008 R-09). See `spec/ruby_reactor/rollback/async_step_compensate_spec.rb`.

- **Scenarios**: [O: S-async-02] [O: S-async-07]
- **Reader expects** (documentation/background_and_async.md:291-292): "`compensate` / `undo` blocks
  declared on an `async_step` still register; they run only if the failure is surfaced into the
  parent's compensation path this way".
- **Actual**: when a reader surfaces the unit's failure, the **reader** is compensated and the
  parent's steps are undone, but `compensate:u` never runs. `StepWorker` never invokes rollback
  hooks [R: lib/ruby_reactor/step_worker.rb:240-393], and the parent never pushed the unit
  [R: lib/ruby_reactor/executor/result_handler.rb:137]. The blocks are accepted by the DSL and are
  dead code. The same holds when the unit exhausts its retries (S-async-07).
- **Coverage gap**: [T: spec/ruby_reactor/dsl/async_step_spec.rb:111] asserts only that `:setup`
  is compensated, so it passes either way.
- **Related**: INV-24, INV-29.

### F-05 · Medium · Fan-out fail-fast leaves a scheduling-dependent set of elements in place

- **Resolved by 008**: a fail-fast fan-out map settles every index before applying its failure, and every completed element is rolled back, so nothing is left in place whatever the job order (008 R-04). See `spec/ruby_reactor/rollback/map_fan_out_settle_spec.rb`.

- **Scenarios**: [O: S-map-04] vs [O: S-map-04b]
- **Actual**: the fail-fast marker is checked only when an element job **starts**
  [R: lib/ruby_reactor/map/element_executor.rb:61, :145]. Elements that started, or finished,
  before the failing element are kept. Later ones skip. Same input, different job order →
  different leftovers (elements 0, 1 vs element 3). Combined with F-01, the leftover set is
  neither rolled back nor predictable.
- **Doc conflict**: documentation/data_pipelines.md:167 ("fails immediately").
- **Related**: INV-22 (CONDITIONAL).

### F-06 · Medium · A raising `where`/`guard` compensates a step whose body never ran

- **Resolved by 008**: a raising `where`/`guard` is a never-started `ConditionError`: not compensated, not retried (008 R-06).

- **Scenario**: [O: S-edge-04]
- **Actual**: conditions are evaluated inside the step's rescue
  [R: lib/ruby_reactor/executor/step_executor.rb:342]. The resulting `Failure` goes through
  normal failure handling, which compensates the step. Contention, key errors and argument
  validation are all correctly treated as never-started (S-lock-03, S-edge-05). This path isn't.
- **Doc conflict**: documentation/locks_and_semaphores.md:778 states the never-started
  principle (for contention only).
- **Related**: INV-07 (CONDITIONAL).

### F-07 · Medium · `Halt` means different things at different nesting levels

- **Scenarios**: [O: S-compose-08] vs [O: S-map-11]
- **Actual**: a map element's `Halt` halts the parent. A composed child's `Halt` is converted to
  `Success(nil)` [R: lib/ruby_reactor/step/compose_step.rb:106-114], and the parent **continues**
  with `nil` as the compose result.
- **Doc conflict**: documentation/core_concepts.md:277 and documentation/composition.md:195
  describe Halt and compose without this case.
- **Related**: INV-09 (VIOLATED).

### F-08 · Medium · `Reactor.undo(id)` runs outside the reactor-level lock

- **Scenario**: [O: S-intr-04]
- **Actual**: `Reactor#undo` builds an executor and calls `undo_all` directly
  [R: lib/ruby_reactor/reactor.rb:188-192]. It never acquires the reactor's `with_lock` /
  `with_semaphore`. The undo succeeded while another owner held `rk`. Step-level locks *are*
  re-taken, so only reactor-level exclusion is lost.
- **Doc conflict**: documentation/interrupts.md:150-157 (Cancellation & Undo) is silent on
  locking.
- **Related**: INV-35 (CONDITIONAL).

### F-09 · Medium · Dispatched units run after their dispatcher rolled back, including units of a failed map element

- **Scenarios**: [O: S-async-03] [O: S-async-06] [O: S-async-08] [O: S-map-12]
- **Actual**: parent rollback neither cancels nor undoes an `async_step`/`async_reactor`
  (documented independence). A queued unit then performs its side effect **after** the rollback.
  For an `async_step` inside a fan-out map element the unit escapes even the element: the element
  rolled back, the unit still ran (S-map-12). This contradicts `ElementExecutor`'s stated intent
  that async work "must execute inline here" [R: lib/ruby_reactor/map/element_executor.rb:51-55],
  because `async_step` dispatch is deliberately not gated on that flag
  [R: lib/ruby_reactor/executor/async_step_dispatch.rb:20-24].
- **Doc conflict**: README.md:545-550 and documentation/background_and_async.md:285-289 explain
  independence, but not that a unit can run *after* its dispatcher's rollback.
- **Related**: INV-27 (VIOLATED).

### F-10 · Medium · Rollback coverage of composite constructs is asymmetric and invisible in the DSL

- **Scenarios**: [O: S-compose-02] vs [O: S-map-03] vs [O: S-async-06]
- **Actual**: three constructs that all "run more steps" differ completely, and nothing in the
  reactor definition shows it:

  | Construct | Child/element/unit completed, later parent failure | Child/element/unit fails |
  |---|---|---|
  | `compose` | undone (full child replay) | child self-rolls back, parent rolls back |
  | `map` | **left in place** | failed element self-rolls back; siblings left |
  | `async_step` | left in place | own hooks never run; parent unaffected unless a reader opts in |
  | `async_reactor` | left in place | child self-rolls back; parent unaffected unless a reader opts in |

- **Resolved by 008** (the table rebuilt from 008's rollback contract, RS §2): one rule for every
  construct, and each construct's own `compensate`/`undo` decides what rollback means for it. The
  coordinator asks the step whether a success is tracked for undo (`rollback_tracked?`).

  | Construct | Child/element/unit completed, later parent failure | Child/element/unit fails |
  |---|---|---|
  | `compose` | undone (full child replay) | child self-rolls back, parent rolls back; a retry starts a fresh child |
  | `map` | **undone** (every completed element, highest index first) | failed element self-rolls back; completed siblings undone, then the parent rolls back |
  | `async_step` | left in place (independent by design, documented) | the unit compensates itself once, in its own job; parent unaffected unless a reader opts in |
  | `async_reactor` | left in place (independent by design, documented) | child self-rolls back; parent unaffected unless a reader opts in |

  `compose`, `map` and the async macros accept no `compensate`/`undo` declaration of their own, so
  a reader cannot tell from the class body what will be rolled back. This is the user's
  "does the DSL help clearly understand" question.
- **Related**: F-01, F-04, INV-16, INV-19, INV-20, INV-25.

### F-11 · Low · Step-lock gap between the forward release and the rollback re-acquire

- **Scenarios**: [O: S-lock-02] [O: S-lock-05]
- **Actual**: a step lock is held for the body only. Rollback re-takes it (documented) but another
  execution can hold it in between and change the protected resource. The undo is serialized with
  that execution, but it runs against a possibly changed resource. It can also be skipped (reported)
  when the key stays busy past `rollback_wait`.
- **Doc**: documentation/locks_and_semaphores.md:852-866 documents the re-take, not the gap.
- **Related**: INV-35, INV-36.

### F-12 · Low · `async_step` retries are invisible to middleware

- **Scenario**: [O: S-async-07]. There is no `retry_attempt` event, unlike every other retry path
  [R: lib/ruby_reactor/step_worker.rb:275-289]. **Related**: INV-29.

### F-13 · Low · Failures without step attribution after rollback

- **Resolved by 008**: argument, condition, unknown and compensation failures all carry `step_name` and `reactor_name` (008 R-06, R-07).

- **Scenarios**: [O: S-plain-03] (compensate fails → `CompensationError` → "Execution error: …",
  no `step_name`), [O: S-plain-07] (argument resolution → no `step_name`).
  [R: lib/ruby_reactor/executor/result_handler.rb:64-70]. Violates Constitution IV ("every failure
  MUST carry … step name").

### F-14 · Low · Dead, contradictory map collection default

- `Map::Helpers#apply_collect_block` ("Default behavior: fail if any failure")
  [R: lib/ruby_reactor/map/helpers.rb:36-52] is shadowed by `Collector.apply_collect_block`
  ("Default behavior: Return Success(Enumerator)") [R: lib/ruby_reactor/map/collector.rb:108-126].
  Only the latter is called. A reader of `helpers.rb` gets the wrong semantics.

### F-15 · Low · Reactor-level `lock_released` names a different key than `lock_acquired`

- **Scenario**: [O: S-lock-01] (`lock_acquired:rk`, `lock_released:lock:rk`). Known and pinned by
  [T: spec/ruby_reactor/step_coordination/attribution_spec.rb:41]. **Related**: INV-38.

### F-16 · Low · Interrupt docs say "cancelled"; exhausted payload validation marks the run `failed`

- **Scenario**: [O: S-intr-02] ends `failure(approval)`, status `failed`
  [R: lib/ruby_reactor/reactor.rb:411-415]. documentation/interrupts.md:40, :62, :141 say the
  reactor is "cancelled and compensated". The rollback itself is as documented.

---

## 2. Documentation audit

Claims about ordering or rollback in README.md and `./documentation`. **CONFIRMED** rows are
listed too, so the audit is complete. Per plan.md Complexity Tracking, none of these files is edited
by this initiative. Each fix ships with the remedy chosen for its finding.

| File:line | Claim (quoted) | Actual | Finding |
|---|---|---|---|
| README.md:16 | "if any part of your workflow fails, Ruby Reactor automatically triggers compensation logic to undo previous steps, ensuring your system never ends up in a corrupted half-state" | Not for map elements, async units, argument-resolution errors or non-`StandardError` exceptions | F-01, F-03, F-04, F-09 |
| README.md:25 | "**Compensation**: Automatic rollback of completed steps when a failure occurs." | Same exceptions | F-01, F-03 |
| README.md:35 | "Auto compensation/undo \| Yes" | Partial (see F-10 table) | F-10 |
| README.md:545-550 | "A reader that returns `Failure` triggers compensation normally" | Triggers the reader's compensation and the parent's undos only. The unit's hooks never run, and the unit may run after the rollback | F-04, F-09 |
| README.md:841 | Halt: "already-completed steps are NOT compensated" | CONFIRMED [O: S-plain-05]. Nested behavior unstated | F-07 |
| README.md:1309 | "When a step fails, RubyReactor automatically undoes completed steps in reverse order, compensate only runs in the failing step…" | CONFIRMED for steps and composes [O: S-plain-09, S-compose-03]. Not for map elements | F-01 |
| README.md:1398 | "A rollback that did not complete is never silent." | True for **attempted** rollbacks [O: S-plain-04, S-lock-05]. Rollbacks never attempted (map elements, F-03) leave `rollback_failures` empty | F-01, F-03 |
| documentation/background_and_async.md:165-167 | "Compensation is unchanged. A worker-side failure compensates exactly as a same-process failure does" | CONFIRMED [O: S-bg-01, S-bg-02] | — |
| documentation/background_and_async.md:279-283 | "A later step that reads the result and returns `Failure` triggers compensation normally — so no failure is ever unrecoverable" | Reader + parent only; the unit's effect stays | F-04 |
| documentation/background_and_async.md:285-289 | "the dispatch itself never enters the parent's undo stack … independent compensation flows" | CONFIRMED [O: S-async-03, S-async-06]. Unstated: the unit can run *after* the rollback, and an `async_step` has **no** compensation flow at all | F-04, F-09 |
| documentation/background_and_async.md:291-292 | "`compensate` / `undo` blocks declared on an `async_step` still register; they run only if the failure is surfaced into the parent's compensation path this way." | **Contradicted**: they never run [O: S-async-02] | F-04 |
| documentation/composition.md:184 | "can be configured with different retry strategies" | A compose-level retry resumes an already-rolled-back child | F-02 |
| documentation/composition.md:195 | "Compensation \| fully linked — a child failure rolls the parent back" | CONFIRMED, including earlier sibling composes [O: S-compose-01, S-compose-03]. Missing row: a child `Halt` does not stop the parent | F-07 |
| documentation/data_pipelines.md:167 | "the entire map operation fails immediately if any single element fails" | Completed elements are kept, not rolled back. In fan-out, "immediately" means not-yet-started elements skip themselves | F-01, F-05 |
| documentation/data_pipelines.md:179 | `fail_fast false` collects successes and failures | CONFIRMED [O: S-map-02, S-map-05]. Unstated: failed elements roll back individually | — |
| documentation/data_pipelines.md:233-235 | per-element `retries` | CONFIRMED. Unstated: inline sleeps, fan-out re-enqueues [O: S-map-09, S-map-10] | — |
| documentation/core_concepts.md:321-331 | "Compensation runs in reverse order of successful steps" | CONFIRMED for steps [O: S-plain-09]. Map elements and async units are excluded without saying so | F-01, F-10 |
| documentation/core_concepts.md:277 | Halt: "completed steps are **not** compensated" | CONFIRMED | F-07 (nesting) |
| documentation/DAG.md:228-240 | "Cascading Compensation … continue to Step 1 → Consistent State Achieved" | Not achieved for maps, async units or F-03 failures | F-01, F-03 |
| documentation/locks_and_semaphores.md:777-778 | "the contended step itself does not compensate — … its own work was never attempted" | CONFIRMED [O: S-lock-03, S-edge-01]. The same principle is broken for a raising `where`/`guard` | F-06 |
| documentation/locks_and_semaphores.md:852-866 | Step rollback re-takes lock then semaphore, waiting `rollback_wait` | CONFIRMED [O: S-lock-02, S-lock-04, S-lock-05] | F-11 (gap unstated) |
| documentation/getting_started.md:231-232 | compensate the failing step, then undo in reverse | CONFIRMED | — |
| documentation/interrupts.md:40, :62, :141 | exhausted payload validation → "cancelled and compensated" | Rolled back as stated, but the status is **failed** [O: S-intr-02] | F-16 |
| documentation/interrupts.md:155-157 | `undo` runs undo blocks in reverse, then cancels | CONFIRMED [O: S-intr-04]. Unstated: no reactor lock | F-08 |

---

## 3. Options

Every option addresses finding(s), lists at least one con, and is a **proposal** only.
Compatibility: SemVer impact per Constitution V.

### Options for F-01 (map rollback) — and the user's Q3

The user's question: should `map` get `compensate_all` / `compensate_each`? The first design point
is that **two different moments** need covering, and the library already has a word for each:

- **The map itself fails** (fail-fast, partial success): the elements that succeeded so far must be
  cleaned up. In library terms that is the map's **compensate**.
- **The map completed, and a later step fails**: all elements must be cleaned up. That is the map's
  **undo**.

`compensate_all` / `compensate_each` as named would cover only the first, unless their semantics
also cover undo. That naming mismatch is itself a DSL-clarity issue (F-10).

#### O-01-a · Implicit element-undo replay (make `map` behave like `compose`)

- **Sketch**: `MapStep#compensate` and a new `MapStep#undo` replay each **succeeded element's own
  undo stack**, newest element first, exactly as `ComposeStep#undo` replays a child
  [R: lib/ruby_reactor/step/compose_step.rb:31-47]. No new DSL: the `undo` blocks authors already
  write on element steps start running.
- **Pros**: consistent with compose (closes the F-10 asymmetry). Rollback granularity is per
  element step, so partial failures inside an undo are reported per step on `rollback_failures`.
- **Cons**: the element contexts must be **kept**. Inline maps discard them today, and keeping N
  contexts inside the parent blob risks `ContextTooLargeError`. Fan-out needs a rollback fan-out
  (N jobs, or a serial loop in the collector). It is a **behavior change** for every existing map
  whose element steps declare `undo` (MAJOR). "Newest element first" is ill-defined under fan-out
  concurrency.
- **Open questions**: keep element contexts by id (fan-out already does:
  `store_map_element_context_id`) or embed? Serial or parallel element undo? Honour `fail_fast false`?

#### O-01-b · `compensate_each` / `undo_each` block on the map (user proposal, per element)

- **Sketch**:

  ```ruby
  map :charges, ChargeElement do
    source input(:orders)
    argument :order, element(:charges)
    undo_each { |element_result, element| Refund.call(element_result[:charge_id]) }
  end
  ```

  Called once per **succeeded** element, on map failure (compensate) and on a later failure (undo).
- **Pros**: visible in the DSL. Needs only element **results**, which fan-out already stores
  (`store_map_result`) and inline has in memory, so no context retention. Per-element error
  isolation: one failed call becomes one `rollback_failures` entry and the rest continue.
- **Cons**: duplicates the element reactor's own step `undo`s (two places for the same cleanup)
  and is coarser than them. For the undo moment the map step must be pushed on the undo stack in
  fan-out mode (it isn't today, [R: lib/ruby_reactor/map/helpers.rb:97]). A `collect` block that
  transformed the results means the raw per-element results must be kept separately. Under fan-out
  fail-fast, elements still in flight when it runs finish later and escape it (see F-05 options).
- **Open questions**: argument order/shape (`element` = source item, `result` = element output)?
  Sequential or parallel calls in fan-out?

#### O-01-c · `compensate_all` / `undo_all` block on the map (user proposal, bulk)

- **Sketch**: `undo_all { |results, elements| Charge.where(id: results.map { _1[:charge_id] }).refund_all }`,
  called once with every succeeded element's result.
- **Pros**: matches bulk cleanup (one `DELETE … WHERE id IN`), which is the user's
  `all_elements.destroy` example. It is a single rollback call to reason about and report. It works
  identically inline and fan-out (the collector already holds a `ResultEnumerator`).
- **Cons**: all-or-nothing error handling. A failure halfway through a bulk undo is one opaque
  `rollback_failures` entry. The full result set must stay available until the parent finishes
  (fan-out results live under the context TTL). The in-flight-element problem from O-01-b applies
  unchanged.
- **Open questions**: pass an enumerator (lazy, fan-out friendly) or an array? Should
  `fail_fast false` successes be included when a later step fails? (Probably yes.)

#### O-01-d · Keep behavior, make it explicit

- **Sketch**: document "map elements are never rolled back", recommend `fail_fast false` plus a
  following step whose `undo` cleans up from the collected results, and remove the `# TODO` stub.
- **Pros**: no behavior change (PATCH). Honest.
- **Cons**: the gap stays. Every author re-implements the same pattern. It contradicts the README
  reliability promise, which would also have to change.

#### O-01 evaluation: `compensate_all` vs `compensate_each`

| Dimension | `compensate_each` / `undo_each` (O-01-b) | `compensate_all` / `undo_all` (O-01-c) | Element-undo replay (O-01-a) |
|---|---|---|---|
| Map fails, `fail_fast` on | called for each element that succeeded before the failure. Inline = deterministic set; fan-out = scheduling-dependent set (F-05) | one call with that same set | replays those elements' step undos |
| Map succeeds with `fail_fast false`, later step fails | called for each **successful** element (failed ones already self-rolled back) | one call with the successful subset | replay successful elements |
| Map fails with `fail_fast false` | n/a (map does not fail, unless a `collect` block raises, which then needs the compensate moment) | same | same |
| Inline | results in memory: easy | easy | needs element contexts kept (currently discarded) |
| Fan-out | results stored per index: available. In-flight elements finish after the call and escape it | same | contexts stored by id: available. Needs a rollback fan-out |
| Element retries | an element that succeeded after retries is included. One that exhausted is excluded (already self-rolled back) | same | same |
| Later-step failure (undo moment) | requires pushing the map step on the undo stack in fan-out mode | same | same |
| Data the block needs | per element: source item + result | all results (+ items) | none (element steps' own undo args/results) |
| Failure isolation | per element | whole batch | per element step |
| DSL visibility | explicit on the map | explicit on the map | implicit (like compose) |
| Duplication with element step `undo`s | yes | yes | none |
| Compatibility | additive (MINOR) if opt-in | additive (MINOR) if opt-in | behavior change (MAJOR) |

**Reading of the evidence (not a decision)**: the gap is real (INV-19 and INV-20 VIOLATED, zero
coverage). O-01-b and O-01-c are complementary rather than alternatives: per-element vs bulk is
the author's cleanup granularity, and both need the same two plumbing pieces:

1. The map step on the undo stack in every mode.
2. Retained element results.

They also share one unsolved problem: fan-out elements still in flight at compensate time (F-05).
O-01-a is the most consistent with `compose`, but the most expensive and the only breaking one.
Whatever is chosen, name the hooks after the two moments (`compensate…` for map failure,
`undo…` for a later failure) or document that one block covers both.

### Options for F-02 (compose retry resumes an undone child)

- **O-02-a · Fresh child per attempt**: when the compose step is retried after a failed attempt,
  discard the stored child context and start a new one.
  *Pros*: "retry the sub-saga" semantics, a one-line change at
  [R: lib/ruby_reactor/step/compose_step.rb:97]. *Cons*: child steps without `undo` (left in
  place) run again, so their side effect happens twice. Park/resume of a child mid-attempt must
  still resume, so the fresh-child rule must distinguish "retry after failure" from "redelivery
  after park". *Compat*: behavior fix (MINOR/PATCH, arguably a bug fix).
- **O-02-b · Rollback clears completion marks**: `rollback_completed_steps` removes each undone
  step's result from `intermediate_results`, so any later resume re-runs it.
  *Pros*: fixes the class of bug (any resume after a rollback), not just compose.
  *Cons*: changes context state that dashboards and `execution_trace` readers see. Undone results
  disappear, so post-mortem inspection loses data unless moved elsewhere.
  *Compat*: MINOR, observable.
- **O-02-c · Disallow `retries` on `compose`** (definition-time error, point to inner-step
  retries). *Pros*: removes the ambiguity. *Cons*: breaking (MAJOR). Loses a legitimate use (retry
  a whole sub-saga after a transient failure deep inside it).

### Options for F-03 (failures that skip rollback)

- **O-03-a · Resolve arguments inside the step's rescue, as a never-started failure**: an
  argument/transform error becomes the step's `Failure` (with `step_name`), classified like
  contention: no compensate, completed steps undone.
  *Pros*: consistent with INV-07 and fixes F-13's attribution too. *Cons*: the "deferred
  resolution" paths (`async_step`, `background before:`) need the same treatment in their own
  process. Needs a new never-started error class.
- **O-03-b · Roll back on every `StandardError`**: remove the "Unknown errors - don't rollback"
  branch [R: lib/ruby_reactor/executor/result_handler.rb:68-70].
  *Pros*: tiny change, covers unknown future paths. *Cons*: the branch exists deliberately.
  Rolling back after an internal executor bug runs user undo code on possibly inconsistent state.
  Error attribution is still missing (F-13).
- **O-03-c · Document the non-`StandardError` boundary** (for the `Exception` half): running user
  undo code on `SignalException`/`NoMemoryError` is unsafe. Document that an inline run offers no
  rollback here, and that a worker run is redelivered (INV-32).
  *Cons*: inline callers keep partial effects. It is only a documentation fix.

### Options for F-04 (`async_step` rollback hooks never run)

- **O-04-a · Make the docs and DSL honest**: state that unit hooks never run, and reject (or warn
  on) `compensate`/`undo` inside `async_step` at definition time.
  *Pros*: no runtime change, removes the dead-code trap. *Cons*: loses a natural place for cleanup.
  Authors must put it in the reader's `compensate`, far from the step. Rejecting would be MAJOR.
  Warning is MINOR.
- **O-04-b · Unit-local saga**: `StepWorker` calls the unit's own `compensate` when its body finally
  fails (after retries), inside the unit's job. This mirrors how an `async_reactor` child rolls
  itself back (INV-28).
  *Pros*: symmetric with `async_reactor`, the author's block becomes live, no cross-process state.
  *Cons*: runs whether or not anyone reads the result (a behavior change for existing units that
  declare `compensate`). Still no `undo` moment, since nobody tells a *successful* unit to roll back.
- **O-04-c · Parent-driven unit compensation on surfaced failure** (what the docs promise): when a
  reader returns `Failure`, the parent's rollback also calls the unit's `compensate` with the
  unit's recorded arguments/error, re-taking the unit step's locks.
  *Pros*: matches documented intent. *Cons*: the parent's executor must run a step config against
  another execution's recorded arguments and coordination owner. It only covers **read** units, and
  it happens in the reader's process, after an arbitrary delay.

### Options for F-05 (scheduling-dependent fan-out leftovers)

- **O-05-a · Collector waits for in-flight elements before resolving a fail-fast failure**, then
  runs the map compensation (O-01-*) over every success.
  *Pros*: deterministic leftover set (all successes), required anyway for O-01-b/c to be complete.
  *Cons*: failure latency grows to the slowest in-flight element. Needs "dispatched" vs "not
  started" accounting per index.
- **O-05-b · Late elements self-compensate**: an element that finishes after the fail-fast marker
  is set rolls itself back instead of storing its success.
  *Pros*: no waiting. *Cons*: the element must run its whole saga before undoing it (wasted side
  effects), and it races with the collector.

### Options for F-06 (raising `where`/`guard` compensates)

- **O-06-a** Classify condition errors as never-started (wrap them in a never-started error class
  before result handling). *Cons*: slightly more error-class surface.
- **O-06-b** Document that conditions must not raise. *Cons*: leaves an easy trap.

### Options for F-07 (nested `Halt`)

- **O-07-a** Propagate a composed child's `Halt` as the parent's `Halt` (map-consistent).
  *Cons*: behavior change for anyone relying on a child halting "locally".
- **O-07-b** Make an element's `Halt` stop only that element (compose-consistent).
  *Cons*: changes map semantics. The collector must represent "halted element" in results
  (it already can: `_halt` [R: lib/ruby_reactor/map/element_executor.rb:166-171]).
- **O-07-c** Keep both, document them side by side. *Cons*: the asymmetry remains.

### Options for F-08 (`Reactor.undo` outside the reactor lock)

- **O-08-a** `Reactor#undo` acquires the reactor-level lock/semaphore (with the configured `wait`)
  before `undo_all`. *Cons*: a manual undo can now fail on contention. Needs an error shape.
- **O-08-b** Document it. *Cons*: concurrent forward run + manual undo stays possible.

### Options for F-09 (units run after rollback)

- **O-09-a · Cancellation marker**: a failing dispatcher marks its not-yet-started units cancelled.
  `StepWorker`/`Worker` checks the marker before running the body. *Cons*: units already running
  are unaffected (still a race). Adds a storage write per rollback.
- **O-09-b · Gate `async_step` dispatch inside map elements** (run inline there, as
  `ElementExecutor` intends [R: lib/ruby_reactor/map/element_executor.rb:51-55]). *Cons*:
  reverses a deliberate decision [R: lib/ruby_reactor/executor/async_step_dispatch.rb:20-24] and
  serializes the unit into the element.
- **O-09-c** Document the ordering explicitly. *Cons*: behavior unchanged.

### Options for F-10 (DSL visibility)

- **O-10-a · Uniform rollback declarations on composites**: every construct that runs "more
  steps" states its rollback policy in the DSL (`map … undo_each/undo_all`, `compose … rollback:
  :replay` default, `async_step … compensate` either live or rejected).
  *Cons*: more DSL surface. Composes would gain a knob they may not need.
- **O-10-b · Rollback plan introspection**: `Reactor.rollback_plan` (and a dashboard view) lists,
  per step, what a failure after it would roll back and what it would leave in place, derived from
  the rules in [execution-order.md](execution-order.md#1-rollback-algorithm).
  *Pros*: no semantic change, helps readers and reviewers. *Cons*: the plan must be kept in sync
  with the executor. It is descriptive only.

### Options for Low findings

| Finding | Option | Con |
|---|---|---|
| F-11 lock gap | Document the gap next to `rollback_wait` and recommend idempotent, state-checking undos | documentation only |
| F-12 async retries invisible | Emit `retry_attempt` from `StepWorker`'s loop (middlewares are already built there) | more events on an existing hook (observability change) |
| F-13 missing attribution | Carry `step_name` onto `CompensationError`-derived and resolution failures (overlaps O-03-a) | failure shape grows |
| F-14 dead collect default | Delete `Map::Helpers#apply_collect_block` | none known. Confirm no external caller |
| F-15 lock key asymmetry | Emit the unprefixed key on release (the spec pins the current shape, so update it) | event payload change (observability MINOR) |
| F-16 interrupt status docs | Fix interrupts.md to say `failed` | documentation only |

---

*All options above are proposals pending later analysis. Nothing in this initiative changes
library behavior, tests or the demo application.*
