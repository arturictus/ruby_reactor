# Quickstart: Validate the Rollback and Resume Follow-ups

A guide to proving each user story end to end. The behavior is specified in
[contracts/](contracts/), and the records in [data-model.md](data-model.md).

## 0. Prerequisites

- Ruby >= 3.0 and `bundle install`.
- Test Redis reachable at `redis://localhost:6780` (`docker start ruby_reactor_redis_test`, or
  `docker run -d --name rr-test-redis -p 6780:6379 redis:7-alpine`).
- If other suites share the test Redis, run the new specs alone first (known flake under load).
- The concurrency specs use threads and real Redis in Sidekiq fake mode. Only the US4 spec marked
  `inline` uses `Sidekiq::Testing.inline!` (R-14).

## 1. US1: the sweeper leaves live caller-process runs alone (P1)

```bash
bundle exec rspec spec/ruby_reactor/caller_process_liveness_spec.rb
bundle exec rspec spec/ruby_reactor/sweeper_spec.rb
```

| Scenario | Observable outcome |
| --- | --- |
| Synchronous run blocked in a step (latch), `Sweeper.run_once` called meanwhile | Returns 0 for that run, `be_locked` on `async:<id>`, and the step's counter is 1 after the latch opens |
| Same, `context_lock_ttl = 1`, the step blocks 3s, sweeping every 0.5s | Never re-enqueued (the auto-extender renews the lock) |
| A forked child runs the reactor, and is `SIGKILL`ed mid-step | Within `context_lock_ttl + 1s`, `Sweeper.run_once` re-enqueues it once (spec tagged `:fork`) |
| Synchronous run hands off at a fan-out map and returns | Swept as before (lock released after the final save) |

## 2. US2: no lost progress from the caller's last save (P1)

```bash
bundle exec rspec spec/ruby_reactor/executor/caller_save_race_spec.rb
bundle exec rspec spec/ruby_reactor/worker_lock_then_load_spec.rb
```

| Scenario | Observable outcome |
| --- | --- |
| A middleware on the map step's `:complete_step` drains jobs while the caller still holds the lock | The owner Worker waits or snoozes and loads nothing. After a second drain: `be_success`, and each step after the map ran once (`have_run_step`) |
| Same, with the fix reverted (regression proof, run once while writing the spec) | The final save overwrites the Worker's progress, and the run is stuck `running` |
| Worker started while another owner holds `async:<id>` for longer than 2s | Snoozes as `ContextLockContention`, nothing written; runs after release on fresh state |
| Inline `continue` reaching a fan-out map | Same as the first row |

## 3. US3: contended resume is accepted (P1)

```bash
bundle exec rspec spec/ruby_reactor/interrupts/contended_resume_spec.rb
bundle exec rspec spec/ruby_reactor/rollback/resume_guard_spec.rb   # updated: no longer raises
bundle exec rspec spec/ruby_reactor/worker_snooze_admitted_spec.rb
```

| Scenario | Observable outcome |
| --- | --- |
| `hold_lock(<reactor lock key>)`, then `continue` with a valid payload | Returns `DispatchResult`, the run is `running`, a `ruby_reactor.resume.deferred reason=lock` line is logged, and one Worker job is enqueued |
| Release the lock, drain | `be_success`; the interrupt's result equals the payload |
| Lock held across 25 snoozes (`lock_snooze_max_attempts = 20`) | Never `failed`; one `ruby_reactor.resume.waiting` warning; resumes after release |
| Invalid payload while the lock is held | Validation failure returned (the class method raises `InputValidationError`); `be_paused`; no job enqueued; no claim stored |
| A second `continue` for the same interrupt while deferred | Raises `ValidationError` "already resumed" |
| Semaphore with no free slot | Same as the first three rows |
| `Reactor.cancel` before draining | The Worker loads `cancelled` and does nothing |

## 4. US4: exactly one of two simultaneous resumes (P2)

```bash
bundle exec rspec spec/ruby_reactor/interrupts/resume_claim_spec.rb
```

| Scenario | Observable outcome |
| --- | --- |
| 200 iterations: two threads released by a barrier call `continue` for the same interrupt | Exactly one returns, one raises "already resumed"; the steps after the interrupt run once per run; the stored result is the winner's payload |
| Same, inside `Sidekiq::Testing.inline!` (the one justified inline spec) | Same |
| `resume: :background` interrupt | Exactly one Worker job is enqueued |

## 5. US5: several interrupts resumed at once (P2)

```bash
bundle exec rspec spec/ruby_reactor/interrupts/concurrent_interrupts_spec.rb
bundle exec rspec spec/ruby_reactor/multiple_interrupts_spec.rb   # existing, unchanged outcomes
```

| Scenario | Observable outcome |
| --- | --- |
| Paused at A and B. Thread 1 resumes A, and a step after A blocks on a latch. Thread 2 resumes B | Thread 2 gets `DispatchResult` (`reason=run_busy`). The latch opens, the run pauses at B, then a drain lets the Worker apply B: `be_success`, both results, each applied once |
| 2 to 5 ready interrupts all resumed from threads | All accepted; final `be_success`; each interrupt result applied once |
| Resume of B with an invalid payload while A runs | Validation failure; no claim; B stays ready |
| A's resume fails and rolls back after B was accepted | The Worker loads `failed` and returns; B's result never applied |
| The run is executing its first run in a worker, and B's dependencies are complete | Accepted; the run does not stay paused at B |

## 6. US6: manual undo finishes a cut-off `compensate` (P2)

```bash
bundle exec rspec spec/ruby_reactor/rollback/aborted_execution_spec.rb   # extended
```

| Scenario | Observable outcome |
| --- | --- |
| Step X fails; X's `compensate` raises `SignalException` part-way (caller process) | The run is `aborted`, and `rollback` carries `step: X`, `compensated: false` and the arguments; the API shows `pending_compensation` |
| `Reactor.undo(id)` | X's `compensate` runs again with the same arguments and a `RecordedFailure` reason (or the original string), before every undo; `cancelled` |
| Interruption after X's `compensate` returned (during the undo stack) | Manual undo does not re-run `compensate`, and replays only the remaining entries |
| Re-run `compensate` returns `Failure` | A `:failed_compensation` event and trace entry; the undo stack is still replayed |
| X inside a composed child; X inside an inline map element | Re-run before that child's or element's undos |

## 7. US7: `undo_all` (P3)

```bash
bundle exec rspec spec/map/map_undo_all_spec.rb
bundle exec rspec spec/ruby_reactor/dsl/map_undo_all_dsl_spec.rb
bundle exec rspec spec/map/map_undo_all_spec.rb --tag slow   # 10,000 elements (SC-007)
```

| Scenario | Observable outcome |
| --- | --- |
| Fan-out map of 20 elements with `undo_all`, a later step fails | One call with 20 results in index order; no element undo ran; no rollback jobs enqueued; the steps before the map undone after the call; `have_run_undo_all(:map).with_elements(20)` |
| Atomic fan-out map, element 7 fails | Called with the completed results only; element 7 rolled itself back |
| Inline map, same reactor | Same outcome |
| The block raises | `have_rollback_failure(:map)` with `kind: :undo_all`; the steps before the map are still undone |
| No element completed | Not called |
| `Reactor.undo(id)` of a completed run | Called once |
| Declared twice or without a block | `ValidationError` at class load |
| 10,000 completed elements (slow) | One call; zero per-element undos; the process's memory is flat across the enumeration (measured as in 009 SC-001) |

## 8. Full suite and style

```bash
bundle exec rspec
bundle exec rubocop
```

## 9. Demo app (Constitution VI)

Locally, without Docker, against test Redis DB 5:

```bash
cd demo_app
REDIS_URL=redis://localhost:6780/5 RAILS_ENV=test bundle exec rspec \
  spec/reactors/bulk_refund_demo_reactor_spec.rb \
  spec/reactors/contended_approval_demo_reactor_spec.rb \
  spec/reactors/dual_approval_demo_reactor_spec.rb
REDIS_URL=redis://localhost:6780/5 bin/rails demo:rollback_follow_ups
```

**Docker acceptance**: use an isolated compose project, because container names are fixed and
collide across worktrees.

```bash
docker compose -p rr_rollback_follow_ups -f docker-compose.yml -f <override.yml> up -d --build demo-redis demo-sidekiq
docker compose -p rr_rollback_follow_ups -f docker-compose.yml -f <override.yml> run --rm --no-deps demo-app \
  bash -c "bin/rails db:prepare && bin/rails demo:rollback_follow_ups"
```

Expected rake output, per task:

- **`demo:map_undo_all`**: "bulk refund called once with N charges", then the run `failed` with
  the steps before the map undone.
- **`demo:contended_resume`**: "resume accepted (DispatchResult) while the lock is held", then
  `completed` after release.
- **`demo:concurrent_interrupts`**: "finance accepted (background); legal accepted while running",
  then `completed`, with both approvals in the result.
