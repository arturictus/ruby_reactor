# Contract: Rollback Semantics

This is the behavior contract reactor authors can rely on after this feature. The tests (R-11) and
the updated 007 harness (SC-002) check it event by event.

Notation: `run:x`, `compensate:x`, `undo:x`. `e.s[i]` is step `s` of map element `i`.
`child.s` / `k.s` is a step of a composed child. `=> failure(x)` means the failure is attributed to
step `x`.

## 1. The one rule

1. A construct that **completed** is tracked for undo, unless it is an async unit
   (`rollback_tracked? == false`, which is the documented independence).
2. On failure, the failing construct is **compensated** if its work started. It is **not**
   compensated if it never started: contention, key error, refused dispatch, argument resolution
   error, argument/type validation.
3. Then every tracked construct is **undone**, newest first.
4. A compensate or undo that fails does not stop the rest. It is listed in `rollback_failures`.
5. `Halt` stops without rollback. `Skipped` is a `Success` in every effect (tracked and undone
   like one); it only marks the trace.
6. Every exception counts as a failure under rules 2–4, standard or not, except an interruption
   (`SignalException`, `SystemExit`, `NoMemoryError`, an enclosing timeout). An interruption runs no
   rollback. An execution in the caller's process is marked `aborted`, keeping only the entries not
   yet undone, and `Reactor#undo` rolls it back later. A worker execution is redelivered.
7. A nested reactor (`compose`, `async_reactor`) is never retried as a whole. Only steps retry.

## 2. What compensate and undo mean per construct

| Construct | compensate (its own failure) | undo (a later failure, or manual undo) |
| --- | --- | --- |
| step | its `compensate` (inline block, else class, else skipped) | its `undo` (same order) |
| `compose` | replay the child's undo stack. The child already rolled itself back, so this is a no-op | replay the child's undo stack, newest first |
| `map` (inline and fan-out) | replay the undo stack of every **completed** element, in descending element index. Failed elements rolled themselves back already | the same, for every completed element |
| `map` fan-out, fail-fast | as above, after **every** index has settled. Elements that were in flight when the failure happened are included | as above |
| `async_step` | not tracked by the parent. The **unit** compensates itself once, in its own job, after its final attempt fails | none. An inline `undo` block is rejected at definition time; a class `undo` is warned about and not run |
| `async_reactor` | not tracked by the parent. The child rolls itself back (unchanged) | none (unchanged) |

## 3. Canonical sequences (old → new)

These are the 007 scenarios whose sequence changes. All other 007 scenarios are unchanged. The last
four rows were found when the harness was re-run (T069): each is a direct consequence of an in-scope
fix (F-13, F-01, F-04, R-06), not a separate change.

| Scenario | Baseline (0.8.3) | After this feature |
| --- | --- | --- |
| S-map-01 inline, fail-fast, elem 2 fails | `… compensate:e.e2[2] undo:e.e1[2] undo:a` | `… compensate:e.e2[2] undo:e.e1[2] undo:e.e2[1] undo:e.e1[1] undo:e.e2[0] undo:e.e1[0] undo:a => failure(m)` |
| S-map-03 inline, all ok, b fails | `… run:b compensate:b undo:a` | `… run:b compensate:b undo:e.e2[3] undo:e.e1[3] undo:e.e2[2] undo:e.e1[2] undo:e.e2[1] undo:e.e1[1] undo:e.e2[0] undo:e.e1[0] undo:a => failure(b)` |
| S-map-04 fan-out, fail-fast, jobs 0..3 | `… compensate:e.e2[2] undo:e.e1[2] undo:a` | `… compensate:e.e2[2] undo:e.e1[2] undo:e.e2[1] undo:e.e1[1] undo:e.e2[0] undo:e.e1[0] undo:a => failure(m)` (elem 3 skipped) |
| S-map-04b fan-out, fail-fast, jobs 3,2,1,0 | `… run:e.e1[3] run:e.e2[3] … compensate:e.e2[2] undo:e.e1[2] undo:a` | `… compensate:e.e2[2] undo:e.e1[2] undo:e.e2[3] undo:e.e1[3] undo:a => failure(m)` (elems 1, 0 skipped) |
| S-map-06 fan-out, all ok, b fails | `… run:b compensate:b undo:a` | same as S-map-03 |
| S-map-07 compose(c0 → map(elem 2 fails)) | `… undo:e.e1[2] undo:child.c0 undo:a` | `… undo:e.e1[2] undo:e.e2[1] undo:e.e1[1] undo:e.e2[0] undo:e.e1[0] undo:child.c0 undo:a => failure(child)` |
| S-map-08 element = e1 → compose(k1) → e2 | `… compensate:e.e2[2] undo:k.k1 undo:e.e1[2]` | `… compensate:e.e2[2] undo:k.k1 undo:e.e1[2] undo:e.e2[1] undo:k.k1 undo:e.e1[1] undo:e.e2[0] undo:k.k1 undo:e.e1[0] => failure(m)` |
| S-compose-05 compose declares `retries` | `… retry:child#1 run:child.c2 => success` | `=> raised(DeprecatedDslError)` at class definition (R-14) |
| S-compose-05b child's c2 declares `retries`, fails once, then b fails | `… run:child.c2 run:b compensate:b undo:child.c2` (compose retries) | `run:child.c1 run:child.c2 retry:c2#1 run:child.c2 run:b compensate:b undo:child.c2 undo:child.c1 => failure(b)`: c1 runs once, c2 retries inside the child (R-14) |
| S-plain-07 b's transform raises | `run:a => failure(?)` | `run:a undo:a => failure(b)` |
| S-edge-03 b raises a custom `Exception` subclass | `run:a run:b => raised` (status `running`) | `run:a run:b compensate:b undo:a => failure(b)` (R-16) |
| S-edge-03b (new) b raises `Interrupt` | — | `run:a run:b => raised(Interrupt)` (same object), status **`aborted`**. `Reactor#undo` then gives `undo:a` |
| S-edge-04 b declares `where` | `run:a compensate:b undo:a => failure(b)` | `=> raised(DeprecatedDslError)` at class definition (R-15) |
| S-async-02 unit u fails, reader r fails | `run:a run:u run:r compensate:r undo:a` | `run:a run:u compensate:u run:r compensate:r undo:a => failure(r)` |
| S-async-07 unit u retries 3× then fails, no reader | `run:a run:b run:u run:u run:u => success` | `run:a run:b run:u run:u run:u compensate:u => success` (`compensate:u` recorded on the unit's record) |
| S-plain-03 b fails, its compensate fails | `run:a run:b compensate:b undo:a => failure(?)` | same sequence `=> failure(b)` (a `CompensationError` carries the step name, FR-017) |
| S-map-12 fan-out map, element has an async_step, elem 1 fails | `… compensate:e.e2[1] undo:e.e1[1] undo:a run:e.u[0] run:e.u[1]` | `… compensate:e.e2[1] undo:e.e1[1] undo:e.e2[0] undo:e.e1[0] undo:a run:e.u[0] run:e.u[1] => failure(m)` (element 0 is rolled back; its async unit is not, INV-25) |
| S-async-01 unit u fails, no reader | `run:a run:b run:u => success` | `run:a run:b run:u compensate:u => success` |
| S-async-08 reader's wait on u times out | `run:a undo:a run:u => failure(?)` | `run:a undo:a run:u compensate:u => failure(r)` (the timeout is wrapped as the reader's `ArgumentResolutionError`) |

## 4. Guarantees tied to invariants

| Invariant | After this feature |
| --- | --- |
| INV-06 every failure after completed work rolls back | HOLDS for every exception except interruptions, which give `aborted` plus manual undo |
| INV-07 never-started is never compensated | HOLDS, including argument resolution errors (`where`/`guard` no longer exist) |
| INV-13 a retried unit does not treat rolled-back work as done | HOLDS: only steps retry; a nested reactor cannot be retried as a whole |
| INV-19 / INV-20 succeeded map elements are rolled back | HOLDS in both modes |
| INV-22 left-in-place set after fail-fast is deterministic | HOLDS (it is always empty). Which elements run stays scheduling-dependent |
| INV-24 a unit's own compensate runs | HOLDS (unit-local, once, after the final attempt) |
| INV-25 parent rollback never touches async units | HOLDS (unchanged; expressed via `rollback_tracked?`) |
