# Quickstart: Validating the Remediation

**Feature**: [spec.md](./spec.md) | **Contract**: [contracts/public-api.md](./contracts/public-api.md)

This is a run guide, not a test suite. Each scenario says what to set up, what to run, and what
the result must be. The scenario ids (R1–R6, P1–P5) are the permanent regression specs that
FR-027 requires. Each must **fail on `ca963444`** before its fix lands.

## Prerequisites

```bash
docker compose up -d redis-test        # gem suite Redis on :6780
bundle install
```

A demo acceptance run from this worktree needs its own compose project. The container names
in `docker-compose.yml` are fixed, and another worktree may own them:

```bash
docker compose -p rr_step_locks -f docker-compose.yml -f <override-with-unique-names>.yml \
  up -d --build demo-redis demo-sidekiq
```

Do not run the gem suite and the demo suite at the same time on the same test Redis. Both
flake under load.

## Scenarios

Files named below are the target behavior files from research R-12.

### R1: Rollback under contention (US1, FR-001–FR-004)

`spec/ruby_reactor/step_coordination/rollback_under_contention_spec.rb`

- **Setup**: a synchronous reactor. `:charge` is a step class with `with_lock` (default `wait:`)
  and an `undo` that records itself. The next step takes the same key as an external owner,
  releases it after ~0.5 s from a thread, then raises.
- **Expect**: the undo ran, and `result.rollback_failures == []`.
- **Variant**: `rollback_wait: 0.2` and a 2 s hold. Expect the undo not to have run, and
  `result.rollback_failures` to contain
  `{step: :charge, kind: :undo, key:, reason: :coordination_unavailable}`.
- **Variant**: an undo that raises. Expect an entry with `reason: :raised`.
- **On `ca963444`**: the undo did not run, and `Failure` has no `rollback_failures`.

### R2: Parent rate limit across a composed park (US2-2, FR-007)

`spec/ruby_reactor/step_coordination/park_spec.rb`

- **Setup**: a `background all: true` parent with `with_rate_limit`, composing a child whose
  first step has `with_lock`. Hold the child's key externally.
  1. Perform the worker job once. It parks.
  2. Release the key.
  3. Perform again.
- **Expect**: `have_rate_limit_count(1)` on the parent's key. The no-contention control is
  also 1.
- **On `ca963444`**: 2.

### R3: Synchronous out-of-turn ordered step (US3-1, FR-011)

`spec/ruby_reactor/step_coordination/ordering_parity_spec.rb`

- **Setup**: a synchronous reactor with a strict `with_ordered_lock` step.
  - E1, in a thread, sleeps inside the step.
  - E2 runs synchronously and gets a contention Failure.
  - E3 runs after E1 finishes.
- **Expect**: E3's step body ran, and its value is present.
- **On `ca963444`**: E3 is `success?`, but its step value is nil and its body did not run.

### R4: Parent lock across a composed park (US2-1, FR-006)

`park_spec.rb`

- **Setup**: as R2, but the parent has `with_lock`. After the first (parking) perform, check
  the parent key.
- **Expect**: `be_locked` on the parent key between the two performs. It is released after the
  second perform completes. There is exactly one `:lock_acquired` for the parent key across
  both performs.
- **On `ca963444`**: released after the first perform.

### R5: Middleware attribution (US5, FR-020, FR-022)

`spec/ruby_reactor/step_coordination/attribution_spec.rb`

- **Setup**: a `background all: true` reactor with `with_lock`, a step with `with_lock`, and a
  recording middleware. Park the step once, then complete.
- **Expect**:
  - Every reactor-key event has `coordinating_step == nil`.
  - Every step-key event names `:charge`.
  - One `:snooze_step` and no `:failed_step`.
- **Docs check**: `grep -n "current_step" documentation/middlewares.md` returns no attribution
  example.

### R6: Background-result park inside a composed child (US2-8, F10)

`park_spec.rb`

- **Setup**: a `background all: true` parent composes a child that has an `async_step` and a
  step reading `result(:that_async_step)`.
  1. Drive the parent's worker. It must park.
  2. Drain the async_step job.
  3. Drive again.
- **Expect**: the first drive raises and snoozes, and does not fail. The second completes with
  the child's value.
- **On `ca963444`**: `Failure: Step 'child' failed … parking the call`. The planning repro
  confirmed this.

### P1: Stale batch skips the step (US3-3, FR-013)

`ordering_parity_spec.rb`. Use an ordered step with retries. Make its position stale: drain the
batch past it with `OrderedLock.skip!` or the poison pill, then start a new batch on the same
key. Let the retry run.

- **Expect**: `be_skipped` with reason `:ordered_lock_stale_batch`, and the body count is
  unchanged.

### P2: Heartbeat stops on an abnormal exit (US3-5, FR-014)

`ordering_parity_spec.rb`. Use an ordered step whose body raises `NoMemoryError`, raised
directly in the test body.

- **Expect**: the heartbeat thread is not alive afterwards. The position is not advanced: the
  cursor is unchanged, and the poison pill releases it.

### P3: Gate parity (FR-010)

`ordering_parity_spec.rb`. Run a table over `go`, `wait`, `skip_chain`, `stale` and `drained`.
For each state, force it through real Redis state (no stubbing of `OrderedLock`) at the reactor
level and at the step level.

- **Expect**: the outcomes in the data-model table.

### P4: Background step park state (US4, FR-017–FR-019)

`park_spec.rb`, using a real Sidekiq worker (Constitution III).

1. Park an ordered `async_step` on contention.
2. Have the parent checkpoint newer progress.
3. Release the key.
4. Drain.

- **Expect**:
  - The redelivery reuses the original nonce.
  - The parent's checkpoint is intact.
  - `CoordinationSerializer` shows `waiting` for the step while it is parked.
  - The root blob was not written by the step worker: its `updated_at` is unchanged across the
    park.

### P5: Direct invocation attribution (US5-3, FR-021)

`attribution_spec.rb`. The body of step `:outer` calls `ChargeStep.run(args, context)` while
the key is held elsewhere.

- **Expect**: the `Contended` message and `coordinating_step` name `ChargeStep`, not `:outer`.

## Full gates (SC-011)

```bash
bundle exec rubocop
bundle exec rspec
bundle exec rspec spec/ruby_reactor/step_coordination     # the behavior-named suite
ls spec/ruby_reactor/step_coordination | grep review_fixes # must print nothing (FR-028)

# demo acceptance, from this worktree's isolated compose project
docker compose -p rr_step_locks run --rm --no-deps demo-app \
  bash -c "bin/rails db:prepare && bin/rails demo:step_lock"
docker compose -p rr_step_locks run --rm -e RAILS_ENV=test demo-app \
  bundle exec rspec spec/reactors/step_lock_demo_reactor_spec.rb
```

The demo run must print both rollback lines: an undo that waited and ran, and one reported on
the failure through `rollback_failures`. The demo spec asserts them with
`have_rollback_failure`.
