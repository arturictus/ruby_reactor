# Invariants

Testable propositions about ordering and rollback. Each has a status, evidence and existing-spec
coverage. Status scale: **HOLDS** (evidence agrees, no counter-example found) · **VIOLATED**
(a reproducible counter-example exists, cited as `[O]`) · **CONDITIONAL** (holds only under the
listed conditions) · **UNDETERMINED** (evidence insufficient).

Every `[O: S-…]` is a block in [`../evidence/output.txt`](../evidence/output.txt).
Details and sequences are in [execution-order.md](execution-order.md).

**Updated for 008.** INV-06, 07, 13, 19, 20, 22 and 24 now **HOLD**, each covered by a spec under
`spec/ruby_reactor/rollback/` that fails on the baseline. Their original counter-examples are in
git history.

## A. Ordering & the rollback algorithm

| Id | Statement | Scope | Status | Evidence | Coverage |
|---|---|---|---|---|---|
| INV-01 | The failing step's compensate runs **before** any undo. | all reactor executions | HOLDS | [R: lib/ruby_reactor/executor/compensation_manager.rb:35-65] [O: S-plain-01, S-compose-01, S-map-01] | [T: spec/ruby_reactor/order_processing_reactor_spec.rb:91] |
| INV-02 | Completed steps are undone in reverse completion order, including across independent DAG branches. | one execution's undo stack | HOLDS | [R: …/compensation_manager.rb:69] [O: S-plain-09] | [T: spec/ruby_reactor/order_processing_reactor_spec.rb:91] (linear only; DAG branches: none) |
| INV-03 | After a step fails, no further step of the same execution runs. | inline and worker | HOLDS | [R: lib/ruby_reactor/executor/step_executor.rb:47] [O: S-plain-01, S-bg-01] | implicit in most failure specs; no dedicated example |
| INV-04 | A compensate or undo that fails (returns `Failure` or raises) does not stop the remaining undos, and it is listed on `Failure#rollback_failures`. | all | HOLDS | [O: S-plain-03, S-plain-04, S-compose-07] | [T: spec/ruby_reactor/compensation_failure_spec.rb:30] [T: spec/ruby_reactor/step_coordination/rollback_under_contention_spec.rb:51, :59, :67, :78] |
| INV-05 | `Halt` never rolls back. *(008 R-19: `Skipped` is undone like `Success`, so its former second clause, "`Skipped` steps are never undone", no longer applies.)* | inline | HOLDS | [O: S-plain-05, S-plain-06] | [T: spec/ruby_reactor/halt_status_spec.rb:30] [T: spec/ruby_reactor/skipped_rollback_spec.rb:6] |
| INV-06 | **Every** failure that occurs after at least one step has completed rolls back the completed steps. | all | HOLDS (008) for every exception, `StandardError` or not (R-16). Only an interruption (signal, exit, out of memory, enclosing timeout) runs no rollback, by design; the caller-process run is stored `aborted` and `Reactor.undo(id)` rolls it back | [O: S-plain-07, S-edge-03, S-edge-03b] | [T: spec/ruby_reactor/rollback/failure_rollback_spec.rb] [T: spec/ruby_reactor/rollback/aborted_execution_spec.rb] |
| INV-07 | A step whose body never started is never compensated. | all | HOLDS (008) | Own-coordination contention [O: S-lock-03, S-edge-01], refused async dispatch, argument/type validation [O: S-edge-05], and (since 008) argument resolution errors [O: S-plain-07]. `where`/`guard` were removed (008 R-15) [O: S-edge-04] | [T: spec/ruby_reactor/step_coordination/contention_spec.rb:173] [T: spec/ruby_reactor/rollback/failure_rollback_spec.rb] |
| INV-08 | A step whose body ran and then failed (including an invalid output) is compensated. | same-process steps | HOLDS (exception: async units, INV-24) | [O: S-plain-01, S-plain-08] | [T: spec/ruby_reactor/validations_spec.rb:1139] |
| INV-09 | Halt semantics are the same at every nesting level: a `Halt` anywhere stops the top-level execution without rollback. | compose, map | **VIOLATED** | A map element's `Halt` halts the parent [O: S-map-11]. A composed child's `Halt` becomes a plain `Success(nil)` and the parent **continues** [O: S-compose-08]. [R: lib/ruby_reactor/step/compose_step.rb:106-114] | none |

## B. Retries

| Id | Statement | Scope | Status | Evidence | Coverage |
|---|---|---|---|---|---|
| INV-10 | Retries are exhausted before compensation. Compensation runs exactly once, after the last attempt. | same-process steps, inline and worker | HOLDS | [O: S-retry-01, S-retry-04, S-bg-03] | [T: spec/ruby_reactor/step_retries/execution_paths_spec.rb:81] [T: spec/map/map_retry_spec.rb:49] |
| INV-11 | A failed attempt followed by a successful one is never compensated. | same-process steps | HOLDS | [O: S-retry-03, S-bg-04, S-map-09, S-map-10] | [T: spec/ruby_reactor/retry_reexecution_spec.rb:13] [T: spec/ruby_reactor/retry_signals_spec.rb:14] |
| INV-12 | A `retry: false` failure is not retried. | all | HOLDS | [O: S-retry-02] | [T: spec/ruby_reactor/retry_signals_spec.rb:32] |
| INV-13 | A retried unit of work re-runs from a state in which its already-rolled-back work is **not** treated as done. | step `retries` (incl. a composed child's steps) | HOLDS (008) | Only steps retry: `retries` on a `compose`/`async_reactor` is rejected at definition time (008 R-14) [O: S-compose-05]. A child's own step retries inside the child and a later failure undoes each child step once [O: S-compose-05b]. A park/resume still resumes | [T: spec/ruby_reactor/rollback/compose_retry_spec.rb] |
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
| INV-19 | When a map fails, its elements that already **succeeded** are rolled back. | map, fail_fast | HOLDS (008) | `MapStep#compensate` replays every completed element's undo stack, highest index first [O: S-map-01, S-map-04, S-map-04b, S-map-07, S-map-08] | [T: spec/ruby_reactor/rollback/map_rollback_spec.rb] [T: spec/ruby_reactor/rollback/map_fan_out_settle_spec.rb] |
| INV-20 | When a step **after** a completed map fails, the map's elements are rolled back. | map | HOLDS (008) | The map step's `undo` is the same element replay; a fan-out map is pushed on the undo stack by the collector [O: S-map-03, S-map-06] | [T: spec/ruby_reactor/rollback/map_rollback_spec.rb] [T: spec/ruby_reactor/rollback/map_fan_out_settle_spec.rb] |
| INV-21 | A failed element rolls back its own completed steps (compensate failing step, undo the rest) regardless of mode. | map element | HOLDS | [O: S-map-01, S-map-02, S-map-04, S-map-05, S-map-08] | none dedicated |
| INV-22 | *Restated in 008.* After a fail-fast failure, the set of elements **left in place** is deterministic: it is empty. (Which elements run in fan-out mode still depends on job scheduling, inherently.) | map, fail_fast | HOLDS (008) | The collector applies the failure only once every index has settled, then rolls back every completed element [O: S-map-04, S-map-04b] | [T: spec/ruby_reactor/rollback/map_fan_out_settle_spec.rb] (100 shuffled job orders, SC-003) |
| INV-23 | `fail_fast false`: the map step succeeds even when elements fail. Failed elements are rolled back individually, successes kept, and the consumer must inspect the results. | map | HOLDS (by design) | [O: S-map-02, S-map-05] | [T: spec/map/map_fail_fast_spec.rb:77] [T: spec/map/fail_fast_spec.rb:172, :196] |

## E. Async units (`async_step`, `async_reactor`)

| Id | Statement | Scope | Status | Evidence | Coverage |
|---|---|---|---|---|---|
| INV-24 | *Restated in 008.* A unit's own `compensate` runs once, in its own job, after its final attempt fails, whether or not a reader surfaces it; an `undo` on `async_step` is rejected (inline) or warned (class). | async_step | HOLDS (008) | [O: S-async-01, S-async-02, S-async-07] | [T: spec/ruby_reactor/rollback/async_step_compensate_spec.rb] [T: spec/ruby_reactor/dsl/async_step_spec.rb:111] (tightened) |
| INV-25 | A unit never enters the parent's undo stack, so parent rollback never touches it. | async_step, async_reactor | HOLDS (by design, documented) | [R: lib/ruby_reactor/executor/result_handler.rb:137] [O: S-async-03, S-async-06] | [T: spec/ruby_reactor/dsl/async_reactor_spec.rb:26, :123] |
| INV-26 | A unit's failure fails the parent only if a reader returns `Failure`. | async_step, async_reactor | HOLDS (by design) | [O: S-async-01, S-async-02, S-async-04, S-async-05] | [T: spec/ruby_reactor/dsl/async_step_spec.rb:98] [T: spec/ruby_reactor/dsl/async_reactor_spec.rb:16, :77] |
| INV-27 | A unit dispatched by an execution that then fails and rolls back does not perform its side effect **after** that rollback. | async_step, async_reactor, async_step inside a map element | **VIOLATED** | Unit bodies run after the parent's undo [O: S-async-03, S-async-06, S-async-08, S-map-12]. In production the relative order is a race | none |
| INV-28 | An `async_reactor` child rolls back its own steps on its own failure, in its worker. | async_reactor | HOLDS | [O: S-async-04, S-async-05] | [T: spec/ruby_reactor/dsl/async_reactor_spec.rb:16] |
| INV-29 | An async unit's retries behave like a same-process step's (one compensation at exhaustion, retry middleware events). | async_step | **VIOLATED** (compensation half fixed in 008) | One compensation at exhaustion since 008 [O: S-async-07]. Retries still loop inside the job with no `retry_attempt` event [R: lib/ruby_reactor/step_worker.rb:275-289] | [T: spec/ruby_reactor/dsl/async_step_spec.rb:123] (attempt count only) [T: spec/ruby_reactor/rollback/async_step_compensate_spec.rb] |
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
| HOLDS | 36 | INV-01–08, 10–26, 28, 30–34, 36, 37, 39–41 |
| VIOLATED | 4 | INV-09, 27, 29, 38 |
| CONDITIONAL | 1 | INV-35 |
| UNDETERMINED | 0 | — |

(41 invariants in total. INV-38's violation is known and pinned by a spec.)

**No existing spec covers** (after 008): INV-09, INV-27, INV-34, the `Reactor.undo` half of
INV-35, the DAG half of INV-02, and the sibling-compose half of INV-16. INV-17 is now covered by
the nested map/compose examples in `spec/ruby_reactor/rollback/map_rollback_spec.rb`.
