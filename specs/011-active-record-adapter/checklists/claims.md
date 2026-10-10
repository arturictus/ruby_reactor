# Claims Audit: ActiveRecord Storage Adapter (SC-002)

**Purpose**: Every behavioral claim in `README.md` and `documentation/*.md` is either covered by a spec
that runs under **both** storage adapters, or listed as a documented per-adapter difference.

**Created**: 2026-10-10

**Feature**: [spec.md](../spec.md)

**How coverage is proven**: CI runs the whole gem suite once per storage target (Redis, AR/SQLite,
AR/PostgreSQL, AR/MySQL; `.github/workflows/main.yml`). An example runs on all four unless it is
tagged `:redis_only` or `:active_record_only`. So a claim is covered on both adapters when its specs
carry no adapter tag. Part 2 lists every `:redis_only` example and the documented difference behind it.

Local verification (2026-10-10): the full gem suite passed with 0 failures on AR/PostgreSQL. On
AR/SQLite and AR/MySQL it passed with 1 failure each, and both examples passed when rerun alone: they
were timing flakes from running the three suites at the same time. Redis: 0 failures.

## Part 1: Claim areas → specs that run on both adapters

- [x] CA-01 Saga rollback: compensation of the failing step, then undo in reverse order (README "Error Handling and Compensation", `core_concepts.md` "The Rollback Rule"). Specs: `spec/ruby_reactor/compensation_*`, `spec/ruby_reactor/error_handling_spec.rb`, `spec/ruby_reactor/rollback/`.
- [x] CA-02 Retries and backoff, inline and background (`retry_configuration.md`). Specs: `spec/async_retry_*`, `spec/ruby_reactor/executor/`.
- [x] CA-03 Durability and crash recovery: checkpoints, liveness lock, sweeper re-enqueue (README "Durability & Recovery"). Specs: `spec/ruby_reactor/checkpoint_spec.rb`, `context_lock_spec.rb`, `caller_process_liveness_spec.rb`, `sweeper_spec.rb`, `step_sweeper_spec.rb`, `spec/map/map_recovery_spec.rb`.
- [x] CA-04 Async steps and async reactors: notified wait, bounded timeout, single writer (`background_and_async.md`). Specs: `spec/ruby_reactor/dsl/async_step_spec.rb`, `async_reactor_spec.rb`, `async_step_single_writer_spec.rb`, `async_waiter_spec.rb` (the fallback re-check example).
- [x] CA-05 Interrupts: pause, resume by id or correlation id, one resume per interrupt, max attempts, composed children (`interrupts.md`). Specs: `spec/ruby_reactor/interrupt*_spec.rb`, `spec/ruby_reactor/interrupts/`, `spec/integration/interrupt_*`.
- [x] CA-06 Maps: inline, fan-out, batching, atomic, recovery, rollback, `undo_all` (`data_pipelines.md`). Specs: `spec/map/`, `spec/ruby_reactor/map/`, `spec/ruby_reactor/rollback/`.
- [x] CA-07 Composition (`composition.md`). Specs: `spec/compose_spec.rb`, `spec/nested_reactor_inline_execution_spec.rb`.
- [x] CA-08 Locks: exclusive, re-entrant, auto-extend, TTL recovery after a crash, contention snooze/park (`locks_and_semaphores.md`). Specs: `spec/ruby_reactor/integration/locking_spec.rb`, `spec/ruby_reactor/step_coordination/lock_spec.rb`, `contention_spec.rb`, `park_spec.rb`, and the adapter contract.
- [x] CA-09 Semaphores: limit, token safety, double release refused. Specs: `locking_spec.rb`, `step_coordination/primitives_spec.rb`, the adapter contract, `storage/active_record/stress_spec.rb` (AR, multi-process).
- [x] CA-10 Rate limits: multi-window all-or-none, `retry_after` snoozes. Specs: `locking_spec.rb`, `primitives_spec.rb`, the adapter contract.
- [x] CA-11 Periods: once per bucket, failed runs don't claim, calendar buckets. Specs: `locking_spec.rb`, `primitives_spec.rb`, `rspec/period_marked_by_matcher_spec.rb`.
- [x] CA-12 Ordered locks: nonce order, poison pill, strict chain skip, drain reset, stale-epoch fence. Specs: `storage/redis_ordered_locking_spec.rb` (adapter-agnostic since this feature), `step_coordination/ordering_parity_spec.rb`, `primitives_spec.rb`.
- [x] CA-13 Step-scoped coordination and deadlock-safe composition. Specs: `spec/ruby_reactor/step_coordination/`.
- [x] CA-14 Validation: inputs, interrupt payloads, step input contracts. Specs: `spec/ruby_reactor/dsl/`, `spec/integration/interrupt_validation_spec.rb`, `step_contract_*_spec.rb`.
- [x] CA-15 Dashboard API and redaction (README "Web Dashboard", `contracts/dashboard-api.md`). Specs: `spec/ruby_reactor/web/`.
- [x] CA-16 RSpec helpers and matchers (`testing.md`). Specs: `spec/ruby_reactor/rspec/`, plus every `demo_app/spec/reactors/*_spec.rb`, which runs on Redis+Sidekiq and on AR+ActiveJob across all three engines.
- [x] CA-17 Middlewares and OpenTelemetry (`middlewares.md`). Specs: `spec/ruby_reactor/telemetry_spec.rb`, middleware specs.
- [x] CA-18 Idempotency keys (both adapters, different retention). Specs: `spec/ruby_reactor/idempotency_spec.rb`, `rspec/idempotent_replay_matcher_spec.rb`, demo `idempotent_charge_reactor_spec.rb`.
- [x] CA-19 Storage adapter contract: every adapter method's semantics. Spec: `spec/ruby_reactor/storage/adapter_contract_spec.rb`.

## Part 2: Redis-only examples → documented differences

Each row's difference is stated in `documentation/storage_adapters.md` ("Differences between the
adapters"), unless another location is named.

- [x] RD-01 `context_ttl_spec.rb` (contexts expire after `context_ttl`). Documented: contexts and history kept permanently on AR.
- [x] RD-02 `storage/step_result_spec.rb:52` (step result TTL). Documented: same row.
- [x] RD-03 `interrupt_claims_spec.rb:26,40` (claim/attempt TTLs). Documented: same row. The claim semantics are covered on both adapters by the adapter contract.
- [x] RD-04 `map_undo_all_spec.rb:131`, `rollback/map_rollback_spec.rb:285,405`, `rollback/map_fan_out_settle_spec.rb:219` (simulated TTL expiry → `:context_unavailable`). Documented: storage_adapters.md, and `data_pipelines.md` ("`context_ttl` is the rollback horizon (Redis storage)").
- [x] RD-05 `map/map_owner_resume_spec.rb:106` (map metadata written by a pre-009 Redis version). Not a behavior difference: ActiveRecord storage has no pre-009 data to read.
- [x] RD-06 `integration/locking_spec.rb:194` (period marker TTL = 2× period). Documented: periods row, and `locks_and_semaphores.md` ("markers are permanent").
- [x] RD-07 `idempotency_spec.rb:163` (keys expire after `context_ttl`). Documented: idempotency row and `core_concepts.md` ("Retention").
- [x] RD-08 `async_waiter_spec.rb:40` (pub/sub wakes the waiter early). Documented: completion-signal row and `background_and_async.md`. The AR twin (wait within one fallback interval) runs as `:active_record_only`.
- [x] RD-09 `step_coordination/lock_spec.rb:216` (Redis unreachable). Not a difference: the AR twin is `storage/active_record/failure_modes_spec.rb` (database unreachable).
- [x] RD-10 `web/api_spec.rb:47`, `rspec/findable_matcher_spec.rb:25` (filters and history queries refused on Redis). Documented: storage_adapters.md "History and dashboard filters" and `dashboard-api.md`.
- [x] RD-11 `storage/redis_adapter_spec.rb` (Redis key layout and TTLs). Internals, not a behavioral claim. Its behavioral examples moved to the adapter contract.

## Notes

- No claim was found with neither a both-adapter spec nor a documented difference.
- The `:active_record_only` examples cover behavior that exists only on AR (schema checks, transaction independence, the database clock, history windows, query performance, stress). They are not claims about Redis.
