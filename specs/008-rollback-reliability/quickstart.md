# Quickstart: Validating Reliable Rollback

This guide checks that the feature does what [spec.md](spec.md) promises.

- Behavior contract: [contracts/rollback-semantics.md](contracts/rollback-semantics.md)
- API changes: [contracts/api-surface.md](contracts/api-surface.md)

## Prerequisites

```sh
docker start ruby_reactor_redis_test 2>/dev/null \
  || docker run -d --name rr-test-redis -p 6780:6379 redis:7-alpine
bundle install
```

Don't run the gem suite and the demo suite at the same time against the same test Redis. Their
per-example flushes wipe each other's state.

## 1. Feature specs (SC-001, SC-003, SC-005)

```sh
bundle exec rspec spec/ruby_reactor/rollback
bundle exec rspec spec/ruby_reactor/dsl/async_step_spec.rb
```

**Expected**: all green. Each example fails when run against baseline `faf90e8d`. That is the
Red step: check it once by running the new files on a checkout of the baseline.

| File | Proves |
|---|---|
| `map_rollback_spec.rb` | US1: inline and fan-out map compensate and undo, `fail_fast false`, collect failure, nested map/compose, manual undo, element rollback failure attribution |
| `map_fan_out_settle_spec.rb` | US1-3 / SC-003: 100 seeded shuffled drain orders, 0 completed elements left with a non-empty undo stack. Skipped slots stop the sweeper from re-dispatching |
| `compose_retry_spec.rb` | US2: `retries` on `compose`/`async_reactor` rejected; a child step's own retries; a failed child is not re-run; park/resume does not re-run |
| `failure_rollback_spec.rb` | US3: transform, source and result path raising; unknown errors; non-`StandardError` exceptions (`NotImplementedError`, `SystemStackError`, custom `Exception`) in a body, a transform, a compensate and an undo; `CompensationError` attribution; worker-side resolution |
| `aborted_execution_spec.rb` | US3-5: an `Interrupt` re-raised unchanged, status `aborted`, skipped by the sweeper, `Reactor#undo` rolls it back; an interruption mid-rollback keeps only the entries not yet undone; an enclosing `Timeout.timeout` still fires |
| `removed_dsl_spec.rb` | US6: `where`/`guard` rejected on `step`, `async_step` and `interrupt`; `Skipped` from the body continues the reactor |
| `async_step_compensate_spec.rb` | US4: compensate once after the final attempt, not on a retried success, no double compensation with a reader, inline `undo` rejected, class `undo` warned, `compensation` on the unit record |

## 2. Slow scale check (SC-006)

```sh
bundle exec rspec spec/ruby_reactor/rollback --tag slow
```

**Expected**: a 10,000-element map fails after all elements succeed (its collect step raises) and
rolls every element back. There is no `ContextTooLargeError`, and the parent context size is about
the same as for a 10-element map.

## 3. 007 regression harness (SC-002)

```sh
bundle exec ruby specs/007-execution-flow-analysis/evidence/run.rb \
  | tee specs/007-execution-flow-analysis/evidence/output.txt
```

**Expected**: `64 scenarios, 64 match, 0 mismatch` (S-edge-03b is new in the 2026-09-27 revision).

- Only the scenarios listed in [contracts/rollback-semantics.md §3](contracts/rollback-semantics.md#3-canonical-sequences-old--new)
  have their `expected:` sequences updated.
- `git diff` on the probe files must touch only those scenario ids.

## 4. Full suite and style (SC-009)

```sh
bundle exec rspec
bundle exec rubocop
```

## 5. Demo acceptance (Constitution VI, SC-009)

Use an isolated compose project, because the fixed container names collide across worktrees.
Create an override file that gives unique `container_name`s and `ports: !reset []` for
`demo-redis` and `demo-app`, then:

```sh
docker compose -p rr_rollback -f docker-compose.yml -f /tmp/rr_rollback.override.yml \
  up -d --build demo-redis demo-sidekiq
docker compose -p rr_rollback -f docker-compose.yml -f /tmp/rr_rollback.override.yml \
  run --rm --no-deps demo-app bash -c "bin/rails db:prepare && bin/rails demo:rollback_reliability"
docker compose -p rr_rollback -f docker-compose.yml -f /tmp/rr_rollback.override.yml \
  run --rm --no-deps demo-app bash -c "bundle exec rspec spec/reactors/map_refund_demo_reactor_spec.rb spec/reactors/compose_retry_demo_reactor_spec.rb spec/reactors/argument_failure_demo_reactor_spec.rb spec/reactors/async_step_compensate_demo_reactor_spec.rb"
```

**Expected** output of `demo:rollback_reliability`, one block per scenario:

- **Map refund**: charges for orders 0..N-1 are refunded when order N fails, and all of them are
  refunded when the post-map step fails.
- **Compose retry**: the child's flaky step retries inside the child. The child's first step runs
  once. A later failure undoes each child step once.
- **Argument failure**: the earlier step is undone, and the failure names the step whose transform
  raised. A step class that raises a non-`StandardError` (`NotImplementedError`) is rolled back the
  same way.
- **`async_step` compensate**: the unit's record shows `compensation.status = completed` after its
  retries are exhausted.

`demo:all` includes the new task.

## 6. Documentation check (SC-007)

Search the README and `./documentation` for `where`, `guard`, `ConditionError`, and `retries` inside
a `compose`/`async_reactor`: the only hits are migration notes (SC-011).

For each row in 007 [findings-and-options.md §2](../007-execution-flow-analysis/analysis/findings-and-options.md#2-documentation-audit)
tied to F-01..F-06 or F-13, open the cited README/documentation line and confirm it describes the
new behavior. The 007 `invariants.md` shows INV-06, 07, 13, 19, 20, 22 and 24 as **HOLDS**.
