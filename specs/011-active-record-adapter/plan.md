# Implementation Plan: ActiveRecord Storage Adapter

**Branch**: `active_record_adapter` | **Date**: 2026-10-10 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `specs/011-active-record-adapter/spec.md`

## Summary

`config.storage.adapter = :active_record` replaces Redis completely: execution state, coordination and signals. The success bar is that every documented claim and the whole current suite hold on PostgreSQL, MySQL and SQLite. Four mechanisms carry it:

1. **Two storage shapes, split by lifecycle** (R-03).
   - **History** is the data users query: executions, step results, map state, rollback records, claims, period markers and idempotency keys. It goes into typed, indexed tables and is never expired.
   - **Coordination** is ephemeral state driven by the audited Lua scripts: locks, semaphores, rate-limit windows and ordered locks. It goes into one TTL key/value table that mirrors Redis's per-key data model.
2. **Each Lua script becomes a row-locked transaction ported line by line** (R-04–R-06).
   - The helper `atomically(keys)` ensures the rows exist, locks them in digest order, reads the database clock once, and exposes the Redis verbs the scripts use.
   - Reviewers diff each Ruby twin against its Lua. The scripts are not re-derived.
   - The helper retries on deadlock or serialization failure. TTL expiry is judged by the database clock, the equivalent of Redis's single server clock.
3. **A dedicated connection pool** (R-02). Reactor writes never join the host's transaction, so locks are visible immediately and history survives a host rollback. Every operation runs inside `with_connection`, so long-lived background threads never hold a connection.
4. **Parity-bounded scans** (R-08). The sweepers only see rows written within `context_ttl`, exactly the set Redis would still hold. Keeping history therefore never resurrects ancient stranded work, while the dashboard lists and filters all of it.

On top of parity:

- **Dashboard filters** (US4): reactor class, status, time range, and input equality through a portable input index that never contains redacted inputs (R-11, R-18).
- **Permanent period markers** that record the claiming execution (US5).
- **Run-level `idempotency_key:`** on both adapters, permanent on AR and kept for `context_ttl` on Redis (US6, R-15).

**Packaging** (R-01, R-16):

- ActiveRecord ≥ 8.0, loaded lazily outside Zeitwerk, with no gemspec change.
- Versioned plain migrations, installed by `rails g ruby_reactor:install` and run with `migrate`.
- A boot-time schema version check raises the new `StorageSchemaError`.
- A checksum lock makes released migrations append-only.

**Testing** (R-17): environment variables select the adapter and database. A shared adapter-contract spec runs against both adapters. CI runs Redis plus 3 database jobs for the gem suite, and Redis/Sidekiq plus 3 Redis-free AR/ActiveJob jobs for demo_app.

## Technical Context

**Language/Version**: Ruby >= 3.0 for the gem and Redis users. The ActiveRecord adapter, and running the gem suite, need Ruby >= 3.2, because ActiveRecord 8 requires it. CI uses 3.4.8 and 4.0.4.

**Primary Dependencies**:

- Existing: Redis, Sidekiq and ActiveJob adapters, dry-validation, Roda, Zeitwerk.
- Optional OpenTelemetry middleware.
- GUI: React/Vite (`gui/`, built into `lib/ruby_reactor/web/public`).
- **New, optional, host-provided**: ActiveRecord ≥ 8.0 plus a driver (`pg`, `trilogy`/`mysql2`, `sqlite3`). They are never in the gemspec. They are added to the gem's `Gemfile` `:development, :test` group and to `demo_app/Gemfile`.

**Storage**:

- Redis through `Storage::RedisAdapter`, unchanged except `period_mark(context_id:)` and `claim_idempotency_key`.
- **New**: `Storage::ActiveRecordAdapter` over 14 `ruby_reactor_*` tables (see [data-model.md](data-model.md)), created by `001_create_ruby_reactor_tables.rb`, `SCHEMA_VERSION = 1`.

**Testing**:

- RSpec against real services only (Constitution III). Adapter and engine are selected by `RUBY_REACTOR_TEST_STORAGE` and `RUBY_REACTOR_TEST_DATABASE_URL`.
- Shared adapter-contract examples; the `:redis_only` and `:active_record_only` tags; a `:stress` tag for SC-006 using forked processes; a `:slow` tag for SC-007.
- demo_app: `RUBY_REACTOR_STORAGE` and `RUBY_REACTOR_QUEUE`, with the shipped matchers only, plus the new `be_idempotent_replay`, `be_findable_by` and `be_period_marked….by`.

**Target Platform**: Linux and macOS servers. PostgreSQL ≥ 13, MySQL ≥ 8.0, SQLite ≥ 3.38. SQLite is for single-host and development use.

**Project Type**: Ruby gem (library), plus the `demo_app/` Rails integration app and the `gui/` dashboard.

**Performance Goals**:

- The demo suite on AR/PostgreSQL takes ≤ 2× its Redis wall-clock time (SC-008).
- A dashboard input filter over 100k executions returns its first page in < 2 s (SC-007).

**Constraints**:

- No new runtime dependency (FR-002).
- No Redis connection when AR and a non-Redis queue backend are configured (FR-006).
- Storage writes are independent of host transactions (FR-010).
- Released migrations are never edited (FR-018).

**Scale/Scope**:

- About 75 adapter methods. 11 coordination Lua scripts to port (lock ×3, semaphore ×2, rate limit, ordered lock ×5); the map-rollback start script becomes a unique insert (R-13).
- 22 spec files are coupled to Redis and need classifying.
- Documentation to touch: README plus 9 files under `documentation/`.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Status | Evidence |
|---|---|---|
| I. Gem-First | ✅ | The adapter sits behind `Storage::Adapter`, reached through `require "ruby_reactor"` and opted into by config. AR loads lazily outside Zeitwerk (R-01). No host coupling: a dedicated pool, and migrations shipped in `lib/`. |
| II. Saga Integrity (NON-NEGOTIABLE) | ✅ | Executor, compensation and DAG code are untouched. Atomicity is preserved by porting the scripts line by line under row locks (R-04), and the full saga suite is re-run per engine (SC-001). |
| III. Test-First, Real Infrastructure | ⚠️ text amendment | Every AR spec runs against real PostgreSQL, MySQL or SQLite, with no mocks. The literal "Redis MUST be reachable for the test suite" still holds for the gem suite, because Redis stays up as the queue backend. The Redis-free demo_app jobs need the wording "the configured storage backend MUST be real and reachable". See Complexity Tracking. |
| IV. Observability | ✅ | Failure records (reactor, step, redacted inputs, reason) are stored unchanged in `context`. The dashboard stays current: it gains filters, and the detail view gains redaction masking. AR adapter errors are logged as key=value lines with the operation, key and engine. |
| V. Simplicity and SemVer | ✅ | MINOR (additive). The adapter is the abstraction's second real use case. One generic coordination table instead of 4+ typed ones. No pub/sub emulation (R-14). CHANGELOG gets a Features entry. |
| VI. Demo-App Proof (NON-NEGOTIABLE) | ✅ planned | Three new reactors: `ActiveRecordHistoryReactor` (US4), `YearlyReportReactor` (US5) and `IdempotentChargeReactor` (US6, including a failing original that is compensated and then replayed as a failure). Each comes with a rake task (`[:environment, :flush_redis]`, where `flush_redis` now resets whichever storage is configured) and a spec that uses only the shipped matchers plus the new `be_idempotent_replay`, `be_findable_by` and `.by(...)` chain. Also: the existing `demo:all` aggregate gains the three new tasks and is the Redis-free acceptance run. `docker-compose.yml` gains `test-postgres`, `test-mysql`, `demo-postgres`, `demo-mysql` and the environment variables. |
| Tech Constraint: "Redis: Required for state persistence, locks…" | ⚠️ text amendment | The new adapter makes Redis optional. The amendment goes through `/speckit-constitution` (MINOR 1.4.0) **before merge**. See Complexity Tracking. |
| Tech Constraint: RuboCop | ✅ | New files follow the existing cops. The Lua twins carry the same rubocop disables as their Lua counterparts. |

- [x] Documentation impact identified (carried into tasks.md as required tasks):
  - `README.md`:
    - the intro (line 8, "Redis for state persistence");
    - the features list (line 28, "Redis-backed primitives");
    - the configuration block (lines 111–127: a new `storage.adapter = :active_record`, `storage.database`, and the meaning of `context_ttl` per adapter);
    - "Background reactors are durable" (line 593);
    - coordination (lines 724 and 1588);
    - the development section (lines 1610–1660: test databases and environment variables);
    - a new "Choosing a storage adapter" section.
  - **New** `documentation/storage_adapters.md`:
    - adapter comparison;
    - install and upgrade;
    - non-Rails setup;
    - supported engines and SQLite limits;
    - MySQL `max_allowed_packet` (R-10);
    - pool sizing;
    - the host-transaction note (R-02);
    - switching adapters (drain first);
    - history and the dashboard filters;
    - the idempotency API;
    - per-adapter differences.
  - `documentation/getting_started.md`: setup with either adapter.
  - `documentation/locks_and_semaphores.md`: "Redis-backed" becomes "store-backed"; TTL expiry is judged by the store's clock; `with_period` markers are permanent on AR.
  - `documentation/data_pipelines.md`: "`context_ttl` is the rollback horizon" applies to Redis only; on AR, `:context_unavailable` cannot come from expiry.
  - `documentation/background_and_async.md`: completion signals are pub/sub on Redis and fallback re-checks on AR.
  - `documentation/testing.md`: the environment variables, `be_idempotent_replay`, and storage reset per adapter.
  - `documentation/interrupts.md`, `documentation/retry_configuration.md`, `documentation/README.md`: Redis-specific wording made adapter-neutral where the claim is adapter-neutral.
  - `CHANGELOG.md`: Features entry.

**Post-design re-check (after Phase 1)**: no new violations. The two ⚠️ rows are text amendments, not design conflicts, and are tracked below.

## Project Structure

### Documentation (this feature)

```text
specs/011-active-record-adapter/
├── spec.md
├── plan.md              # this file
├── research.md          # R-01 … R-18
├── data-model.md        # 14 tables, mapped to the Redis key families
├── quickstart.md        # runnable validation per user story
├── contracts/
│   ├── public-api.md        # config, install, idempotency, RSpec surface, env vars
│   ├── storage-adapter.md   # parity surface, every adapter method and its semantics
│   └── dashboard-api.md     # filters, capabilities, redaction masking
├── checklists/requirements.md
└── tasks.md             # /speckit-tasks
```

### Source Code (repository root)

```text
lib/
├── ruby_reactor.rb                                  # loader.ignore AR paths
├── ruby_reactor/configuration.rb                    # :active_record branch, lazy require
├── ruby_reactor/reactor.rb, dsl/reactor.rb          # run(…, idempotency_key:)
├── ruby_reactor/executor.rb, executor/step_coordination.rb  # pass context_id to period_mark
├── ruby_reactor/sweeper.rb                          # + purge_expired_coordination
├── ruby_reactor/error/storage_schema_error.rb       # new
├── ruby_reactor/storage/
│   ├── adapter.rb                                   # declares the full surface + determine_status
│   ├── configuration.rb                             # + database
│   ├── redis_adapter.rb, redis_locking.rb           # + claim_idempotency_key, period_mark(context_id:)
│   ├── redis_reactor_scan.rb                        # determine_status moved up
│   ├── active_record_adapter.rb                     # new: entry, schema check, includes the modules below
│   └── active_record/                               # new (ignored by Zeitwerk)
│       ├── record.rb                                # ActiveRecordAdapter::Record, abstract base, establish_connection
│       ├── models.rb                                # one-line model per table
│       ├── coordination.rb                          # atomically(keys) + kv verbs + db clock + retry
│       ├── locking.rb                               # Ruby twins: lock, semaphore, rate limit, period
│       ├── ordered_locking.rb                       # Ruby twins: assign/can_proceed/advance/skip/heartbeat
│       ├── contexts.rb                              # executions, inputs index, correlation, scans, query_executions
│       ├── step_results.rb
│       ├── maps.rb                                  # operations, elements, results
│       ├── map_rollback.rb
│       ├── claims.rb                                # interrupt resumes, idempotency keys
│       └── migrations/001_create_ruby_reactor_tables.rb, migrations.lock
├── generators/ruby_reactor/install/install_generator.rb   # new (Rails only)
├── ruby_reactor/rspec/storage_reset.rb              # + ActiveRecordAdapterReset
├── ruby_reactor/rspec/matchers.rb                   # + be_idempotent_replay
└── ruby_reactor/web/api.rb                          # filters, /capabilities, redaction masking

gui/src/components/Dashboard.tsx, gui/src/lib/reactors.ts  # filter bar behind the capability flag

spec/
├── spec_helper.rb                                   # adapter selection, AR boot + migrate
├── support/storage_selection.rb                     # env-var adapter selection, AR boot + migrate, :redis_only / :active_record_only skips
├── ruby_reactor/storage/adapter_contract_spec.rb    # shared semantics, both adapters
├── ruby_reactor/storage/active_record/{loading,coordination,transaction_independence,history_window,failure_modes,stress,schema,migrations_lock,query_performance}_spec.rb
├── ruby_reactor/idempotency_spec.rb
└── (22 Redis-coupled specs classified: tagged :redis_only, or moved onto inspectors)

demo_app/
├── Gemfile                                          # + pg, trilogy
├── config/initializers/ruby_reactor.rb              # RUBY_REACTOR_STORAGE / RUBY_REACTOR_QUEUE
├── db/migrate/<ts>_create_ruby_reactor_tables.rb    # via the generator
├── app/reactors/{active_record_history,yearly_report,idempotent_charge}_reactor.rb
├── lib/tasks/demo_reactors.rake                     # flush_redis → storage-agnostic reset; new tasks; demo:all
└── spec/reactors/{…}_spec.rb

docker-compose.yml                                   # + test-postgres(6781), test-mysql(6782), demo-postgres, demo-mysql
.github/workflows/main.yml                           # gem: redis + AR×3; demo: redis+sidekiq + AR+active_job×3 (no Redis)
```

**Structure Decision**: The single-gem layout is unchanged. The AR adapter mirrors the Redis adapter's module split (locking, ordered locking, step results, scans, map rollback), so each Redis module has a one-to-one AR counterpart to review against.

## Implementation Order

Each phase leaves the suite green under Redis.

0. **Constitution amendment** (1.4.0, `/speckit-constitution`) before any Redis-free work (tasks T003).
1. **Contract first**:
   - `Adapter` declares the full surface, and `determine_status` moves up.
   - `adapter_contract_spec.rb` is written against Redis, green.
   - Spec tagging infrastructure and environment-variable selection are added.
2. **Foundation**:
   - loading and config (R-01, R-02);
   - migration 001 and `SCHEMA_VERSION` check (R-16);
   - `Coordination.atomically` with the clock and retry (R-04–R-07);
   - `StorageReset` for AR.
   - The contract spec runs under AR and goes red.
3. **History tables**: contexts, inputs, correlation, step results, maps, map rollback, interrupt claims, scans (R-08, R-09, R-11–R-13). The contract spec goes green for these.
4. **Coordination twins**:
   - lock, semaphore, rate limit and period;
   - then ordered locking (the highest-risk port, done last with the most review).
   - The contract spec goes fully green.
5. **Full suite under AR × 3 engines**: classify the 22 Redis-coupled specs, fix parity gaps, add the AR-only specs (schema, transaction independence, clock, history window, stress).
6. **New capabilities**: `idempotency_key:` (both adapters), `period_mark(context_id:)`, `query_executions`, the API filters, `/capabilities`, the GUI filter bar, redaction masking.
7. **Demo app, Docker and CI**: environment variables, the generator-installed migrations, 3 reactors with rake tasks and specs, `demo:all`, compose services, the workflow matrix.
8. **Documentation sweep**: the README and documentation files listed above, CHANGELOG, and the SC-002 claims audit (`checklists/claims.md`).

## Spec Deltas (applied to spec.md on 2026-10-10)

- **Edge case "Large contexts"**: on MySQL, the accepted size is bounded by half of `max_allowed_packet`, which operators configure. Above it, the adapter always raises `ContextTooLargeError` and never truncates (R-10).
- **FR-021**: masking redacted inputs in the dashboard detail view also changes the Redis dashboard. Today it shows stored inputs raw. The change is intended because FR-021 says "never displayed"; it is called out in the CHANGELOG.
- **Values that are not indexed** (non-scalar, or longer than 255 characters) cannot be filtered on. This narrows the spec's "input key/value equality" assumption and is documented (R-11).

## Complexity Tracking

| Violation | Why Needed | Simpler Alternative Rejected Because |
|-----------|------------|-------------------------------------|
| Constitution Technical Constraint "Redis: Required for state persistence, locks, semaphores…" | The user asked for a full replacement, so Redis must become optional. | Keeping Redis for coordination (a hybrid) was explicitly rejected by the user for this feature. A per-concern mix is a later feature. |
| Constitution III wording "Redis MUST be reachable for the test suite" | The Redis-free demo_app CI jobs are the continuous proof of FR-006 and SC-005. | Keeping Redis up in those jobs would leave "no Redis connection" unproven. A spec that merely stubs Redis away is forbidden by III itself. |
| Generic key/value table emulating Redis types for coordination (R-03) | It lets the 11 coordination Lua scripts be ported line by line, so the fencing logic tuned against real incidents is kept, not re-derived. | Typed per-primitive tables would mean re-deriving each script's semantics against a new model. That is the regression risk the spec ranks first. |
| Two storage engines exercised by one suite (CI: 2 Rubies × 4 storage targets = 8 gem jobs, plus 4 demo jobs) | FR-028 and SC-001/SC-003 require parity proof on every engine. | Running AR on SQLite only would miss row-locking, gap-lock and deadlock behavior that only PostgreSQL and MySQL exhibit. |
