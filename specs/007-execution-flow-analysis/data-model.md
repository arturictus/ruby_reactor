# Data Model: Execution Flow & Compensation Analysis

The "data" here is the report's own structure. Every entity below has a stable ID so report files
can cross-reference each other and cite probes.

## Scenario

A reactor shape + failure location + conditions. It is one matrix cell, and usually one probe.

| Field | Description |
|---|---|
| `id` | `S-<area>-<nn>`; area ∈ `plain`, `retry`, `compose`, `map`, `async`, `bg`, `lock`, `intr`, `edge` |
| `shape` | Constructs and nesting, e.g. `a → compose(c1 → c2) → b` |
| `failure_at` | Which step fails and how (`returns Failure`, `raises`, `contended`, `validation`, `compensate fails`, …) |
| `mode` | `inline` or `worker` (+ which worker path) |
| `conditions` | Locks / retries / fail_fast / fan_out flags in effect |
| `expected` | Ordered event list the report claims (see Trace event) |
| `left_in_place` | Completed work that nothing rolls back |
| `evidence` | `[R]`, `[O]`, `[T]` labels (research D5) |

Rule: a matrix cell is **filled** when `expected` and `left_in_place` are both stated, or when it is
marked `not reachable` with a one-line reason (SC-001).

## Trace event

One entry in an observed or expected sequence.

| Kind | Format | Source |
|---|---|---|
| Body | `run:<step>`, `compensate:<step>`, `undo:<step>` | probe step bodies |
| Element body | `run:<step>[<i>]`, `undo:<step>[<i>]` | probe map element steps |
| Middleware | `<event>:<subject>` e.g. `lock_acquired:acct:1`, `retry_attempt:charge#2` | recorder middleware |
| Outcome | `=> success`, `=> failure(<step>)`, `=> halt`, `=> paused` | probe footer |

Nested reactors prefix the step with the child name when they would otherwise be ambiguous,
e.g. `run:child.c1`.

## Invariant

| Field | Description |
|---|---|
| `id` | `INV-<nn>` |
| `statement` | A testable proposition ("Compensation never runs for a step whose body never started") |
| `scope` | Constructs/modes it applies to |
| `status` | `HOLDS` · `VIOLATED` · `CONDITIONAL` · `UNDETERMINED` (research D6) |
| `conditions` | Required when `CONDITIONAL` |
| `evidence` | `[R]`/`[O]`/`[T]` labels; a `VIOLATED` status MUST cite a reproducible counter-example (`[O]`) |
| `coverage` | Existing spec(s) exercising it, or `none` |

## Finding

| Field | Description |
|---|---|
| `id` | `F-<nn>` |
| `title` | One line |
| `severity` | `High` · `Medium` · `Low` (research D7) |
| `scenario` | Scenario id(s) that show it |
| `reader_expects` | What someone reading the DSL/docs would expect |
| `actual` | What happens, with evidence |
| `doc_conflict` | Quoted README/documentation text + `file:line`, or `none` |
| `related` | Invariant ids |

## Improvement option

| Field | Description |
|---|---|
| `id` | `O-<finding>-<letter>` e.g. `O-03-a` |
| `addresses` | Finding id(s) |
| `sketch` | DSL/behavior shape (pseudo-code allowed) |
| `pros` / `cons` | At least one con is required (SC-004) |
| `compatibility` | Breaking? Migration impact? |
| `open_questions` | What must be decided before choosing |
| `status` | Always `proposal`, never a decision |

## Relationships

```text
Scenario 1─* Trace event
Scenario *─* Invariant   (a scenario is evidence for invariants)
Finding  *─* Scenario    (shown by)
Finding  *─* Invariant   (violates / conditions)
Option   *─1..* Finding  (addresses)
```
