# Quickstart: Validating the ActiveRecord Storage Adapter

These are runnable checks that prove each user story end to end. Commands run from the repo root unless noted. The behavior they check is defined in [contracts/](contracts/) and [data-model.md](data-model.md).

## Prerequisites

```bash
docker compose up -d redis-test test-postgres test-mysql   # services added by this feature
bundle install                                              # Gemfile dev group: activerecord, sqlite3, pg, trilogy
```

| engine | `RUBY_REACTOR_TEST_DATABASE_URL` |
|---|---|
| SQLite | `sqlite3:tmp/ruby_reactor_test.sqlite3` |
| PostgreSQL | `postgres://postgres:postgres@localhost:6781/ruby_reactor_test` |
| MySQL | `trilogy://root:root@127.0.0.1:6782/ruby_reactor_test` |

## 1. Gem suite parity (US1, US3, SC-001)

```bash
bundle exec rspec                                                    # Redis, unchanged
RUBY_REACTOR_TEST_STORAGE=active_record RUBY_REACTOR_TEST_DATABASE_URL=sqlite3:tmp/ruby_reactor_test.sqlite3 bundle exec rspec
RUBY_REACTOR_TEST_STORAGE=active_record RUBY_REACTOR_TEST_DATABASE_URL=postgres://postgres:postgres@localhost:6781/ruby_reactor_test bundle exec rspec
RUBY_REACTOR_TEST_STORAGE=active_record RUBY_REACTOR_TEST_DATABASE_URL=trilogy://root:root@127.0.0.1:6782/ruby_reactor_test bundle exec rspec
```

**Expect**:

- 0 failures in each run.
- Skips appear only for `:redis_only` (under AR) or `:active_record_only` (under Redis), each with a reason.
- `spec/ruby_reactor/storage/adapter_contract_spec.rb` runs under all four runs.

## 2. Contention stress (SC-006)

```bash
RUBY_REACTOR_TEST_STORAGE=active_record RUBY_REACTOR_TEST_DATABASE_URL=postgres://… bundle exec rspec --tag stress
```

**Expect**: 0 violations across 1,000 contended acquisitions from ≥ 4 forked processes, for locks, semaphores, rate limits and ordered locks. Repeat with the MySQL URL.

## 3. Schema install, mismatch and append-only (US2, SC-009)

```bash
RUBY_REACTOR_TEST_STORAGE=active_record bundle exec rspec spec/ruby_reactor/storage/active_record/schema_spec.rb
```

**Expect**:

- Install creates every table, and the default of `ruby_reactor_schema.version` equals `SCHEMA_VERSION`.
- A database built from a dumped `db/schema.rb` (the `db:prepare` and `db:test:prepare` path) passes the check.
- Dropping the schema table, or changing the column default to below or above `SCHEMA_VERSION`, makes the first adapter call raise `StorageSchemaError` with the matching message, and no row is written.
- `migrations.lock` matches every shipped migration's SHA-256.

In demo_app: `bin/rails generate ruby_reactor:install` copies the migrations. Running it again copies nothing.

## 4. Demo app, both adapters (US1, US3, SC-003, SC-005)

```bash
cd demo_app
bundle exec rspec                                                     # Redis + Sidekiq (today)
RUBY_REACTOR_STORAGE=active_record RUBY_REACTOR_QUEUE=active_job bin/rails db:prepare
RUBY_REACTOR_STORAGE=active_record RUBY_REACTOR_QUEUE=active_job bundle exec rspec
RUBY_REACTOR_STORAGE=active_record RUBY_REACTOR_QUEUE=active_job DATABASE_URL=postgres://… bundle exec rspec
```

Redis-free acceptance (SC-005). Stop every Redis first:

```bash
docker compose stop redis-test demo-redis
docker compose run --rm --no-deps -e RUBY_REACTOR_STORAGE=active_record -e RUBY_REACTOR_QUEUE=active_job demo-app bash -c "bin/rails db:prepare && bin/rails demo:all"
```

**Expect**:

- Every `demo:` task prints its documented outcome.
- No connection to Redis is attempted (FR-006).

## 5. History and dashboard queries (US4, SC-007, SC-010)

```bash
cd demo_app
RUBY_REACTOR_STORAGE=active_record bin/rails demo:active_record_history
```

It runs several reactors with different `user_id` inputs and prints their ids. Then:

```bash
curl -s localhost:3000/ruby_reactor/api/capabilities                              # {"execution_query":true}
curl -si 'localhost:3000/ruby_reactor/api/reactors?input[user_id]=100&status=completed'
```

**Expect**:

- Only executions with `user_id = 100` and `completed` status are returned.
- A filter on a redacted input returns `[]`.
- On Redis, the same request returns `422`.
- With 100,000 seeded executions (`--tag slow`), the first page takes under 2 s on PostgreSQL and MySQL.

## 6. Permanent period and idempotency (US5, US6)

```bash
cd demo_app
RUBY_REACTOR_STORAGE=active_record bundle exec rspec spec/reactors/yearly_report_reactor_spec.rb spec/reactors/idempotent_charge_reactor_spec.rb
```

**Expect**:

- A second `:year` run in the same year `be_halted`, and the marker records the claiming execution.
- A repeated `idempotency_key` run `be_idempotent_replay`, with the original `execution_id` and no step re-run.
- Concurrent duplicate starts produce exactly one execution.

## 7. Host transaction independence (FR-010)

```bash
RUBY_REACTOR_TEST_STORAGE=active_record RUBY_REACTOR_TEST_DATABASE_URL=postgres://… bundle exec rspec spec/ruby_reactor/storage/active_record/transaction_independence_spec.rb
```

**Expect**:

- A reactor run inside `ActiveRecord::Base.transaction { …; raise ActiveRecord::Rollback }` leaves its execution row behind.
- A lock it took was visible to a second connection before the host transaction ended.

## 8. Release checklist: performance and stress (SC-006, SC-007, SC-008)

These are not per-PR gates. Run them on one machine before a MINOR release:

```bash
cd demo_app
time RUBY_REACTOR_QUEUE=active_job bundle exec rspec spec/reactors        # Redis storage, ActiveJob
time RUBY_REACTOR_STORAGE=active_record RUBY_REACTOR_QUEUE=active_job DATABASE_URL=postgres://… bundle exec rspec spec/reactors
```

**Expect**: the AR time is ≤ 2× the Redis time (same machine, same queue backend). Also run §2 (`--tag stress`) and the `--tag slow` query-performance spec (§5) on PostgreSQL and MySQL.
