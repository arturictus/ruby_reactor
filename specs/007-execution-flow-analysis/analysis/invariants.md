# Invariants

Testable propositions about ordering and rollback. Each has a status, evidence and existing-spec
coverage. Status scale: **HOLDS** (evidence agrees, no counter-example found) · **VIOLATED**
(a reproducible counter-example exists, cited as `[O]`) · **CONDITIONAL** (holds only under the
listed conditions) · **UNDETERMINED** (evidence insufficient).

Every `[O: S-…]` is a block in [`../evidence/output.txt`](../evidence/output.txt).
Details and sequences are in [execution-order.md](execution-order.md).

## A. Ordering & the rollback algorithm

| Id | Statement | Scope | Status | Evidence | Coverage |
|---|---|---|---|---|---|
| INV-01 | The failing step's compensate runs **before** any undo. | all reactor executions | HOLDS | [R: lib/ruby_reactor/executor/compensation_manager.rb:35-65] [O: S-plain-01, S-compose-01, S-map-01] | [T: spec/ruby_reactor/order_processing_reactor_spec.rb:91] |
| INV-02 | Completed steps are undone in reverse completion order, including across independent DAG branches. | one execution's undo stack | HOLDS | [R: …/compensation_manager.rb:69] [O: S-plain-09] | [T: spec/ruby_reactor/order_processing_reactor_spec.rb:91] (linear only; DAG branches: none) |
| INV-03 | After a step fails, no further step of the same execution runs. | inline and worker | HOLDS | [R: lib/ruby_reactor/executor/step_executor.rb:47] [O: S-plain-01, S-bg-01] | implicit in most failure specs; no dedicated example |
| INV-04 | A compensate or undo that fails (returns `Failure` or raises) does not stop the remaining undos, and it is listed on `Failure#rollback_failures`. | all | HOLDS | [O: S-plain-03, S-plain-04, S-compose-07] | [T: spec/ruby_reactor/compensation_failure_spec.rb:30] [T: spec/ruby_reactor/step_coordination/rollback_under_contention_spec.rb:51, :59, :67, :78] |
| INV-05 | `Halt` never rolls back. `Skipped` steps are never undone. | inline | HOLDS | [O: S-plain-05, S-plain-06] | [T: spec/ruby_reactor/halt_status_spec.rb:30] [T: spec/ruby_reactor/skipped_rollback_spec.rb:6] |
| INV-06 | **Every** failure that occurs after at least one step has completed rolls back the completed steps. | all | **VIOLATED** | Argument source/transform raising a `StandardError` [O: S-plain-07]. A non-`StandardError` exception [O: S-edge-03]. Both skip rollback. [R: lib/ruby_reactor/executor/result_handler.rb:68-70] [R: …/step_executor.rb:83] | none |
| INV-07 | A step whose body never started is never compensated. | all | **CONDITIONAL** | Holds for own-coordination contention [O: S-lock-03, S-edge-01], refused async dispatch, and argument/type validation [O: S-edge-05]. **Violated** when a `where`/`guard` block raises: the step is compensated though its body never ran [O: S-edge-04]. | [T: spec/ruby_reactor/step_coordination/contention_spec.rb:173] [T: spec/ruby_reactor/step_coordination/rollback_spec.rb:184]; where/guard: none |
| INV-08 | A step whose body ran and then failed (including an invalid output) is compensated. | same-process steps | HOLDS (exception: async units, INV-24) | [O: S-plain-01, S-plain-08] | [T: spec/ruby_reactor/validations_spec.rb:1139] |
| INV-09 | Halt semantics are the same at every nesting level: a `Halt` anywhere stops the top-level execution without rollback. | compose, map | **VIOLATED** | A map element's `Halt` halts the parent [O: S-map-11]. A composed child's `Halt` becomes a plain `Success(nil)` and the parent **continues** [O: S-compose-08]. [R: lib/ruby_reactor/step/compose_step.rb:106-114] | none |

## B. Retries

| Id | Statement | Scope | Status | Evidence | Coverage |
|---|---|---|---|---|---|
| INV-10 | Retries are exhausted before compensation. Compensation runs exactly once, after the last attempt. | same-process steps, inline and worker | HOLDS | [O: S-retry-01, S-retry-04, S-bg-03] | [T: spec/ruby_reactor/step_retries/execution_paths_spec.rb:81] [T: spec/map/map_retry_spec.rb:49] |
| INV-11 | A failed attempt followed by a successful one is never compensated. | same-process steps | HOLDS | [O: S-retry-03, S-bg-04, S-map-09, S-map-10] | [T: spec/ruby_reactor/retry_reexecution_spec.rb:13] [T: spec/ruby_reactor/retry_signals_spec.rb:14] |
| INV-12 | A `retry: false` failure is not retried. | all | HOLDS | [O: S-retry-02] | [T: spec/ruby_reactor/retry_signals_spec.rb:32] |
| INV-13 | A retried unit of work re-runs from a state in which its already-rolled-back work is **not** treated as done. | `compose` with `retries` | **VIOLATED** | During the failed attempt the child undoes `c1`. The retry *resumes* the child: `c1` is not re-run, its stale result feeds `c2` and the final value, and a later failure undoes only `c2` [O: S-compose-05, S-compose-05b]. [R: lib/ruby_reactor/step/compose_step.rb:97] [R: lib/ruby_reactor/executor/graph_manager.rb (mark_completed_steps_from_context)] | none. [T: spec/compose_spec.rb:46] retries an inner step, not the compose |
| INV-14 | Retry delivery depends only on where the step runs. Inline: in-process `sleep`. Worker/background: re-enqueue. Fan-out element: element re-enqueue. `async_step`: loop inside its job. | all | HOLDS (descriptive) | [O: S-retry-01, S-bg-03, S-map-09, S-map-10, S-async-07] | [T: spec/async_retry_integration_spec.rb:75] |

## C. Composition

| Id | Statement | Scope | Status | Evidence | Coverage |
|---|---|---|---|---|---|
| INV-15 | A failing composed child rolls back its own completed steps **before** the parent starts its rollback. | compose, any depth | HOLDS | [O: S-compose-01, S-compose-04] | [T: spec/compose_spec.rb:197] |
| INV-16 | A completed composed child is fully undone (all its completed steps, reverse order) when a later parent step fails. This includes **earlier sibling composes** when a later compose fails. | compose | HOLDS | [O: S-compose-02, S-compose-03, S-compose-06] | [T: spec/compose_spec.rb:192] (single child; sibling case: none) |
| INV-17 | Nesting unwinds innermost-first. Nesting depth never changes the rule. | compose ⊂ compose, map ⊂ compose, compose ⊂ map element | HOLDS | [O: S-compose-04, S-map-07, S-map-08] | none |
| INV-18 | A composed child's rollback failures reach the parent's `rollback_failures`. | compose | HOLDS | [O: S-compose-07] | [T: spec/ruby_reactor/step_coordination/rollback_under_contention_spec.rb:78] |

## D. Map

| Id | Statement | Scope | Status | Evidence | Coverage |
|---|---|---|---|---|---|
| INV-19 | When a map fails, its elements that already **succeeded** are rolled back. | map, fail_fast | **VIOLATED** | Elements 0, 1 left in place when element 2 fails [O: S-map-01, S-map-04, S-map-07, S-map-08]. `MapStep#compensate` is a stub returning `Success()` [R: lib/ruby_reactor/step/map_step.rb:29-31] | none. [T: spec/map/map_fail_fast_spec.rb:34] asserts only the Failure |
| INV-20 | When a step **after** a completed map fails, the map's elements are rolled back. | map | **VIOLATED** | All elements left in place [O: S-map-03, S-map-06]. Inline: the map step's undo is the base `Skipped` [R: lib/ruby_reactor/step.rb:57]. Fan-out: the map step is never pushed on the undo stack [R: lib/ruby_reactor/map/helpers.rb:97] | none |
| INV-21 | A failed element rolls back its own completed steps (compensate failing step, undo the rest) regardless of mode. | map element | HOLDS | [O: S-map-01, S-map-02, S-map-04, S-map-05, S-map-08] | none dedicated |
| INV-22 | For a given input, the set of elements that run, and the set left in place after a fail-fast failure, is deterministic. | map, fail_fast | **CONDITIONAL** | Inline: yes (source order) [O: S-map-01]. Fan-out: depends on job scheduling. Elements that started before the failure marker finish and stay [O: S-map-04 vs S-map-04b] [R: lib/ruby_reactor/map/element_executor.rb:61, :145] | [T: spec/map/fail_fast_spec.rb:118] (only "stops further elements") |
| INV-23 | `fail_fast false`: the map step succeeds even when elements fail. Failed elements are rolled back individually, successes kept, and the consumer must inspect the results. | map | HOLDS (by design) | [O: S-map-02, S-map-05] | [T: spec/map/map_fail_fast_spec.rb:77] [T: spec/map/fail_fast_spec.rb:172, :196] |

## E. Async units (`async_step`, `async_reactor`)

| Id | Statement | Scope | Status | Evidence | Coverage |
|---|---|---|---|---|---|
| INV-24 | A unit's own `compensate`/`undo` runs when its failure is surfaced into the parent's rollback by a reader. | async_step | **VIOLATED** | The reader is compensated and the parent undone, but `compensate:u` never runs [O: S-async-02]. `StepWorker` never calls rollback hooks [R: lib/ruby_reactor/step_worker.rb:240-393] | [T: spec/ruby_reactor/dsl/async_step_spec.rb:111] asserts only that `:setup` is compensated |
| INV-25 | A unit never enters the parent's undo stack, so parent rollback never touches it. | async_step, async_reactor | HOLDS (by design, documented) | [R: lib/ruby_reactor/executor/result_handler.rb:137] [O: S-async-03, S-async-06] | [T: spec/ruby_reactor/dsl/async_reactor_spec.rb:26, :123] |
| INV-26 | A unit's failure fails the parent only if a reader returns `Failure`. | async_step, async_reactor | HOLDS (by design) | [O: S-async-01, S-async-02, S-async-04, S-async-05] | [T: spec/ruby_reactor/dsl/async_step_spec.rb:98] [T: spec/ruby_reactor/dsl/async_reactor_spec.rb:16, :77] |
| INV-27 | A unit dispatched by an execution that then fails and rolls back does not perform its side effect **after** that rollback. | async_step, async_reactor, async_step inside a map element | **VIOLATED** | Unit bodies run after the parent's undo [O: S-async-03, S-async-06, S-async-08, S-map-12]. In production the relative order is a race | none |
| INV-28 | An `async_reactor` child rolls back its own steps on its own failure, in its worker. | async_reactor | HOLDS | [O: S-async-04, S-async-05] | [T: spec/ruby_reactor/dsl/async_reactor_spec.rb:16] |
| INV-29 | An async unit's retries behave like a same-process step's (one compensation at exhaustion, retry middleware events). | async_step | **VIOLATED** | Retries loop inside the job with no `retry_attempt` event and no compensation [O: S-async-07] [R: lib/ruby_reactor/step_worker.rb:275-289] | [T: spec/ruby_reactor/dsl/async_step_spec.rb:123] (attempt count only) |
| INV-30 | A reader that cannot get the unit's result in time fails and rolls back the parent. | async_step reader | HOLDS | [O: S-async-08] | [T: spec/ruby_reactor/async_waiter_spec.rb] (waiter timeout only) |

## F. background / worker parity

| Id | Statement | Scope | Status | Evidence | Coverage |
|---|---|---|---|---|---|
| INV-31 | A worker-side run produces the same order and rollback coverage as an inline run of the same shape, including steps that ran in the caller before a `background after:`/`before:` hand-off. | background, fan-out map, compose in worker | HOLDS | [O: S-bg-01, S-bg-02, S-compose-06, S-map-04] (vs S-map-01) | [T: spec/ruby_reactor/step_retries/execution_paths_spec.rb:81] |
| INV-32 | A worker crash re-drives from the last checkpoint. Completed steps are not re-run, and the in-flight step may run twice (at-least-once). | background | HOLDS | [O: S-edge-02] [R: lib/ruby_reactor/executor.rb:55] | [T: spec/ruby_reactor/checkpoint_spec.rb:85] |

## G. Locks & coordination

| Id | Statement | Scope | Status | Evidence | Coverage |
|---|---|---|---|---|---|
| INV-33 | A reactor-level lock/semaphore is held from before the first step until after the last undo. | reactor `with_lock`/`with_semaphore` | HOLDS | [O: S-lock-01] [R: lib/ruby_reactor/executor.rb:161] | [T: spec/ruby_reactor/telemetry_spec.rb:353] (events only) |
| INV-34 | A reactor-level lock is released while the execution is paused at an interrupt and re-acquired on `continue`. | interrupts | HOLDS | [O: S-intr-01] | none |
| INV-35 | Every rollback of a step is serialized with forward runs by the same locks the forward run held. | step locks, `Reactor.undo` | **CONDITIONAL** | Step-level lock/semaphore is re-taken around compensate/undo [O: S-lock-02, S-lock-04]. The **reactor-level** lock is **not** taken by `Reactor.undo(id)` [O: S-intr-04] [R: lib/ruby_reactor/reactor.rb:188] | [T: spec/ruby_reactor/step_coordination/rollback_spec.rb:31, :52]; Reactor.undo: none |
| INV-36 | A rollback that cannot re-take its step lock within `rollback_wait` is skipped **and reported**, never silently dropped. | step locks | HOLDS | [O: S-lock-05] | [T: spec/ruby_reactor/step_coordination/rollback_under_contention_spec.rb:32] |
| INV-37 | A composed child re-enters the parent's reactor lock without releasing the parent's hold. | compose + reactor lock | HOLDS | [O: S-lock-06] (count back to 1 in `b`) | [T: spec/ruby_reactor/step_coordination/reentrancy_spec.rb:53] |
| INV-38 | Lock middleware events name the same key on acquire and release. | reactor-level lock | **VIOLATED** (known, pinned) | `lock_acquired:rk` vs `lock_released:lock:rk` [O: S-lock-01] | [T: spec/ruby_reactor/step_coordination/attribution_spec.rb:41] (documents the asymmetry) |

## H. Interrupts & manual control

| Id | Statement | Scope | Status | Evidence | Coverage |
|---|---|---|---|---|---|
| INV-39 | Steps completed before a pause are undone when the run fails after `continue`. | interrupts | HOLDS | [O: S-intr-01] | [T: spec/ruby_reactor/interrupt_undo_spec.rb:77] (explicit undo) |
| INV-40 | Invalid interrupt payload past `max_attempts` rolls back completed steps. | interrupts | HOLDS | [O: S-intr-02] | [T: spec/integration/interrupt_max_attempts_spec.rb:9] |
| INV-41 | `Reactor.cancel` never rolls back. `Reactor.undo(id)` rolls back and then cancels. | manual | HOLDS | [O: S-intr-03, S-intr-04] | [T: spec/ruby_reactor/interrupt_undo_spec.rb:77, :94] |

## Coverage summary

| Status | Count | Ids |
|---|---|---|
| HOLDS | 29 | INV-01–05, 08, 10–12, 14–18, 21, 23, 25, 26, 28, 30–34, 36, 37, 39–41 |
| VIOLATED | 9 | INV-06, 09, 13, 19, 20, 24, 27, 29, 38 |
| CONDITIONAL | 3 | INV-07, 22, 35 |
| UNDETERMINED | 0 | — |

(41 invariants in total. INV-38's violation is known and pinned by a spec.)

**No existing spec covers**: INV-06, INV-09, INV-13, INV-17, INV-19, INV-20, INV-27, INV-34,
the `where`/`guard` half of INV-07, the `Reactor.undo` half of INV-35, the DAG half of INV-02, and
the sibling-compose half of INV-16. INV-19 and INV-20 are the map behavior the user asked about.
They are currently neither specified nor tested.
