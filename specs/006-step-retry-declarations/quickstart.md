# Quickstart: Validating Step-Scoped Retry Declarations

The API is in [contracts/dsl-surface.md](contracts/dsl-surface.md) and the resolution rules
are in [data-model.md](data-model.md).

## Prerequisites

- Ruby >= 3.0, `bundle install`
- Redis reachable by the suite (Constitution III): `docker compose up -d redis` or a local
  `redis-server`
- For the demo: `docker compose up` (see the constitution, Principle VI §4)

## Phase A: `retry_defaults` removed (validate before starting Phase B)

1. The removal error fires at definition time:

   ```bash
   bundle exec ruby -Ilib -e 'require "ruby_reactor"; Class.new(RubyReactor::Reactor) { retry_defaults max_attempts: 3 }'
   ```

   Expected: `RubyReactor::Error::DeprecatedDslError`, with a message pointing to step-level
   `retries`.

2. No references remain outside the removal stub and its spec:

   ```bash
   grep -rn "retry_defaults" lib spec demo_app README.md documentation llms*.txt
   ```

   Expected: only `lib/ruby_reactor/dsl/reactor.rb` (the stub) and the spec asserting it
   raises.

3. The full suite and lint are green:

   ```bash
   bundle exec rspec && bundle exec rubocop
   ```

## Phase B: `retries` on step classes

Run the feature specs, then the full suite:

```bash
bundle exec rspec spec/ruby_reactor/step_retries/
bundle exec rspec && bundle exec rubocop
```

What the feature spec must show (each maps to a spec story):

| Scenario | Expected | Spec |
| --- | --- | --- |
| Class declares 3 attempts, body fails twice, reactor has no wiring | success on attempt 3 | US2 |
| Same class, body always fails | `MaxRetriesExhaustedFailure`, 3 attempts, compensation runs | US2 |
| Inline `retries` vs class `retries`, same values and failures | same attempts, delays, outcome | US3 |
| Class `retries` + step block `retries` | `ValidationError` at reactor definition | US4 |
| Class `retries max_attempts: 1` | not retried | US4 |
| Same class under `background all: true` (drained) | attempts requeued, same count | US5 |
| Same class as `async_step` | `StepWorker` honors the class policy | US5 |
| Subclass without / with its own `retries` | inherits / overrides; parent unchanged | US6 |
| `failing_at` / `mock_step` on a class step | still retried under the class policy | US7 |
| `steps[:x].retry_source` | `:step_class` / `:step_block` / `:none` | US7 |
| `ChargeCard.run(args)` directly, failing | one attempt, `Failure` returned | FR-013 |
| `retries backoff: :bogus` on a class | `ArgumentError` at class definition | FR-004 |

## Demo acceptance run

```bash
docker compose run --rm demo-app bin/rails demo:step_retry
docker compose run --rm demo-app bundle exec rspec spec/reactors/step_retry_demo_reactor_spec.rb
```

The rake task prints three outcomes:

1. a class step that succeeds after retries (`attempts=3 success?=true`);
2. a class step that exhausts its retries, with an earlier step compensated
   (`success?=false attempts=3 compensated=true`);
3. a step with no declaration that is attempted once (`attempts=1`).

When running from a git worktree, pass an isolated compose project name (`-p <name>`) so
the fixed container names don't collide with another worktree's stack.
