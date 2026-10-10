# Research: ActiveRecord Storage Adapter

**Feature**: [spec.md](spec.md) | **Plan**: [plan.md](plan.md) | **Date**: 2026-10-10

Every decision below serves the spec's first priority: the relational adapter must meet every documented claim and everything the current test suite verifies. Where fidelity and elegance conflict, fidelity wins.

---

## R-01 Loading: lazy, outside Zeitwerk, no gemspec dependency

**Decision**:
- The adapter lives in `lib/ruby_reactor/storage/active_record_adapter.rb` plus `lib/ruby_reactor/storage/active_record/`.
- Both paths are added to `loader.ignore` in `lib/ruby_reactor.rb`.
- `Configuration#storage_adapter` loads them with `require_relative` only when `storage.adapter == :active_record`.
- The adapter's first line is `require "active_record"`. A `LoadError` there is re-raised as a `LoadError` whose message names the missing gem and the Gemfile line to add (FR-003). There is no new error class, because a missing gem is a load problem.
- Minimum version is ActiveRecord ≥ 8.0, checked at load. ActiveRecord 8 needs Ruby ≥ 3.2, which is therefore the floor for the AR adapter and for contributors running the gem suite. The gem itself keeps `>= 3.0` for Redis users.
- **Constant naming**: every AR-side constant lives under the adapter class: `ActiveRecordAdapter::Record`, `ActiveRecordAdapter::Execution`, `ActiveRecordAdapter::Coordination`, `ActiveRecordAdapter::MODELS` and so on. There is **no** `RubyReactor::Storage::ActiveRecord` module, because one would shadow `::ActiveRecord` inside `RubyReactor::Storage`, and `ActiveRecord::Deadlocked` there would raise `NameError`. Code still writes `::ActiveRecord::…` explicitly. The files stay in the `storage/active_record/` directory, which Zeitwerk ignores, so file paths need not match constants.
- The gemspec is unchanged (FR-002).
- In the gem's `Gemfile`, `activerecord`, `sqlite3`, `pg` and `trilogy` go in the `:development, :test` group.

**Rationale**:
- Rails runs `Zeitwerk::Loader.eager_load_all` in production. If the AR files were managed by the gem's loader, a Redis-only app built without ActiveRecord would raise `LoadError` at boot. Ignoring them keeps loading strictly opt-in, which is the same pattern the Sidekiq and ActiveJob guards already use.
- ActiveRecord 7.2 reached end of life in August 2026, so ≥ 8.0 drops no supported Rails.
- ActiveRecord 8.x defaults SQLite to `default_transaction_mode: :immediate`. That was verified in activerecord-8.1.1 `sqlite3_adapter.rb:162`. R-05 depends on it. A task re-verifies that 8.0 matches 8.1.
- Of the MySQL drivers, `trilogy` builds without `libmysqlclient`, so a maintainer's `bundle install` never breaks on a missing system library.

**Alternatives considered**:
- A separate `ruby_reactor-active_record` gem. Rejected: it doubles release work, and the user asked for this to live in the gem.
- `add_development_dependency "activerecord"`. Rejected: the user allows it only "if there is no other choice", and the Gemfile is enough.

## R-02 Connection: a dedicated pool so storage commits independently

**Decision**:
- All adapter models inherit from `RubyReactor::Storage::ActiveRecord::Record`, an abstract class. The adapter calls `Record.establish_connection(config)` once.
- `config` is `storage.database` when set: a `database.yml` name (Symbol), a URL or a Hash (FR-005). Otherwise it is `ActiveRecord::Base.connection_db_config`, the primary database.
- Every adapter operation runs inside `Record.connection_pool.with_connection { … }`.

**Rationale**:
- `establish_connection` on a subclass creates its own pool, even for the same database. Its writes therefore never join a host transaction opened on `ActiveRecord::Base` (FR-010): locks are visible immediately, and history survives a host rollback.
- `with_connection` returns the connection when each operation ends. This matters because lock auto-extend threads, ordered-lock heartbeats and the async waiter's subscriber thread are long-lived; if they leased connections per thread, they would drain the pool.
- **Known ceiling**: SQLite cannot write from a second connection while a host transaction holds the write lock, so the reactor write blocks until `timeout`. This is documented: on SQLite, do not start reactors inside an open write transaction. SQLite is already scoped to single-host, development and test use (spec).

**Alternatives considered**:
- Reusing `ActiveRecord::Base`'s pool. Rejected: it breaks FR-010, and a host rollback would erase locks and claims that other processes already acted on.
- `requires_new: true` savepoints. Rejected: savepoints are still rolled back when the outer transaction is.

## R-03 Two storage shapes: typed history tables plus a TTL key/value table for coordination

**Decision**: Split by data lifecycle.

- **History, kept permanently (FR-014, FR-015)**:
  - stored in typed tables: executions, input index, step results, map operations, map elements, map results, map rollbacks, rollback outcomes, correlation IDs, interrupt resumes, period markers, idempotency keys;
  - each is indexed for the queries its callers and the dashboard make (see [data-model.md](data-model.md)).
- **Coordination, ephemeral and TTL-bound (FR-011)**:
  - stored in **one** table, `ruby_reactor_coordination`: `key_digest` (PK), `key`, `value` (JSON text, NULL = absent) and `expires_at_ms`;
  - covers locks, semaphores, rate-limit windows and ordered-lock sequences.

**Rationale**:
- History is what users query (US4). It needs real columns and indexes.
- Coordination state is Redis data-structure state driven by audited Lua scripts. The lowest-risk way to keep their semantics is to keep their data model: string, hash, list and set values per key, each with its own TTL. Each script is then ported line by line (R-04).
- One generic table means coordination logic can change without a schema migration.

**Alternatives considered**:
- Typed tables per primitive (locks, semaphore_tokens, ordered_lock_sequences…). Rejected for coordination. Each Lua script would have to be re-derived against a new model, and the ordered-lock scripts alone carry about 200 lines of fencing logic tuned against real incidents (stale epochs, drained-batch fences, KEEPTTL resurrection). Re-deriving them invites exactly the regressions the spec forbids.
- Key/value for everything. Rejected: history would not be queryable, which defeats US4.

## R-04 Atomicity: each Lua script becomes one row-locked transaction ported line by line

**Decision**:
- A single helper, `Coordination.atomically(keys) { |kv| … }`, does four things in order:
  1. opens a transaction on the adapter's pool;
  2. inserts any missing rows for `keys` with `value = NULL`, skipping duplicates (`insert_all`);
  3. selects the rows `ORDER BY key_digest FOR UPDATE`;
  4. reads the database clock once (R-06).
- It yields `kv`, an in-memory view with the Redis verbs the scripts use: `get set incr incrby decr exists del expire ttl hget hset hdel hincrby hexists hkeys hlen lpop rpush llen sadd srem sismember scard`, plus `set(nx:, ex:, keepttl:)`.
- It writes back only the rows that changed.
- Each `*_SCRIPT` constant in `RedisLocking` and `RedisOrderedLocking` gets a Ruby twin that keeps the Lua's control flow and comments. Reviewers diff the twin against the Lua.

**Rationale**:
- A Lua script is atomic across its `KEYS`. Locking exactly those rows in a fixed order (`key_digest`) inside one transaction gives the same isolation and is deadlock-free by construction.
- Rows are ensured before they are locked because `SELECT … FOR UPDATE` on a missing row locks nothing in PostgreSQL, so two "first acquires" would both succeed.
- On SQLite, `FOR UPDATE` is ignored, but IMMEDIATE transactions (R-01) serialize every writer, which is stronger.
- The non-script Redis **writes** (plain `SET NX`, `INCR`, `DEL`) use the same helper with one key. There is one mechanism to review.
- **Read-only inspectors** (`lock_held?`, `lock_info`, `lock_ttl`, `semaphore_state`, `semaphore_held`, `semaphore_exists?`, `rate_limit_count`, `rate_limit_ttl`, `ordered_lock_peek`) use `Coordination.peek(keys)`. It does a plain `SELECT` plus the same database-clock expiry check, with no insert, no row lock and no write transaction. Dashboard polling and RSpec matchers therefore never compete with workers for locks, which matters most on SQLite, where any write transaction blocks all writers. A Redis read has the same no-lock semantics.

**Alternatives considered**:
- Single conditional `UPDATE … WHERE owner = ? OR expired` statements. Rejected as the general mechanism. Each one is a fresh derivation, and on MySQL the affected-row counts depend on the `FOUND_ROWS` flag. Fine as a later optimization behind the same tests.
- PostgreSQL advisory locks or `SKIP LOCKED`. Rejected: neither is portable to MySQL and SQLite (FR-004).

## R-05 Retry on deadlock or serialization failure, never on a lock-wait timeout

**Decision**:
- `atomically` retries the whole block up to 3 times, with 10–50 ms of jitter, on `ActiveRecord::Deadlocked` and `ActiveRecord::SerializationFailure`.
- `ActiveRecord::LockWaitTimeout`, `ConnectionNotEstablished` and other errors are raised unchanged. They reach the executor exactly as a Redis connection error does today (spec edge case "Database unavailable mid-execution").
- On SQLite, `SQLite3::BusyException` (surfacing as `ActiveRecord::StatementTimeout` or `StatementInvalid`) after `timeout` is raised the same way. It is a retriable condition at the job level, never silent corruption.

**Rationale**:
- Sorted locking prevents most deadlocks. MySQL gap locks on `INSERT IGNORE` of neighbouring keys can still produce some. The block is pure (it computes from the locked rows and writes them back), so re-running it is safe.

**Alternatives considered**: Not retrying. Rejected: MySQL deadlocks under contention would surface as spurious step failures (SC-006).

## R-06 Time: the database clock decides TTL expiry

**Decision**:
- `atomically` reads `now_ms` from the database once per transaction:
  - PostgreSQL: `(EXTRACT(EPOCH FROM clock_timestamp()) * 1000)::bigint`;
  - MySQL: `CAST(UNIX_TIMESTAMP(NOW(3)) * 1000 AS UNSIGNED)`;
  - SQLite: `CAST((julianday('now') - 2440587.5) * 86400000 AS INTEGER)`.
- Expiry (`expires_at_ms <= now_ms` means absent), `ttl` and `EX` are judged against that clock.
- Values the Ruby side already passes in, such as the `now` argument to rate-limit and ordered-lock scripts and period bucket IDs, stay app-clock, exactly as with Redis today.

**Rationale**:
- With Redis, TTL expiry is judged by the Redis server's single clock, and that is what keeps lock expiry consistent across hosts (FR-011). The database server is the equivalent single clock.
- Passing the existing `now` arguments through unchanged keeps parity. Moving them to the database clock would change behavior the Redis adapter has.

**Alternatives considered**: `Time.now` in Ruby. Rejected: skewed hosts would disagree on whether a lock expired, which is a double-grant risk.

## R-07 Expired coordination rows: absent when read, purged by the sweeper

**Decision**:
- `kv` treats an expired row as absent, and writing it reuses the row.
- The `Adapter` gains `purge_expired_coordination(limit: 1000)`. It is a no-op on Redis.
- `Sweeper.run_once` calls it, deleting rows where `value IS NULL OR expires_at_ms <= now`, in batches.

**Rationale**:
- Expiry stays exact without a background job; correctness never depends on the purge.
- The purge only bounds table growth (spec edge case "Unbounded growth of coordination state").
- The sweeper already runs periodically in every deployment that uses async work.

## R-08 History scans: bounded to what Redis would still hold

**Decision**:
- The sweeper-facing scans (`scan_reactors`, `scan_step_results`, `scan_maps`, `scan_map_rollbacks`) return only rows written within the last `context_ttl` (`updated_at > now − context_ttl`), oldest first, capped at `count`.
- Each scan can add a status predicate the caller already applies in Ruby. Each such predicate is verified per caller in tasks.
- The dashboard's `scan_reactors_page` and the new `query_executions` are **not** bounded: they list all history.

**Rationale**:
- This is the "TTL as a query optimization" the user allowed, and it is needed for parity, not just for speed.
- With Redis, a run stranded longer than `context_ttl` has expired and is never re-enqueued. Without the bound, the AR sweeper would resurrect years-old work, which is an observable and dangerous difference (FR-016).
- The bound also keeps sweeps O(active work) instead of O(history).

**Alternatives considered**: Scanning everything non-terminal. Rejected: it would revive ancient stranded runs.

## R-09 Context writes: upsert by ID, project the query columns

**Decision**:
- `store_context` parses the serialized JSON once and upserts `ruby_reactor_executions` by `id`. The projected columns are `storage_name`, `reactor_class`, `status` (via the shared `determine_status`, moved from `RedisReactorScan` into `Adapter`), `parent_context_id`, `root_context_id`, `correlation_id`, `started_at` and `finished_at`, plus the full `context` text.
- On the first write only, it inserts the input index rows (R-11).
- `retrieve_context(id, storage_name)` filters on both columns. That keeps Redis's behavior, where looking up an ID under the wrong class returns nil.

**Rationale**:
- One statement, last writer wins, which is identical to Redis `SET`.
- The single-writer context rule (each context is written only by its owning execution) already prevents concurrent writers.

**Known ceiling**: The adapter parses the JSON on every checkpoint, and the Redis adapter does not. It is bounded by `checkpoint_min_interval` and measured by SC-008. Upgrade path: have `ContextSerializer` hand the projection over as well.

## R-10 Context size: use the full column, map database limits to `ContextTooLargeError`

**Decision**:
- `context` is `text` on PostgreSQL (up to 1 GB) and SQLite, and `LONGTEXT` on MySQL (`size: :long`).
- On MySQL, the adapter reads `@@max_allowed_packet` once and raises `ContextTooLargeError` before writing any context larger than **half** of it. The other half is headroom for the rest of the statement and its escaping.

**Rationale**:
- MySQL's default packet size (64 MB) is below the serializer's 512 MB cap. Silent truncation is impossible with `LONGTEXT`, but a driver error would be confusing.

**Spec delta**: "MUST accept every context size the Redis adapter accepts" holds on PostgreSQL and SQLite. On MySQL it holds up to `max_allowed_packet`, which operators raise in configuration. The documentation states this, and above the limit the error is always `ContextTooLargeError`.

## R-11 Input querying: a portable key/value index, not JSON operators

**Decision**:
- `ruby_reactor_execution_inputs` has `execution_id`, `name` and `value`. `value` is a string; Integer, Float, `true`, `false` and `nil` are stored as their `to_s`/`"null"` form.
- Only top-level scalar inputs are indexed, minus the reactor's `redact: true` inputs. Those are resolved from the reactor class; if the class cannot be loaded, nothing is indexed.
- The index is `(name, value, execution_id)`.
- A filter like `user_id=100` becomes one `EXISTS` subquery per filtered input.

**Rationale**:
- JSON path syntax and type coercion differ across PostgreSQL (`->>`), MySQL (`JSON_EXTRACT`) and SQLite (`json_extract`), and indexing them is engine-specific.
- A plain table is portable, indexable everywhere, and meets SC-007 (100k executions in under 2 s) with a B-tree.
- Redacted inputs never reach the index, so they cannot be filtered on (FR-021).
- The dashboard's detail view already shows `inputs`. A task masks redacted keys there too, since FR-021 says "never displayed".

**Alternatives considered**: A JSON column with per-engine operators. Rejected: three query dialects and three indexing strategies.

## R-12 Append order for map elements: a per-map position under the map row lock

**Decision**:
- `store_map_element_context_id` locks the `ruby_reactor_map_operations` row, inserts `(map, position = element_count, context_id)`, and increments `element_count`.
- Tail reads (`retrieve_map_element_context_ids_from_tail`) and `LLEN` read `position` and `element_count`.

**Rationale**:
- 009's rollback anchors positions at the tail of an append-only list, so a late duplicate append must never shift them.
- Auto-increment IDs do not follow commit order under concurrency: a slower transaction can commit a lower ID after a higher one, which would insert into the middle.
- A per-map counter taken under the map row lock is the append-only list.

## R-13 Simple claims (NX semantics): unique index plus `RecordNotUnique`

**Decision**:
- Correlation IDs, idempotency keys, `start_map_rollback` and the first-wins rollback outcome use an `INSERT` on a unique index. `ActiveRecord::RecordNotUnique` means "already claimed".
- The claims that live as columns on an existing row use a conditional update: the map owner signal (`map_operations.owner_signalled_at`), the rollback signal (`map_rollbacks.signalled_at`), the interrupt resume payload (`interrupt_resumes.payload`) and the first map failure (`map_operations.failed_context_id`). The code is `Model.where(id:, col: nil).update_all(col: value) == 1`, after the row has been ensured. The value always changes from NULL, so the affected-row count is exact on MySQL too.
- Each insert runs outside any adapter transaction. PostgreSQL aborts a transaction on a constraint error, so these inserts are never nested inside `atomically`.
- Counters such as interrupt attempts and rollback offsets use a row-locked read-modify-write. That returns the exact post-increment value `INCR` returns.

**Rationale**:
- This is the portable equivalent of `SET NX` on all three engines.
- A row-locked increment is needed because `UPDATE … SET n = n + 1` followed by a `SELECT` can return a later caller's value.

## R-14 Completion signals: none; the fallback re-check carries correctness

**Decision**:
- `publish` is a no-op.
- `subscribe` blocks with `sleep` until `AsyncWaiter` kills the thread.

**Rationale**:
- `AsyncWaiter` already treats the signal as "pure latency optimisation, never load-bearing" and re-checks the durable record at `timeout/10` (clamped to 1–5 s). That holds on any adapter (FR-012).
- The cost is up to 5 s of extra latency per async wait, measured by SC-008.

**Alternatives considered**: PostgreSQL `LISTEN/NOTIFY`. Deferred: it is PostgreSQL-only, it needs a dedicated connection, and it can be added later behind the same two methods.

## R-15 Period markers and idempotency keys: permanent rows; Redis keeps a TTL

**Decision**:
- `period_mark(key, ttl, context_id: nil)` gains an optional `context_id`.
  - AR inserts `ruby_reactor_period_markers (key_digest, key, context_id, claimed_at)`, first insert wins, and ignores `ttl`.
  - Redis stores `context_id || "1"` as the value, so its behavior is unchanged.
- `period_ttl` returns `-1` on AR (persistent), following the Redis convention.
- Idempotency (US6) adds `claim_idempotency_key(key, context_id, storage_name)`, which returns `nil` when this call claimed the key, otherwise the existing `context_id`.
  - Redis: `SET NX EX context_ttl`.
  - AR: a permanent row.
- `Reactor.run(inputs, idempotency_key:)` claims the key after input validation and before the ordered-lock nonce and the first save.
  - A run that loses the claim does not execute.
  - It waits up to 2 s for the winner's first save, then returns the stored execution's reconstructed result with `idempotent_replay? == true` and the original `execution_id`.
  - If the winner has not saved by then, or is still running, it returns the existing `DispatchResult` (`job_id: nil`) carrying `execution_id`. That class already means "work handed off, not yet resolved", so there is no new result class.
  - The replay flag is a one-method module the result is `extend`ed with (`idempotent_replay? => true`). The new `be_idempotent_replay` matcher checks for it with `respond_to?`.

**Rationale**:
- Claiming after validation means invalid inputs never burn a key.
- Claiming before any save means the losing run writes nothing.
- The 2 s wait matches the existing Worker lock wait (010 R-02).

**Alternatives considered**:
- An AR-only idempotency API. Rejected: it would make the public API depend on the adapter.
- Making `continue(idempotency_key:)` functional. Out of scope (spec Assumptions); interrupt resume claims already dedupe resumes.

## R-16 Schema: versioned plain migrations, a generator, and a boot check

**Decision**:
- Migrations are plain Ruby files under `lib/ruby_reactor/storage/active_record/migrations/NNN_<name>.rb` (`ActiveRecord::Migration[8.0]`).
- `rails g ruby_reactor:install` copies the missing ones, timestamped, into `db/migrate`. Re-running it after a gem upgrade copies only the new ones, matched by migration class name, which is the GoodJob/SolidQueue pattern.
- Non-Rails apps use `RubyReactor::Storage::ActiveRecordAdapter.migrations_path` with `ActiveRecord::MigrationContext`.
- The installed version is the **column default** of `ruby_reactor_schema.version`. Migration 001 creates the table with `t.integer :version, null: false, default: 1`, and each later migration NNN runs `change_column_default :ruby_reactor_schema, :version, from: NNN-1, to: NNN`. The table never needs a row.
- On its first operation, the adapter reads that default from the column metadata (`connection.columns("ruby_reactor_schema")`), compares it with `ActiveRecordAdapter::SCHEMA_VERSION`, and raises a **new** `Error::StorageSchemaError < Error::Base` before any read or write (FR-019). The existing `SchemaVersionError` is not reused: `Worker` and `StepWorker` rescue it as a context-deserialization failure, which would turn a deployment mistake into a failed run. There are three messages:
  - table missing: run install;
  - version lower: run install again, then `db:migrate`;
  - version higher: upgrade the gem.
- A spec pins the SHA-256 of every released migration in `migrations.lock`. Editing a released migration fails CI (FR-018).

**Rationale**:
- The generator follows standard Rails practice.
- A column default survives every path Rails uses to build a database: `db:migrate`, and `db:schema:load` / `db:prepare` / `db:test:prepare` / `maintain_test_schema!` from `db/schema.rb`, because `schema.rb` dumps column defaults on all three engines. A version stored as a **data row** would be lost by every `schema.rb` load, so the adapter would reject a correctly migrated test database. Truncation tools such as DatabaseCleaner can't erase a default either.
- Reading column metadata is one cheap query per process.
- The checksum spec enforces append-only migrations mechanically instead of relying on reviewers.
- SC-009 (upgrade keeps history) is verified once migration 002 exists, by a spec that migrates N−1→N over seeded history. At version 1 the spec covers install and the `schema.rb`-load path only. `down` drops the tables by design, so a down-and-up round trip can't keep history.

## R-17 Test selection: environment variables, tags, real services

**Decision**:
- **Gem suite**:
  - `RUBY_REACTOR_TEST_STORAGE=redis|active_record` (default `redis`) and `RUBY_REACTOR_TEST_DATABASE_URL` (`sqlite3:`, `postgres://`, `trilogy://`) are read in `spec_helper.rb`.
  - Under AR, the suite connects, runs the migrations from `migrations_path` once, and installs `StorageReset::ActiveRecordAdapterReset` (`delete_all` on the gem's tables).
  - Redis stays up in AR jobs because the real-Sidekiq specs use it as the queue backend; storage never touches it.
- **Tags**:
  - `:redis_only` specs test Redis internals (raw keys, `@redis`, Lua).
  - `:active_record_only` specs cover AR-specific behavior: schema check, transaction independence, history past the TTL, the clock.
  - Under the other adapter they are skipped with a reason.
  - A shared adapter-contract example group (`spec/ruby_reactor/storage/adapter_contract_spec.rb`) runs every adapter method's semantics against both adapters (FR-027).
- **demo_app**:
  - `RUBY_REACTOR_STORAGE` (default `redis`) and `RUBY_REACTOR_QUEUE=sidekiq|active_job` (default `sidekiq`) are read in its initializer.
  - `DATABASE_URL` selects the engine, through Rails' standard merge over `database.yml`.
  - The `flush_redis` rake prerequisite keeps its name, which is referenced by the constitution, and resets whichever storage is configured.
  - `RUBY_REACTOR_QUEUE=active_job` also sets the ActiveJob queue adapter: `:test` in the test environment, so `drain_async_jobs` works, and `:async` elsewhere. `:async` runs jobs in-process, so the rake demo needs no worker container. Each demo task already prints its dispatch or terminal outcome.
  - `demo_app/spec/support/redis_helpers.rb` flushes Redis only when Redis is the storage or the queue backend. Otherwise a Redis-free run would fail before the first example.
- **CI**: the gem suite runs `{redis} + {active_record × sqlite, postgres, mysql}`. demo_app runs `{redis+sidekiq} + {active_record+active_job × sqlite, postgres, mysql}` with **no Redis service**, which proves FR-006 and SC-005 on every engine.

**Rationale**:
- Constitution III requires real infrastructure.
- Selecting by environment variable keeps the default developer loop unchanged.
- Leaving Redis out of the AR demo jobs is the cheapest continuous proof of a Redis-free deployment.

## R-18 Dashboard querying: one new adapter method plus a capability flag

**Decision**:
- `query_executions(filters:, cursor:, count:)` takes `reactor_class`, `status`, `from`, `to` and `inputs: {name => value}`.
- It returns the same `{ reactors:, cursor: }` shape as `scan_reactors_page`, with keyset pagination on `(started_at DESC, id DESC)` and an opaque cursor string.
- `GET /api/reactors` accepts `class`, `status`, `from`, `to` and `input[<name>]`. With filters, it calls `query_executions`. Without filters, behavior is unchanged.
- `GET /api/capabilities` returns `{ execution_query: adapter.respond_to?(:query_executions) }`. The GUI shows the filter bar only when that is true. On Redis, a filtered request returns `422 { error: "filters require the active_record storage adapter" }` (FR-022).

**Rationale**:
- Additive: existing clients and the Redis listing stay unchanged.
- The capability flag stops the Redis dashboard from offering filters it cannot run.
