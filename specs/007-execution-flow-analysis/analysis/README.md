# Execution Flow & Compensation Analysis

Research into how RubyReactor orders forward execution and rollback across every construct, under
locks, retries and failures. Its purpose is to judge whether compensation is **predictable** and
whether the DSL makes it **visible**. Documentation only: no library, test-suite or demo-app change.

## Scope & baseline

- **Code**: commit `faf90e8d` (ruby_reactor 0.8.3, with step-scoped retries #61 and inputs
  protection #63).
- **Constructs**: plain steps, `compose`, `map` (inline and `fan_out`, `fail_fast` on/off),
  `async_step`, `async_reactor`, `background` reactors, interrupts, manual `cancel`/`undo`.
- **Conditions**: reactor- and step-level locks/semaphores (ordered lock, rate limit and period by
  reading), retries (inline, worker, element, unit), and every failure kind in
  [execution-order.md §1](execution-order.md#failure-kinds--path).
- **Evidence**: 63 probe scenarios run against real Redis through the real worker bodies
  (Sidekiq fake mode + drain; `inline!` only where labelled). **64/64 match** the sequences quoted
  in this report. Re-run: [../quickstart.md](../quickstart.md).
- **Out of scope**: the ActiveJob backend is not probed separately (its adapters delegate to the
  same shared bodies). Neither are rate limits and periods beyond their "never re-taken for rollback"
  rule, the dashboard, or OpenTelemetry spans.
- **Documentation**: README.md and `./documentation` are **audited, not edited**
  ([findings-and-options.md §2](findings-and-options.md#2-documentation-audit)). Writing current
  behavior in as contract before the follow-up decision would lock in behavior that may be
  unintended. Each remedy updates the docs it affects.

## How to read

- *compensate* = the failing step's own cleanup; *undo* = rollback of a completed step;
  *rollback* = both; *left in place* = completed work nothing rolls back; *unit* = an
  `async_step`/`async_reactor` dispatch.
- Evidence labels: `[R: file:line]` read in source · `[O: S-…]` observed, see
  [../evidence/output.txt](../evidence/output.txt) · `[T: spec:line]` covered by an existing spec.
- Invariant status: HOLDS · VIOLATED · CONDITIONAL · UNDETERMINED.
  Finding severity: High · Medium · Low
  ([findings-and-options.md](findings-and-options.md) header).

---

## Answers

### Q1 · Are already-executed map elements compensated individually?

**No.** Only the element that **fails** is rolled back, individually, by its own reactor.
Elements that already **succeeded** are never compensated or undone. That holds whether the map
itself fails or a later step fails.

| Situation | Failed element | Elements that succeeded | Evidence |
|---|---|---|---|
| Inline, `fail_fast` (default), element k fails | compensated + its steps undone | **left in place**: elements before k. Elements after k never run | [O: S-map-01] |
| Fan-out, `fail_fast`, element k fails | same, in its own job | **left in place**: whichever elements started before the failure. The set depends on **job scheduling** | [O: S-map-04] [O: S-map-04b] |
| `fail_fast false` (inline or fan-out) | rolled back individually | kept. The map **succeeds** and the consumer inspects the results | [O: S-map-02] [O: S-map-05] |
| Map completed, a **later step** fails | — | **all left in place** | [O: S-map-03] [O: S-map-06] |
| Map inside a compose child / compose inside an element | same rules, nested | same | [O: S-map-07] [O: S-map-08] |

Why: `MapStep#compensate` is a stub (`# TODO: Implement compensation for map steps` → `Success()`)
[R: lib/ruby_reactor/step/map_step.rb:29-31], the map has no `undo`
[R: lib/ruby_reactor/step.rb:57], and the DSL offers no hook
[R: lib/ruby_reactor/dsl/map_builder.rb:130-131]. `rollback_failures` stays empty, because nothing
is attempted. → [F-01](findings-and-options.md#f-01--high--map-elements-that-already-succeeded-are-never-rolled-back),
[F-05](findings-and-options.md#f-05--medium--fan-out-fail-fast-leaves-a-scheduling-dependent-set-of-elements-in-place),
INV-19/20/22 in [invariants.md](invariants.md#d-map). No existing spec covers it.

### Q2 · When a composed reactor fails, are previously completed composed reactors compensated?

**Yes.** Composition is fully wired into rollback, at any depth and in worker mode:

1. The failing child rolls **itself** back first (its compensate, then its own undos).
2. The parent compensates the compose step (a no-op by then), then undoes its own completed steps
   newest-first. **Each earlier compose is undone by replaying its child's undo stack in reverse.**

```text
compose x(x1 → x2) → compose y(y1 → y2 ✗)
run:x.x1 run:x.x2 run:y.y1 run:y.y2 compensate:y.y2 undo:y.y1 undo:x.x2 undo:x.x1 ⇒ failure(y)
```

[O: S-compose-03] · also [O: S-compose-01] [O: S-compose-02] [O: S-compose-04] [O: S-compose-06] ·
[T: spec/compose_spec.rb:192, :197] · INV-15–18.

**Except** in three cases:

- `compose` with `retries`: a retried child **resumes** with its already-undone steps counted as
  done, so they are not re-run and their stale results flow on
  ([F-02](findings-and-options.md#f-02--high--compose-with-retries-resumes-a-child-whose-earlier-steps-were-already-undone),
  [O: S-compose-05]).
- A child's `Halt` does **not** stop the parent. The parent continues with `nil`
  ([F-07](findings-and-options.md#f-07--medium--halt-means-different-things-at-different-nesting-levels),
  [O: S-compose-08]).
- A `map` or async unit **inside** a child keeps its own rules (Q1, and
  [F-04](findings-and-options.md#f-04--high--an-async_steps-own-compensate--undo-never-run-the-docs-say-they-do)/[F-09](findings-and-options.md#f-09--medium--dispatched-units-run-after-their-dispatcher-rolled-back-including-units-of-a-failed-map-element)).

### Q3 · Would `compensate_all` / `compensate_each` on `map` close a real gap?

**Yes, the gap is real**: INV-19 and INV-20 are VIOLATED and have no spec coverage. Both proposed
shapes would close it, and they are complementary rather than alternatives: per-element vs bulk is
a matter of how the author wants to clean up. Before either works, three things must be settled:

1. **Two moments, not one.** Cleanup is needed when the map **fails** (the library's
   *compensate*) and when a **later step** fails after the map completed (the library's *undo*).
   `compensate_*` as named covers only the first. The hooks should be named for both moments, or one
   block should be documented to cover both.
2. **Plumbing.** In fan-out mode the map step must be on the parent's undo stack (today it never is,
   [R: lib/ruby_reactor/map/helpers.rb:97]). Raw per-element results must also stay available even
   when a `collect` block transformed them.
3. **In-flight fan-out elements.** Elements still running when the hook fires finish afterwards and
   escape it, unless the collector waits for them
   ([O-05-a](findings-and-options.md#options-for-f-05-scheduling-dependent-fan-out-leftovers)).

There is also a third shape: implicit **element-undo replay**, which makes `map` behave like
`compose` and needs no new DSL. It is the most consistent option, but the only breaking one.
Full comparison on fail_fast, inline/fan-out, retries, later failures and data availability:
[O-01 evaluation](findings-and-options.md#o-01-evaluation-compensate_all-vs-compensate_each).

---

## Top findings

**High**

- [F-01](findings-and-options.md#f-01--high--map-elements-that-already-succeeded-are-never-rolled-back): map elements that succeeded are never rolled back (map failure or later failure).
- [F-02](findings-and-options.md#f-02--high--compose-with-retries-resumes-a-child-whose-earlier-steps-were-already-undone): `compose` + `retries` resumes a child whose earlier steps were already undone.
- [F-03](findings-and-options.md#f-03--high--some-failures-skip-rollback-entirely): argument-resolution errors and non-`StandardError` exceptions skip rollback entirely.
- [F-04](findings-and-options.md#f-04--high--an-async_steps-own-compensate--undo-never-run-the-docs-say-they-do): an `async_step`'s own `compensate`/`undo` never run. The docs say they do.

**Medium**: F-05 scheduling-dependent fan-out leftovers · F-06 raising `where`/`guard`
compensates a never-run step · F-07 nested `Halt` inconsistency · F-08 `Reactor.undo` outside the
reactor lock · F-09 units run after their dispatcher's rollback (also escaping a failed map
element) · F-10 composite rollback coverage is asymmetric and invisible in the DSL.

**Low**: F-11 to F-16 (lock gap, async retry telemetry, missing failure attribution, dead collect
default, lock event key asymmetry, interrupt status docs).

What reliably **holds**: compensate-then-reverse-undo ordering (DAG included). Rollback failures
never stop the rollback and are always reported. Retries always finish before compensation, which
runs exactly once. Never-started steps are not compensated (except F-06). Composition rollback is
full, at any depth. Worker runs match inline order. Reactor locks are held through rollback.
Step locks are re-taken for it. A crash re-drives from the last checkpoint.
29 of 41 invariants hold ([invariants.md](invariants.md#coverage-summary)).

## Files

| File | Answers |
|---|---|
| [execution-order.md](execution-order.md) | Rollback algorithm, failure-kind table, construct lifecycles, full order matrix, lock and retry cross-sections |
| [invariants.md](invariants.md) | 41 invariants with status, evidence and existing-spec coverage |
| [findings-and-options.md](findings-and-options.md) | 16 ranked findings, documentation audit, improvement options (proposals) |
| [../evidence/](../evidence/) | Probe harness, 7 probe files, `output.txt` transcript |
