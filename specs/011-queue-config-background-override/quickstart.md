# Quickstart: Validate Per-Reactor/Step Queues

A guide to proving each user story end to end. The behavior is specified in
[contracts/](contracts/), and the records in [data-model.md](data-model.md).

## 0. Prerequisites

- Ruby >= 3.0 and `bundle install`.
- Test Redis reachable at `redis://localhost:6780` (`docker start ruby_reactor_redis_test`, or
  `docker run -d --name rr-test-redis -p 6780:6379 redis:7-alpine`).
- If other suites share the test Redis, run the new specs alone first, or on their own DB:
  `RUBY_REACTOR_TEST_REDIS_URL=redis://localhost:6780/3`.
- Dispatch specs run on both backends (`for_each_async_backend`): Sidekiq fake mode and the
  ActiveJob `:test` adapter.

## 1. Declarations and the freeze (US1-AS7, FR-001–FR-004, SC-008)

```bash
bundle exec rspec spec/ruby_reactor/queues/declaration_spec.rb
```

| Scenario | Observable outcome |
| --- | --- |
| `queue :x` in a reactor body, a step class, a `step` block, and a `Class.new` block | `declared_queue` returns `"x"`. The block wins over the step class |
| The same `queue :x` twice; a subclass with no declaration | No error; the subclass reports `"x"` |
| `queue :y` after `queue :x`; `queue nil`; `queue ""` | `ValidationError` naming the class |
| `MyReactor.queue(:z)`, `MyStep.queue(:z)`, `anon.queue(:z)` after the block | `StaticConfigurationError` "Can not modify static configurations in the runtime"; `declared_queue` unchanged |
| `queue` inside a `compose`/`map` block | `ValidationError` naming the child class |

## 2. US1: a reactor on its own queue (P1)

```bash
bundle exec rspec spec/ruby_reactor/queues/reactor_queue_spec.rb
bundle exec rspec spec/ruby_reactor/queues/backend_placement_spec.rb
```

| Scenario | Observable outcome |
| --- | --- |
| `queue :my_specific_queue`, `background after: :first`, `run` | `:first` in the caller; `pending_async_jobs.map(&:queue) == ["my_specific_queue"]`; after a drain, `have_run_step(:second).on_queue(:my_specific_queue)` |
| A step with backoff fails once after the hand-off | The retry job is on `my_specific_queue` |
| The job is deleted after the hand-off, then `Sweeper.run_once` | The re-enqueued job is on `my_specific_queue`, and the run completes |
| `background all: true` | One job on the declared queue. Input validation runs in it |
| No declaration | Job arguments, count and queue equal to today's (exact-argument comparison) |
| A declaration but no `background` | Runs fully in the caller; no jobs |
| Sidekiq with `queue_name = :critical` set after load | Every job class (Worker, StepWorker, map jobs) is on `critical` (F-1 fix) |

## 3. US2: compose and maps across queues (P2)

```bash
bundle exec rspec spec/ruby_reactor/queues/compose_hop_spec.rb
bundle exec rspec spec/ruby_reactor/queues/hop_crash_windows_spec.rb
bundle exec rspec spec/ruby_reactor/queues/rollback_hop_spec.rb
bundle exec rspec spec/ruby_reactor/queues/manual_undo_handoff_spec.rb
bundle exec rspec spec/ruby_reactor/queues/map_queue_spec.rb
bundle exec rspec spec/ruby_reactor/queues/definition_rejections_spec.rb
```

| Scenario | Observable outcome |
| --- | --- |
| `MyReactor` + `StripeBankDeposit` to completion | `have_hopped_queues(:stripe, :my_specific_queue)`; the child's steps run on `stripe`, `:third` on `my_specific_queue`; 3 jobs in total (SC-003) |
| An undeclared composed child; consecutive units on one queue | No hop; one job |
| A crash at each window in [hop-protocol §3](contracts/hop-protocol.md) | After `Sweeper.run_once` and a drain: completed, each step's `:run` trace entry once, no lock contention logged as concurrent advance |
| Duplicate delivery of a hop job (`perform!` twice) | Only one runs steps; the other exits or dedupes |
| `:third` fails | `:third` compensated on `my_specific_queue`; `have_undone_step(:one).on_queue(:stripe)`; `have_undone_step(:second).on_queue(:my_specific_queue)`; `have_hopped_queues(:stripe, :my_specific_queue).during_rollback`; `be_failure` |
| A crash at a rollback hop boundary | The sweeper resumes it on the recorded queue; each undo once; ends `failed` |
| A run paused after `:bank_deposit`, then `MyReactor.undo(id)` | Returns at once; `be_rolling_back`; a second `undo`/`cancel`/`continue` raises; after a drain, cancelled, with undos on their queues |
| A fan-out map whose element reactor declares `queue :deposits` | Element, retry and rollback jobs on `deposits`; the collector and owner resume on the owner's queue |
| An interrupt in the child on `stripe` with `resume: :background`; a retry in the child | The resume job and the retry job are on `stripe` |
| A step inside a map element (inline or fan-out) declares another queue; a hop in a `with_ordered_lock` reactor | `validate_definition!` raises `ValidationError` naming the unit and the reason |
| A reactor with `with_lock`, hopping, with `context_lock_ttl = 2` and a 5s wait before the drain | The lock stays held through the wait (`be_locked`); another run contending on it snoozes; the first completes |

## 4. US3: step queues (P3)

```bash
bundle exec rspec spec/ruby_reactor/queues/step_queue_spec.rb
```

| Scenario | Observable outcome |
| --- | --- |
| `async_step :email, Email` (`queue :emails`) | Step job on `emails`; the parent continues on its queue; `have_run_step(:email).on_queue(:emails)` |
| A block `queue :priority_emails` over the class's `:emails` | Job on `priority_emails` |
| An undeclared `async_step`; `async_reactor` with a declared child | The reactor's queue; the child's queue |
| A lost `async_step` job, then `StepSweeper.run_once` | Re-dispatched on the step's queue |
| `step :another, AnotherStep` (`queue :another_one`) after the hand-off | `have_hopped_queues(:another_one, :my_specific_queue)`; on retry, the requeue is on `another_one` |
| The same step before the `background` point | Runs in the caller; no job |
| A later step fails | `have_undone_step(:another).on_queue(:another_one)` |

## 5. Waiting runs (FR-020, SC-007)

```bash
bundle exec rspec spec/ruby_reactor/queues/waiting_on_spec.rb
bundle exec rspec spec/ruby_reactor/web/api_waiting_on_spec.rb
```

| Scenario | Observable outcome |
| --- | --- |
| A hop to `stripe`, not drained | API `waiting_on == {queue: "stripe", since: …}`; status `running`; a `ruby_reactor.queue.hop` log line |
| Left waiting, `Sweeper.run_once` twice | Never `failed`; a `ruby_reactor.queue.waiting` log line |
| Drained | `waiting_on` is `null` |

## 6. Regression

```bash
bundle exec rspec                 # SC-002: the existing suite passes unchanged
bundle exec rubocop
```

## 7. Demo and Docker acceptance (FR-023, Constitution VI)

```bash
# local, no Docker (test Redis DB 5; run `bin/rails db:prepare` once first)
cd demo_app && REDIS_URL=redis://localhost:6780/5 RAILS_ENV=test bundle exec rspec spec/reactors/queue_demo_reactor_spec.rb
cd demo_app && REDIS_URL=redis://localhost:6780/5 bin/rails demo:queues

# real Sidekiq, with the demo queues consumed. docker-compose.yml uses fixed container names,
# so run an isolated project if another worktree's stack is up.
docker compose -p rr-queues up -d --build demo-redis demo-sidekiq
docker compose -p rr-queues run --rm demo-app bash -c "bin/rails db:prepare && bin/rails demo:queues"
docker compose -p rr-queues down
```

Expected `demo:queues` output: each step and its queue (`reserve`: caller; `charge`/`settle`:
`demo_stripe`; `confirm`: `demo_orders`; `email`: `demo_emails`); the hops; for the failing
variant, the compensation of `confirm`, the undos on their queues, then `failed`; and the manual
`undo` hand-off ending `cancelled`. Then open `localhost:<port>/ruby_reactor` and check the per-step
queues and the "Waiting on …" line, with the `demo_stripe` consumer stopped
(`docker compose -p rr-queues stop demo-sidekiq`).
