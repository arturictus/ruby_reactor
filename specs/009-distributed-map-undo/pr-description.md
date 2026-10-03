# PR description draft: 009 Distributed Map Rollback and Bounded Fan-out

## Regression bar (T003, before any change, at `c9711cc1`)

- `bundle exec rspec spec/map spec/ruby_reactor/rollback spec/ruby_reactor/map spec/compose_spec.rb spec/single_worker_map_spec.rb`:
  **192 examples, 0 failures**.
- `bundle exec ruby specs/007-execution-flow-analysis/evidence/run.rb | tail -1`:
  **64 scenarios, 64 match, 0 mismatch**.

## `RollbackHandedOff` rescue audit (T078)

`RollbackHandedOff` is an `Error::Base` (a `StandardError`), so every broad rescue between
`MapStep#compensate`/`#undo` and the handlers (`Executor`, `Reactor#undo`) was checked:

- `rescue Error::Rescuable` in `CompensationManager#compensate_step_body` / `#undo_step`,
  `StepExecutor#safe_execute_step_sync`, `StepCoordination`, `StepBuilder#resolve_arguments`,
  `MapStep#collect_results`: pass it through, since `Rescuable.===` excludes it.
- `Executor#aborting_on_interruption`: re-raises it without marking the run `aborted`.
- `StepExecutor#execute_step`'s `rescue Exception`: emits its step event and re-raises;
  `track_interrupted_construct` ignores it.
- `rescue StandardError` in `StepCoordination` (lock/semaphore release, ordered-lock advance,
  `chain_failed?`), `OrderedLockSupport`, `MiddlewareRunner#on`, `Executor#publish_completion_signal`
  / `#release_one`, `Worker` (retries-exhausted and deserialization helpers), `Reactor` reloads and
  `Map::Sweeper`: none wraps a rollback call, so none can see it.

No explicit re-raise was needed.

## Results

- Gem suite: `bundle exec rspec` → **1479 examples, 0 failures, 2 pending** (the pending pair is
  US2-AS2, an interrupt inside a composed child, unsupported on main; see research R-03).
  `bundle exec rspec --tag slow` → 2 examples, 0 failures (10,000-element inline and fan-out
  rollbacks).
- T003 regression set: 192 → now part of the above, all green.
- 007 evidence harness: **64 scenarios, 64 match**. S-map-12's expected order changed (009 R-08:
  element undos run in their own jobs, after the elements' independent `async_step` units);
  the harness drains `MapElementRollbackWorker` too.
- `bundle exec rubocop`: no offenses.
- GUI: `npm test` 68 passed; bundle rebuilt into `lib/ruby_reactor/web/public/`.
- Demo specs (`REDIS_URL=redis://localhost:6780/5`): 145 examples, 0 failures.
- Docker acceptance (isolated project `rr_009`, real Sidekiq): `demo:map_execution_undo`
  prints SUCCESS for all four scenarios (distributed refund with a `rolling_back` progress line,
  composed fan-out happy and failure paths, default batch size 50 with 120 collected).

## Constitution re-check (T086)

- Docs (R-17): README, `data_pipelines.md`, `background_and_async.md`, `composition.md`,
  `core_concepts.md`, `testing.md`, `demo_app/documentation/data_pipelines.md`,
  `specs/future_improvements.md`.
- CHANGELOG: Features (default batch size, distributed rollback, `rolling_back`, router methods,
  matcher, undo lock), Bug Fixes (composed fan-out, owner resume, sweeper re-dispatch, save before
  release, undo record, `exception_class`), Deprecations (`fail_fast` → `atomic`).
- Demo per story, one reactor per file: US1 `DistributedRefundDemoReactor` +
  `DistributedRefundElementReactor` (+ `InlineRefundBenchmarkReactor`), US2
  `ComposedFanOutDemoReactor` + `ComposedFanOutChildReactor` + `ComposedFanOutItemReactor`, US3
  `DefaultBatchFanOutDemoReactor` + `DefaultBatchNumberReactor`, US4 `ar_map_reactor_not_fail.rb`
  on `atomic false`. Rake: `demo:distributed_map_rollback`, `demo:composed_fan_out`,
  `demo:default_batch_size`, grouped as `demo:map_execution_undo` (in `demo:all`), plus
  `demo:map_rollback_benchmark`. Specs use the shipped surface (`be_rolling_back` added).
- `git diff main -- spec | grep '^+.*inline!'`: none besides T041's
  `Sidekiq::Testing.inline! { reactor.run(items) }` in `distributed_map_rollback_spec.rb`.

## SC-002 benchmark (T084) — not demonstrated

Run in the isolated `rr_009` stack, `demo-sidekiq -c 10`, `demo:map_rollback_benchmark[10000]`
(each side timed from `:notify`'s failure to the end of the run):

```
serial (inline map):                  14.57s, 17286 refunds
distributed (fan-out, batch_size 10): 118.60s, 22714 refunds, failed
ratio: 0.1x
```

Invalid: both sides refunded more than 10,000 elements. `demo:flush_redis` restarts the recovery
sweeper, which (a) re-enqueued the in-process inline run into a worker (known follow-up "Sweeper
re-enqueues in-progress inline runs"), and (b) re-dispatched not-yet-thrown element jobs of the
fan-out map (review finding F1), so elements ran and were refunded twice and the distributed run
shared Sidekiq with that duplicate work. Rerun after fixing F1, with the sweeper disabled.
