# Quickstart: Validate Distributed Map Rollback and Bounded Fan-out

A guide to proving each user story end to end. The behavior is specified in
[contracts/](contracts/), and the records in [data-model.md](data-model.md).

## 0. Prerequisites

- Ruby >= 3.0 and `bundle install`.
- Test Redis reachable at `redis://localhost:6780`. The suite refuses to start without it.
- Docker, for the demo acceptance runs and the SC-002 benchmark only.
- If other suites share the test Redis, run the new specs alone first (known flake under load).

## 1. User Story 1: distributed rollback (P1)

```bash
bundle exec rspec spec/ruby_reactor/rollback/distributed_map_rollback_spec.rb
bundle exec rspec spec/ruby_reactor/rollback/map_rollback_recovery_spec.rb
bundle exec rspec spec/ruby_reactor/rollback/map_rollback_spec.rb     # 008 coverage, now via both paths
```

Expected:

| Scenario | Observable outcome |
| --- | --- |
| Fan-out map of 20 elements, `batch_size 5`, a later step fails. This is the spec's 1,000/50 scenario scaled down; §1 Scale covers 10,000/50. | Mid-drain (once rollback jobs are pending): `be_rolling_back`. While draining: no job enqueues more than 5 rollback jobs (`max_burst`); queue depth is not bounded (R-02). After draining: `be_failure`; every element undone once; the steps before the map undone after the last element. |
| Same reactor with an inline map (oracle, I-7) | Same final `Failure` message, step and `rollback_failures` set as the fan-out run. |
| Element 7 fails under atomic | Every started element gets a rollback job. Element 7's job reports `not_needed` and undoes nothing. Skipped indexes get no job. |
| An element's lock is held while its rollback job runs | The job requeues itself, then completes once the lock is free, with no `element_in_flight` failure. After `lock_snooze_max_attempts` requeues it reports `element_in_flight`. |
| An element context expired (row deleted) | Exactly one `context_unavailable` entry for that index, as with the inline map. |
| An element reactor containing an inline (nested) map | The nested map is rolled back inline inside the outer element's rollback job; the log shows nested undos before the outer element's earlier steps. |
| One element's undo raises | The run still undoes the steps before the map. `rollback_failures` holds that element's entry with `map_step` and `element_index`. |
| Interruption raised in an element's second undo, then the job is redelivered | The first undo ran once. The second may run twice. The run finishes its rollback. |
| Rollback job dropped, then `Map::Sweeper.run_once` | The position is re-dispatched and the run finishes. |
| Owner resume dropped, then `RubyReactor::Sweeper.run_once` | The owner is re-enqueued and the run finishes. |
| `Reactor.undo(id)` on a completed run with a fan-out map | Returns with the run `rolling_back`; after draining, `cancelled`. A second `Reactor.undo` while rolling back raises `ValidationError`, and so does `Reactor.cancel`. |
| Inline map rollback | Elements are read 100 at a time, highest index first. Same outcome as before. |

Scale (slow):

```bash
bundle exec rspec spec/ruby_reactor/rollback/map_scale_spec.rb --tag slow
```

Expected: 10,000 elements roll back, and each rollback job loads exactly one element context.

## 2. User Story 2: fan-out map inside a composed child (P2)

```bash
bundle exec rspec spec/map/map_compose_fan_out_spec.rb
```

Expected (drain all jobs):

- Root composes Child; Child has `map … fan_out batch_size: 1`. The root is `be_success` with the
  expected result. Before this change it stayed `running`.
- The same with an interrupt after the map in Child: `be_paused_at(...)`, then `resume`, then
  `be_success`.
- A root step after the compose fails: elements rolled back (distributed), then Child's earlier
  steps, then Root's. The root is `be_failure`.
- A Child element fails under atomic: the root (not only Child's record) is `be_failure`.
- Compose nested two levels deep: the top-level root is `be_success`.
- `Reactor.undo(root id)` on a completed root whose composed child ran a fan-out map: the root is
  `rolling_back`, then `cancelled`. Every element and every earlier step is undone exactly once.
- A root step after the compose fails, and the child step after the map has an undo that fails.
  That failure is recorded before the child hands off, and it still appears in the root's final
  `rollback_failures` after the resume.
- The same child step with a failing undo, reached by a manual undo instead: the failure is in the
  trace, as today for manual undo.

## 3. User Story 3: default batch size (P2)

```bash
bundle exec rspec spec/map/map_batch_size_spec.rb
```

Expected:

- `fan_out` with no batch size, 500 elements: no job enqueues more than 50 element jobs
  (`max_burst`), and all 500 outcomes are collected.
- 20 elements: all 20 enqueued at once.
- `batch_size: 200`: 200 per throw.
- Map metadata stores `batch_size` and `atomic`. `Map::Sweeper` re-dispatch keeps both.

## 4. User Story 4: `atomic` (P3)

```bash
bundle exec rspec spec/map/map_atomic_spec.rb spec/map/map_atomic_async_spec.rb spec/map/atomic_inline_spec.rb
```

Expected:

- No declaration: one element failure fails the map and rolls back the completed elements.
- `atomic false`: the map completes with one `Failure` among the results.
- `fail_fast false`: the same behavior, plus exactly one stderr line starting
  `[RubyReactor] DEPRECATION:` that names `atomic`.
- Both declared: `ValidationError` at class definition.
- An element job payload carrying `"fail_fast" => true` (legacy) is processed as atomic.

## 5. Demo app acceptance (Constitution VI)

Locally, without Docker (test Redis DB 5; run `bin/rails db:prepare` once first):

```bash
cd demo_app
REDIS_URL=redis://localhost:6780/5 RAILS_ENV=test bundle exec rspec \
  spec/reactors/distributed_refund_demo_reactor_spec.rb \
  spec/reactors/composed_fan_out_demo_reactor_spec.rb \
  spec/reactors/default_batch_fan_out_demo_reactor_spec.rb spec/reactors/ar_map_reactor_not_fail_spec.rb
```

Real Sidekiq, in an isolated compose project. `docker-compose.yml` hard-codes container names, so a
second worktree needs its own project plus an override that gives unique `container_name`s and
`ports: !reset []`:

```bash
docker compose -p rr_009 -f docker-compose.yml -f override.yml up -d --build demo-redis demo-sidekiq
docker compose -p rr_009 -f docker-compose.yml -f override.yml run --rm --no-deps demo-app \
  bash -c "bin/rails db:prepare && bin/rails demo:map_execution_undo"
```

Expected output, in order:

- `DistributedRefundDemoReactor`: dispatch, then a `rolling_back` line with progress, then
  `failed`, with refunds equal to charges.
- `ComposedFanOutDemoReactor`: `completed` on the happy path, and `failed` with everything
  unshipped on the failure path.
- `DefaultBatchFanOutDemoReactor`: map metadata `batch_size 50`, and 120 elements collected.

### SC-002 benchmark (manual)

Run `demo-sidekiq` with `command: bundle exec sidekiq -c 10` in the override, then:

```bash
docker compose -p rr_009 -f docker-compose.yml -f override.yml run --rm --no-deps demo-app \
  bin/rails "demo:map_rollback_benchmark[10000]"
```

The task prints two times and their ratio, each timed from the moment `:notify` fails (the
rollback's start) to the end of the run, so the forward run is not counted:

- the serial baseline: the inline-map rollback of the same 10,000 elements, through
  `InlineRefundBenchmarkReactor`, which is today's serial algorithm;
- the distributed rollback time.

Pass: the distributed time is 5× faster or better (SC-002).

## 6. Full checks before PR

```bash
bundle exec rspec
bundle exec rubocop
cd gui && npm test && npm run build   # rolling_back in badge/groups/filters + map rollback progress
grep -rn "fail_fast" lib gui/src documentation README.md demo_app/app demo_app/documentation   # only the deprecated alias, its warning, and legacy normalization remain
```
