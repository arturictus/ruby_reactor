# Contract: Report Structure

The deliverable's "interface" is the set of documents a maintainer reads and the probe output a
reviewer re-runs. This contract fixes what each must contain so the report can be checked
mechanically (see quickstart.md).

## `analysis/README.md`

1. **Scope & baseline**: commit, constructs covered, what is out of scope.
2. **How to read**: vocabulary (research D4), evidence labels (D5), status/severity scales (D6/D7).
3. **Answers**: one subsection per user question, in this order:
   - Q1 *Are already-executed map elements compensated individually?*
   - Q2 *When a composed reactor fails, are previously completed composed reactors compensated?*
   - Q3 *Would `compensate_all` / `compensate_each` on `map` close a real gap?*

   Each answer MUST open with a one-line verdict (`Yes` / `No` / `Depends: …`), then list the
   conditions, then evidence labels, then links to the matrix rows, invariants and findings.
4. **Top findings**: the High-severity findings, one line each with links.
5. **File index**.

## `analysis/execution-order.md`

1. **Construct lifecycles**: one subsection per construct (step, compose, map inline, map fan-out,
   async_step, async_reactor, background reactor, interrupt). Each has a numbered lifecycle from
   scheduling to terminal state, saying where rollback hooks attach and where locks are held.
2. **Rollback algorithm**: the generic compensate → reverse-undo sequence with a Mermaid diagram.
3. **Order matrix**: one table per construct. Columns: `Scenario id | shape | failure at | mode |
   ordered events | left in place | evidence`. No blank cells. Unreachable cells say
   `not reachable: <reason>`.
4. **Cross-cutting sections**: locks (lifetime vs rollback), retries (attempts vs rollback),
   failure kinds (which path each takes: rollback / no rollback / never-started), each with its
   own table.

## `analysis/invariants.md`

A table or list of `INV-nn` entries with every Invariant field from data-model.md, grouped by
area. It ends with a **coverage summary**: counts by status, and the list of invariants with
`coverage: none`.

## `analysis/findings-and-options.md`

1. **Findings**, ranked High → Low, with every Finding field.
2. **Documentation audit**: a table `file:line | quoted claim | actual | finding id`.
3. **Options**, grouped under the finding they address, with every Option field. The map
   `compensate_all` / `compensate_each` evaluation MUST appear here and compare both shapes on:
   failure semantics (fail_fast on/off), inline vs fan-out, interaction with element retries,
   interaction with a later step failing, and data availability (what `all_elements` / `element`
   would contain).
4. A closing note: every option is a proposal pending later analysis.

## `evidence/output.txt`

Produced by `evidence/run.rb`. It has one block per scenario:

```text
== S-plain-01  a → b(fails) → c   [inline]
expected: run:a run:b compensate:b undo:a => failure(b)
observed: run:a run:b compensate:b undo:a => failure(b)
MATCH
```

`MISMATCH` blocks are kept, not hidden. A `MISMATCH` means the report's expectation was wrong and
the report MUST be corrected to the observed sequence (the observation wins). Scenarios whose
purpose is to show a counter-example set `expected` to the *observed* behavior and state the
violation in the report.

## Cross-reference rules

- Every `[O: S-…]` label in `analysis/*.md` resolves to a block in `output.txt`.
- Every finding lists at least one scenario or `[R]` citation.
- Every High finding has at least two options, each with a stated con (SC-004).
