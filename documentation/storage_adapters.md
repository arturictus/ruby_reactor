# Storage Adapters

RubyReactor keeps every reactor's state in a storage adapter: contexts, async step results, map results,
interrupt claims, rollback records, plus the coordination primitives (locks, semaphores, rate limits,
periods, ordered locks). Two adapters ship with the gem:

| | Redis (default) | ActiveRecord |
| --- | --- | --- |
| Backend | Redis | PostgreSQL, MySQL, SQLite (ActiveRecord ≥ 8.0) |
| Execution history | expires after `context_ttl` | kept permanently |
| Dashboard | lists recent runs | lists all runs |
| Coordination TTLs | Redis server clock | database server clock |
| Async completion signal | Redis pub/sub, with a fallback re-check | fallback re-check only |
| Extra dependency | none | `activerecord` + a driver in **your** Gemfile |

Both adapters run the same reactors, unchanged, with the same documented guarantees. The
[differences](#differences-between-the-adapters) all come from one choice: ActiveRecord keeps history
instead of expiring it.

## Choosing an adapter

- **Redis**: the lowest latency, and nothing to migrate. Choose it when you already run Redis (for
  example as the Sidekiq queue) and don't need history beyond `context_ttl`.
- **ActiveRecord**: durable history that survives restarts and Redis evictions, and a dashboard you
  can search. Choose it when your app already lives in a relational database, or when you want to run
  without Redis at all (ActiveRecord storage plus the ActiveJob backend).

## Configuration

```ruby
# Gemfile — RubyReactor never adds these for you.
gem "activerecord", ">= 8.0"   # already present in a Rails app
gem "pg"                       # or "trilogy" / "mysql2", or "sqlite3"

# config/initializers/ruby_reactor.rb
RubyReactor.configure do |config|
  config.storage.adapter = :active_record

  ## Optional: where reactor storage lives. Default: nil, the app's primary
  ## database. Accepts a database.yml name (Symbol), a URL, or a Hash.
  # config.storage.database = :ruby_reactor
end
```

The ActiveRecord adapter needs **Ruby ≥ 3.2**, because ActiveRecord 8 requires it. Redis users keep
the gem's `>= 3.0` floor.

Selecting `:active_record` without the `activerecord` gem installed raises a `LoadError` that names
the gem to add. A Redis-only app never loads ActiveRecord.

### Install and upgrade the schema

The adapter's tables ship as versioned migrations inside the gem.

**Rails:**

```bash
bin/rails generate ruby_reactor:install   # copies the migrations you don't have yet into db/migrate
bin/rails db:migrate
```

Run the same two commands after every gem upgrade. The generator copies only migrations
your app doesn't have yet, and never edits existing files. Released migrations are never
changed; schema changes always arrive as new migrations, so your history is kept.

**ActiveRecord without Rails:**

```ruby
ActiveRecord::MigrationContext.new(RubyReactor::Storage::ActiveRecordAdapter.migrations_path).migrate
```

**The schema check.** On first use, the adapter compares the installed schema version
with the one the gem needs. It raises `RubyReactor::Error::StorageSchemaError` before
reading or writing anything when:

| Message | Fix |
| --- | --- |
| "storage tables are missing" | run the install commands above |
| "schema is version N, this gem needs M" | run the install commands again, then migrate |
| "schema is version N, newer than this gem's M" | upgrade the `ruby_reactor` gem (or roll the migration back) |

The version marker is the default value of the `ruby_reactor_schema.version` column, so it
survives `db/schema.rb` loads (`db:prepare`, `db:test:prepare`) and table truncation in tests.

### Its own connection pool

The adapter opens a **dedicated pool**, even against your primary database. Reactor writes therefore
commit on their own and never join a transaction your code has open:

- a lock a reactor takes is visible to other processes immediately;
- a run's history survives your transaction rolling back.

Size the pool for your worker threads, plus one per running lock auto-extender and ordered-lock
heartbeat. Every storage call checks a connection out only for its own duration.

### Supported databases

| Engine | Notes |
| --- | --- |
| PostgreSQL ≥ 13 | Recommended for production. |
| MySQL ≥ 8.0 | Contexts are bounded by the server's `max_allowed_packet` (default 64 MB). A larger context raises `RubyReactor::Error::ContextTooLargeError`; raise `max_allowed_packet` if you need more. |
| SQLite ≥ 3.38 | Development, tests and single-host use only. SQLite serializes all writers, so don't start reactors inside an open write transaction: the reactor's own writes would wait for it, then time out. |

**macOS + PostgreSQL + forking servers** (Puma cluster mode, `fork` in specs): add
`gssencmode=disable` to the connection URL (`postgres://…/db?gssencmode=disable`). libpq's GSSAPI
initialisation crashes in forked children on macOS. Linux is unaffected.

## Differences between the adapters

The ActiveRecord adapter keeps execution history instead of expiring it. Everything else behaves the
same, and the gem's whole test suite runs against both. The differences follow from that one
choice:

| Behavior | Redis | ActiveRecord |
| --- | --- | --- |
| Contexts, step results, map results, rollback records | expire `context_ttl` after their last write | kept permanently |
| Map rollback reporting `reason: :context_unavailable` because an element's context **expired** | happens after `context_ttl` | cannot happen; the context is still there |
| Period markers (`with_period`) | live for the period's length | permanent, and record the claiming execution |
| Locks, semaphores, rate-limit windows, ordered locks | expire on their TTL | expire on their TTL, identically; expired rows are purged by the sweeper |
| Sweeper recovery of a stranded run | only runs younger than `context_ttl` (older ones expired) | only runs written within `context_ttl`, the same set |
| Completion signal for `result(:async_step)` waits | pub/sub wakes the waiter early | the waiter re-checks every `async_wait_timeout / 10` (1–5 s) |

Coordination TTLs are judged by the **database** server's clock, as Redis judges them by its own
clock, so hosts with skewed clocks still agree on whether a lock expired.

## Switching adapters

Executions are not migrated between adapters. To switch:

1. Stop enqueuing new work, and let in-flight runs finish (or reach a terminal state).
2. Install the ActiveRecord schema.
3. Change `config.storage.adapter` and deploy.

Runs still in Redis are not visible to the ActiveRecord adapter.
