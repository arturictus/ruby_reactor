# Quickstart: Validating Reactor Signal Semantics

Runnable checks that prove the feature works end to end. Contracts:
[signals.md](./contracts/signals.md),
[step-helpers.md](./contracts/step-helpers.md),
[observability.md](./contracts/observability.md).

## Prerequisites

```bash
bundle install
docker compose up -d redis     # the suite requires a live Redis (Constitution III)
redis-cli ping                 # expect PONG
```

## Full gate

```bash
bundle exec rspec
bundle exec rubocop
```

Both must pass with no new offences. SC-007 is exactly this command on a clean
tree.

## Scenario 1 — Halt behaves like the old Skipped (US1 / SC-001)

```bash
bundle exec rspec spec/ruby_reactor/skipped_helper_spec.rb \
                  spec/ruby_reactor/rspec/test_subject_skipped_spec.rb \
                  spec/ruby_reactor/integration/ordered_lock_spec.rb \
                  spec/ruby_reactor/sweeper_spec.rb
```

Expected: every previously-passing clean-halt example still passes with
`Halt` / `be_halted` substituted. No assertion other than the signal name and
matcher name changes. A run halted mid-way leaves earlier steps' side effects in
place — assert the undo trace is empty.

## Scenario 2 — A skipped step keeps the reactor going (US2 / SC-002)

Reactor shape to exercise:

```ruby
step :first  # Success(1)
step :maybe  # skip!(:from_skip)
step :last   # argument :v, result(:maybe)  → Success(v)
```

Expected: `last` runs and sees `:from_skip`; the run is `be_success`, the
context status is `completed`, the trace holds `{ type: :skipped, step: :maybe }`,
and `maybe` is absent from the undo stack. Repeat with `:last` as the reactor's
`return_step` to confirm the skipped value is the run's result.

Rollback check: make a fourth step fail and assert the undo trace contains
`first` but not `maybe`.

## Scenario 3 — Helpers exit the step (US3 / SC-003)

```bash
bundle exec rspec spec/ruby_reactor/step_signals_spec.rb   # new suite
```

Cover, for both an inline block and a class step:
- each of `success!` / `fail!` / `skip!` / `halt!` followed by a line that
  raises if reached;
- a helper called from a nested method;
- a helper called inside `begin … rescue Exception … end` — the intended signal
  must still win (FR-021);
- an `ensure` block in the step body — it must still run.

## Scenario 4 — Retry interaction (SC-008 / SC-009 / SC-010)

```bash
bundle exec rspec spec/ruby_reactor/retry_signals_spec.rb  # new suite
```

Matrix to cover — count invocations with a counter in the step body:

| Step retry config | Signal | Expected attempts | Expected outcome |
|---|---|---|---|
| `max_attempts: 3` | `fail!(e)` | 3 | retries exhausted → rollback |
| `max_attempts: 3` | `fail!(e, retry: false)` | 1 | immediate rollback, no backoff sleep |
| `max_attempts: 3` | `skip!(v)` after 2 failures | 3 | run completes, no exhaustion failure |
| `max_attempts: 3` | `halt!(reason:)` after 2 failures | 3 | run halts, no rollback |
| none | `fail!(e, retry: true)` | 1 | flag cannot grant retries |

Async variant: run the same non-retryable case through the worker and assert no
job was re-enqueued.

## Scenario 5 — Compensation honesty (US4 / SC-005)

Reactor with one step defining `compensate`/`undo` and one defining neither;
force a later failure.

Expected trace: the defined step's entries carry `skipped: false` and its real
result; the undefined step's carry `skipped: true`. Rollback completes in both
cases, and a genuinely failing compensation still raises `CompensationError`.

## Scenario 6 — Migration guard (SC-004)

```ruby
RubyReactor.Skipped(reason: "old halt shape")
# => ArgumentError naming Halt
```

Also assert a context stored with status `"skipped"` is read back as a halted
run (upgrade path), and that `Halt` does not respond to `skipped?`.

## Scenario 7 — Docs and demo

```bash
grep -rn "Skipped(reason:" README.md documentation/ demo_app/ llms.txt llms-full.txt
```

Expected: no hits — every clean-halt example uses `Halt` / `halt!`, and the
per-step skip is documented with a value-carrying example.

## Scenario 8 — Dashboard states (FR-036…FR-040 / SC-011 / SC-012)

```bash
cd gui && npm install && npm test        # vitest component suites
cd .. && rake build:ui                   # rebuild the shipped bundle
git status --short lib/ruby_reactor/web/public   # expect regenerated assets staged
```

Component-test fixtures to add:

- **Skipped step in the DAG** — a context whose `intermediate_results` include
  the skipped step *and* whose trace holds `{ type: 'skipped', step }`. Assert
  the node renders skipped, **not** completed. This is the regression that
  matters: value presence alone must not mean completed.
- **Halted run** — trace ending in `{ type: 'halt', step }`. Assert the halting
  node is marked halted and that unreached nodes are not marked cancelled.
- **Rollback list** — one step with a compensate entry `skipped: false`, one
  with `skipped: true`. Assert two distinct labels, and that the unimplemented
  one is not described as executed.
- **Status vocabulary** — badge, filters, and `aggregateByClass` handle
  `halted`; a legacy `skipped` row still lands in the clean-outcome bucket.

Manual smoke:

```bash
rake server:start   # http://localhost:9292
```

Run a reactor that skips a step and one that halts; confirm the list filter, the
badge, the DAG, and the step inspector all read correctly.
