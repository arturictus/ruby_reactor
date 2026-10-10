---

description: "Task list for 011 ActiveRecord Storage Adapter"
---

# Tasks: ActiveRecord Storage Adapter

**Input**: Design documents from `specs/011-active-record-adapter/`

**Prerequisites**: [plan.md](plan.md), [spec.md](spec.md), [research.md](research.md), [data-model.md](data-model.md), [contracts/](contracts/), [quickstart.md](quickstart.md)

**Tests**: REQUIRED by Constitution III: test-first, real infrastructure. In every phase, write the spec tasks first and confirm they FAIL before implementing. No mocks of Redis or the database in integration or contract specs.

**Citations**:

- research decisions: `R-nn`;
- data-model sections: `DM §n`;
- contracts:
  - `SA` = [contracts/storage-adapter.md](contracts/storage-adapter.md);
  - `PA` = [contracts/public-api.md](contracts/public-api.md);
  - `DA` = [contracts/dashboard-api.md](contracts/dashboard-api.md).

## Format: `[ID] [P?] [Story] Description`

- **[P]**: can run in parallel (different files, no dependency on an incomplete task)
- **[Story]**: US1–US6 from spec.md

## Path Conventions

Single gem project: `lib/ruby_reactor/`, `spec/`, `demo_app/`, `gui/`, `documentation/`.

**Test rules**:

- **Adapter selection**: `RUBY_REACTOR_TEST_STORAGE=redis|active_record` and `RUBY_REACTOR_TEST_DATABASE_URL` (PA, quickstart §1).
- **Redis stays up in every gem-suite run**: the queue backend and the specs' cross-process scratch logs use it. Under AR, *reactor storage* never touches it.
- **Every change is checked on all four targets**: Redis, AR/SQLite, AR/PostgreSQL (`localhost:6781`) and AR/MySQL (`localhost:6782`), all from `docker compose up -d redis-test test-postgres test-mysql`.
- **Adapter-specific specs** are tagged `:redis_only` (Redis internals, raw keys, TTL expiry) or `:active_record_only`. Each is skipped with a stated reason under the other adapter (T012).
- **Shared test Redis**: don't run the gem suite and the demo suite at the same time, because they flush the same Redis. If another worktree's suite shares the test Redis, rerun failures alone first.

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Dependencies and services. Nothing here changes runtime behavior.

- [X] T001 Add to `Gemfile`, group `:development, :test`:

  ```ruby
  gem "activerecord", ">= 8.0", "< 9"
  gem "sqlite3", "~> 2.1"
  gem "pg", "~> 1.5"
  gem "trilogy", "~> 2.9"
  ```

  Change the existing `gem "activejob", "~> 7.0"` to `">= 8.0", "< 9"`, because ActiveRecord 8 and ActiveJob 7 cannot share ActiveSupport.

  Do **not** touch `ruby_reactor.gemspec` (FR-002, R-01).

  Run `bundle install`, then `bundle exec rspec` on Redis. It must stay green. That is the baseline before any adapter code.
- [X] T002 [P] Add two services to `docker-compose.yml`, both with healthchecks:
  - `test-postgres`: `postgres:16-alpine`, port `6781:5432`, `POSTGRES_PASSWORD=postgres`, `POSTGRES_DB=ruby_reactor_test`, healthcheck `pg_isready`;
  - `test-mysql`: `mysql:8.4`, port `6782:3306`, `MYSQL_ROOT_PASSWORD=root`, `MYSQL_DATABASE=ruby_reactor_test`, healthcheck `mysqladmin ping`.

  Add `tmp/*.sqlite3*` to `.gitignore` if `tmp/` is not already ignored.
- [X] T003 Run `/speckit-constitution` to amend `.specify/memory/constitution.md` to 1.4.0 (MINOR), per plan Complexity Tracking. It runs **before** any task that relies on Redis-free operation.
  - Technical Constraints: "Redis: Required for state persistence…" becomes "State and coordination live in the configured storage adapter: Redis (default) or a relational database via the ActiveRecord adapter (PostgreSQL, MySQL, SQLite)".
  - Principle III: "Redis MUST be reachable" becomes "the configured storage backend MUST be real and reachable; Redis is still required when it is the storage or queue backend".
  - Principle VI: `flush_redis` is "resets the configured storage".

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: The contract, loading, connection, schema baseline, coordination core and test selection that every story needs.

**⚠️ CRITICAL**: No user story work can begin until this phase is complete.

- [X] T004 Write `spec/ruby_reactor/storage/adapter_contract_spec.rb`: `RSpec.shared_examples "a RubyReactor storage adapter"` run against `RubyReactor.configuration.storage_adapter`, one `describe` per SA section. Write it **before** T005. On Redis, the examples for existing methods pass, and the examples for the new Redis behavior (`claim_idempotency_key`, and `period_mark(context_id:)` storing the id) are confirmed FAILING before T005 implements them (Constitution III).

  **Surface guard**:

  - every method `Adapter` declares is implemented, not the base `NotImplementedError` (check `instance_method(m).owner != Storage::Adapter`);
  - `RedisAdapter.public_instance_methods(false)` plus its modules ⊆ `Adapter`'s declared methods, so nothing callable is undeclared.

  **Semantics**: move the behavioral examples (not the key-layout or TTL ones) out of `spec/ruby_reactor/storage/redis_adapter_spec.rb` into this file: `find_context_by_id`, `initialize_map_operation`, `claim_map_owner_signal` without its TTL line, and the whole "map rollback records" group. Ordered locking is covered by `spec/ruby_reactor/storage/redis_ordered_locking_spec.rb`, which T028 makes adapter-agnostic. Also add:

  - **NX first-wins**: correlation (same id is a no-op, different id raises `ValidationError`), `claim_interrupt_resume`, `claim_map_owner_signal`, `claim_map_rollback_signal`, `start_map_rollback` → `[false, first_meta]`, `store_map_rollback_outcome` first wins, `store_map_failed_context_id`, `set_map_offset_if_not_exists`, `semaphore_init`, `claim_idempotency_key`.
  - **Counters return post-change values**: `increment_interrupt_attempts`, `decrement_map_counter_by`, `increment_map_offset`, `claim_map_rollback_positions` clipped to total.
  - **Retrieval behavior**: `retrieve_context` under a different storage name returns `nil`; `retrieve_map_offset` returns `nil` when unset.
  - **Map element order**: append order and tail windows (`retrieve_map_element_context_ids_from_tail`, `retrieve_map_element_context_id(index: -1)`).
  - **Map slots**: `retrieve_map_result_slots` aligned with `nil`s; `missing_map_indices`.
  - **Locks**: re-entrant; foreign owner refused; release by non-owner refused; `lock_extend`; expiry after `ttl` (ttl 1, sleep 1.2); `lock_info`; `lock_ttl` `-2` when absent.
  - **Semaphores**: limit enforced; double release refused; over-cap push refused; `semaphore_acquire(timeout: 0.3)` returns a token released by another thread mid-wait, and returns `nil` after the timeout.
  - **Rate limits**: multi-window all-or-none, and `retry_after`.
  - **Signals**: `subscribe` blocks until killed and `publish` never raises.
- [X] T005 Make `RubyReactor::Storage::Adapter` declare **every** method listed in SA. The method names come from that file's tables: maps, coordination inspectors, ordered locks, `claim_idempotency_key`, `purge_expired_coordination`. Each raises `NotImplementedError`, except:
  - `purge_expired_coordination(limit: 1000)`, which returns `0` on the base class;
  - `query_executions`, which is **not** declared, because it is capability-detected (R-18);
  - `period_marker_info`, which is declared by T061 (US5), not here.

  Also:

  - Move `determine_status` and `execution_evidence?` verbatim from `lib/ruby_reactor/storage/redis_reactor_scan.rb` into `lib/ruby_reactor/storage/adapter.rb`, as public methods.
  - Add `period_mark(key, ttl, context_id: nil)` to `lib/ruby_reactor/storage/redis_locking.rb`, storing `context_id || "1"`.
  - Add `claim_idempotency_key(key, context_id, reactor_class_name)` to `lib/ruby_reactor/storage/redis_adapter.rb`: `SET reactor:<C>:idempotency:<sha256(key)> context_id NX EX context_ttl`, returning `nil` when claimed and otherwise the stored id (R-15).

  Then T004's new-behavior examples pass on Redis.
- [X] T006 [P] Write `spec/ruby_reactor/storage/active_record/loading_spec.rb` (`:active_record_only`, except the first example).
  - The first example runs under any adapter. A fresh `ruby -Ilib -e 'require "ruby_reactor"; RubyReactor.configure { |c| c.storage.adapter = :redis }; RubyReactor.configuration.storage_adapter; exit(defined?(ActiveRecord) ? 1 : 0)'` subprocess exits 0 (FR-002).
  - In a subprocess run with `-I spec/fixtures/no_active_record`, a directory whose `active_record.rb` raises `LoadError` and shadows the bundled gem, selecting `:active_record` raises `LoadError` whose message names `activerecord` and the Gemfile line (FR-003). Bundler provides the gem, so `RUBYOPT` cannot hide it.
  - `storage.database` accepts all three forms (FR-005): a URL String, a Hash (`{ adapter: "sqlite3", database: "tmp/x.sqlite3" }`), and a Symbol naming an entry the spec registers in `ActiveRecord::Base.configurations`. Each resolves to `Record.connection_db_config` with the expected database.
  - `Zeitwerk::Loader.eager_load_all` in a Redis-only process does not load `RubyReactor::Storage::ActiveRecordAdapter`.
- [X] T007 Loading and configuration (R-01, R-02, PA "Configuration"):
  - **`lib/ruby_reactor.rb`**: `loader.ignore("#{__dir__}/ruby_reactor/storage/active_record_adapter.rb", "#{__dir__}/ruby_reactor/storage/active_record", "#{__dir__}/generators")`.
  - **`lib/ruby_reactor/storage/configuration.rb`**: add `attr_accessor :database`, default `nil`.
  - **`lib/ruby_reactor/configuration.rb`**: `storage_adapter` gains `when :active_record`, which runs `require_relative "storage/active_record_adapter"` and then `RubyReactor::Storage::ActiveRecordAdapter.new(database: storage.database)`.
  - **`lib/ruby_reactor/storage/active_record_adapter.rb`**:
    - top-level `begin require "active_record" rescue LoadError` re-raising `LoadError` with the message `"config.storage.adapter = :active_record needs the activerecord gem: add `gem \"activerecord\", \">= 8.0\"` (and a database driver) to your Gemfile"`;
    - a version guard raising `LoadError` if `ActiveRecord.gem_version < Gem::Version.new("8.0")`;
    - `require_relative` for every file under `storage/active_record/`;
    - `class ActiveRecordAdapter < Adapter` including the modules from Phase 3. Every AR-side constant (models, `Record`, `Coordination`, the modules) is nested **inside** this class. Never define `RubyReactor::Storage::ActiveRecord`, which would shadow `::ActiveRecord` (R-01). Write `::ActiveRecord::…` explicitly;
    - `SCHEMA_VERSION = 1`;
    - `def self.migrations_path = File.expand_path("active_record/migrations", __dir__)`.
- [X] T008 Write `lib/ruby_reactor/storage/active_record/record.rb` and `lib/ruby_reactor/storage/active_record/models.rb` (R-02, DM).
  - `ActiveRecordAdapter::Record < ::ActiveRecord::Base` with `self.abstract_class = true`.
  - `ActiveRecordAdapter#initialize(database:)` calls `Record.establish_connection(database || ::ActiveRecord::Base.connection_db_config)`. That creates a **dedicated pool**, so reactor writes never join a host transaction (FR-010).
  - A private `with_db { |conn| … }` = `Record.connection_pool.with_connection`. **Every** adapter method goes through it, so long-lived threads never hold a connection.
  - One model class per table in DM §1–§13, each a single line plus `self.table_name` and `self.primary_key` where it isn't `id`: `Schema, Execution, ExecutionInput, StepResult, MapOperation, MapElement, MapResult, MapRollback, MapRollbackOutcome, CorrelationId, InterruptResume, PeriodMarker, IdempotencyKey, CoordinationEntry`.
  - `ActiveRecordAdapter::MODELS = [...]` lists them for reset. All models are `ActiveRecordAdapter::<Name>`.
- [X] T009 Write `lib/ruby_reactor/storage/active_record/migrations/001_create_ruby_reactor_tables.rb`, `class CreateRubyReactorTables < ActiveRecord::Migration[8.0]`.
  - Create every table, column, primary key, unique index and index exactly as in DM §1–§13.
  - `context` uses `size: :long` (LONGTEXT on MySQL, ignored elsewhere, R-10).
  - Composite primary keys use `primary_key: [...]`.
  - `datetime` columns use `precision: 6`.
  - `ruby_reactor_schema` is created with `t.integer :version, null: false, default: 1` and no rows. The column **default** is the installed version (R-16), so it survives `db/schema.rb` loads and truncation.
  - `down` drops every table.
- [X] T010 Write `spec/ruby_reactor/storage/active_record/coordination_spec.rb` (`:active_record_only`). It runs the same verb sequence against real Redis (`redis` helper) and against `Coordination.atomically([...]) { |kv| … }`, and compares results for:
  - `get set(nx:/ex:/keepttl:) incr incrby decr exists del expire ttl`;
  - `hget hset hdel hincrby hexists hkeys hlen`;
  - `lpop rpush llen`;
  - `sadd srem sismember scard`.

  It also asserts:

  - expiry is judged by the **database** clock: stubbing `Time.now` a day ahead does not expire a 60 s key;
  - a block raising `ActiveRecord::Deadlocked` twice and then succeeding is retried, and a third failure re-raises;
  - `ActiveRecord::LockWaitTimeout` is never retried;
  - two threads incrementing the same key 500 times each end at 1000;
  - `Coordination.peek([key])` returns the same values as `atomically` reads, treats expired rows as absent, inserts no rows, and does not block while another connection holds an `atomically` row lock on PostgreSQL and MySQL.
- [X] T011 Write `lib/ruby_reactor/storage/active_record/coordination.rb` (R-04–R-07). `atomically(keys)`:
  1. digests the keys (`Digest::SHA256.hexdigest`);
  2. `CoordinationEntry.insert_all(missing rows, value: nil)`, skipping duplicates;
  3. `lock.where(key_digest:).order(:key_digest)`;
  4. reads `now_ms` once via the per-engine SQL map in R-06 (keyed on `conn.adapter_name`: `PostgreSQL`, `Mysql2`/`Trilogy`, `SQLite`);
  5. yields a `KV` view whose verbs treat `value.nil? || expires_at_ms <= now_ms` as absent, store JSON values, and give each key its own expiry (`keepttl:` preserves it);
  6. writes back dirty rows only.

  Retry: wrap the whole transaction in up to 3 attempts with `sleep(rand(0.01..0.05))` on `ActiveRecord::Deadlocked` and `ActiveRecord::SerializationFailure` (R-05).

  Logging: on a final failure, log `ruby_reactor.storage op=<caller> engine=<adapter_name> keys=<n> error=<class>`, then re-raise (Constitution IV).

  Also add `peek(keys)`: a read-only `SELECT` of the rows plus the same `now_ms` read and expiry rule, yielding a read-only `KV`. It does no insert, takes no lock and opens no transaction. The read-only inspectors use it (R-04).

  Also add `purge_expired_coordination(limit:)`, which deletes up to `limit` rows `WHERE value IS NULL OR expires_at_ms <= now_ms` and returns the count. Run T010 until green.
- [X] T012 Adapter selection in the gem suite (R-17, PA "Environment variables"):
  - **`spec/support/storage_selection.rb`**:
    - define `STORAGE_UNDER_TEST = ENV.fetch("RUBY_REACTOR_TEST_STORAGE", "redis")`;
    - under `active_record`:
      - set `config.storage.adapter = :active_record` and `config.storage.database = ENV.fetch("RUBY_REACTOR_TEST_DATABASE_URL", "sqlite3:tmp/ruby_reactor_test.sqlite3")`;
      - for PostgreSQL and MySQL URLs, create the database if it is missing;
      - run `ActiveRecord::MigrationContext.new(ActiveRecordAdapter.migrations_path).migrate` once on `Record`'s connection;
    - `config.before(:each, :redis_only)` calls `skip("Redis internals: #{metadata reason or 'raw keys/TTL'}")` unless the suite is on Redis, and `:active_record_only` mirrors it.
  - **`spec/spec_helper.rb`**: the `RubyReactor.configure` block stops hard-coding `adapter = :redis` and delegates to `storage_selection.rb`. The global `before` keeps `redis.flushdb`, because Redis is still the scratchpad and queue, and adds `RubyReactor.configuration.storage_adapter.reset!` when on AR.
- [X] T013 [P] Add `ActiveRecordAdapterReset#reset!` to `lib/ruby_reactor/rspec/storage_reset.rb`. It runs `ActiveRecordAdapter::MODELS - [ActiveRecordAdapter::Schema]`, each `.delete_all` inside `with_db`, and is prepended to `ActiveRecordAdapter` in `install!` only `if defined?(::RubyReactor::Storage::ActiveRecordAdapter)`. `install!` must also run when the AR adapter is loaded after `RSpec.configure`: call `StorageReset.install!` again from the end of `active_record_adapter.rb` when `defined?(::RubyReactor::RSpec::StorageReset)`.
- [X] T014 [P] Make `spec/support/sidekiq_boot.rb` configure the child Sidekiq process's storage from the same environment variables as T012. The real-Sidekiq specs must share the parent's storage under both adapters.

**Checkpoint**:

- On Redis, the suite is green and the contract spec (T004) passes.
- On AR, T010 is green and T004 runs red: the adapter methods are missing, and the surface guard lists them. That red is the Phase 3 work list.

---

## Phase 3: User Story 1 - Run reactors on a relational database with full parity (Priority: P1) 🎯 MVP

**Goal**: Every adapter method in SA is implemented for ActiveRecord with Redis-identical semantics, and the whole existing suite passes on SQLite, PostgreSQL and MySQL.

**Independent Test**: quickstart §1, §2 and §7. The gem suite is green under all four targets, and the stress and transaction-independence specs are green.

### Tests for User Story 1 (write first, confirm FAIL) ⚠️

- [X] T015 [P] [US1] Write `spec/ruby_reactor/storage/active_record/transaction_independence_spec.rb` (`:active_record_only`, FR-010).
  - A reactor run inside `ActiveRecord::Base.transaction { …; raise ActiveRecord::Rollback }` leaves its `Execution` row behind, with status `completed`.
  - A `with_lock` reactor run inside an open host transaction holds a lock that a second thread's `storage_adapter.lock_held?` sees **before** the host transaction ends.
  - On SQLite, skip with reason "SQLite serializes writers; documented limitation (R-02)" when the host transaction has already written.

  The spec needs `ActiveRecord::Base` connected to the same test database. Establish that in the spec's `before(:all)`.
- [X] T016 [P] [US1] Write `spec/ruby_reactor/storage/active_record/history_window_spec.rb` (`:active_record_only`, R-08). Executions, step results, map operations and map rollbacks whose `updated_at` is set (`update_columns`) to `context_ttl + 60` seconds ago are:
  - **absent** from `scan_reactors`, `scan_step_results`, `scan_maps` and `scan_map_rollbacks`;
  - still returned by `retrieve_context`, `find_context_by_id` and `scan_reactors_page`.

  A stranded `running` execution older than `context_ttl` is **not** re-enqueued by `RubyReactor::Sweeper.new.run_once`, which matches Redis, where it would have expired.
- [X] T017 [P] [US1] Write `spec/ruby_reactor/storage/active_record/failure_modes_spec.rb` (`:active_record_only`):
  - **Database unreachable**: point `Record` at an unreachable URL (`postgres://127.0.0.1:1/x`). A reactor `run` returns or raises exactly as the Redis-unreachable case does in `spec/ruby_reactor/step_coordination/lock_spec.rb` (the `redis://127.0.0.1:1` example), never a silent success.
  - **MySQL only** (skip elsewhere): a context larger than `@@max_allowed_packet` raises `RubyReactor::Error::ContextTooLargeError`, and no row is written (R-10).
  - **SQLite contention** (SQLite only, G3): one connection holds a write transaction, and an adapter write from another connection with `timeout: 200` surfaces a busy/timeout error, not a silent success or corrupt state. After the holder commits, the same write succeeds.
  - **Pool exhaustion guard**: with pool size 2, 10 concurrent `with_lock(auto_extend: true)` reactors across threads complete without `ActiveRecord::ConnectionTimeoutError`. This proves `with_db` returns connections (R-02).
- [X] T018 [P] [US1] Write `spec/ruby_reactor/storage/active_record/stress_spec.rb` (`:stress`, `:active_record_only`; add `config.filter_run_excluding :stress` alongside `:slow` in `spec/spec_helper.rb`; SC-006). 4 `fork`ed processes, each reconnecting `Record`, make 250 attempts each on:
  - one lock key: at most one holder at any instant, checked by a holder-count row incremented and decremented inside the critical section, with a max of 1;
  - one semaphore with limit 3: never more than 3 holders;
  - one rate limit of 100 per 3600 s window: exactly 100 allowed. The long window prevents a rollover during the test;
  - one ordered-lock key: advance order equals nonce order.

  Expect 0 violations on PostgreSQL and MySQL. Skip on SQLite with reason "single-host only".

### Implementation for User Story 1

- [X] T019 [P] [US1] Write `lib/ruby_reactor/storage/active_record/contexts.rb`, module `ActiveRecordContexts` (DM §2, §9; R-08, R-09).
  - `store_context`:
    - `JSON.parse` once;
    - `Execution.upsert` with `id, storage_name, reactor_class, status: determine_status(data), parent_context_id, root_context_id, correlation_id, dispatched_child: !!data.dig("private_data","async_dispatched"), context, started_at`;
    - set `finished_at` only when the status is terminal and the existing `finished_at` is null, with `COALESCE` semantics through a conditional `update_all` after the upsert.
  - `retrieve_context(id, C)`: `where(id:, storage_name: C).pick(:context)`, then `JSON.parse`.
  - `find_context_by_id`.
  - `delete_context`: deletes the execution and its `ExecutionInput` rows.
  - Correlation methods: insert, and on `RecordNotUnique` compare `context_id`, raising `Error::ValidationError, "Correlation ID '#{cid}' already exists"` on a mismatch.
  - `scan_reactors(count:, include_dispatched_children:)`:
    - filter `updated_at > now − context_ttl`;
    - filter `parent_context_id IS NULL OR (include_dispatched_children AND dispatched_child)`;
    - order by `updated_at ASC`, limit `count`;
    - return rows in the same `{id:, class:, status:, created_at:, failure:}` shape as `RedisReactorScan#fetch_and_filter_reactors`, with `failure` read from the parsed context.
  - `scan_reactors_page`: keyset over all history ordered by `(started_at DESC, id DESC)`, children excluded as above. The cursor is `Base64.urlsafe_encode64("#{started_at.iso8601(6)}|#{id}")`, and `"0"` means start or end.
  - `expire`: a no-op.
- [X] T020 [P] [US1] Write `lib/ruby_reactor/storage/active_record/step_results.rb`: `store_step_result` is an upsert on `(storage_name, context_id, step_name)` with `status: record["status"]`; `retrieve_step_result`; `scan_step_results(count:)` is limited to the R-08 window and ordered by `updated_at` (DM §4).
- [X] T021 [P] [US1] Write `lib/ruby_reactor/storage/active_record/maps.rb` with every SA "Maps" method over `MapOperation`, `MapElement` and `MapResult` (DM §5–§7; R-12).
  - `ensure_map(map_id, C)` runs `insert_all` skipping duplicates, then a row-locked read-modify-write for each counter and offset method, returning the post-change value.
  - `initialize_map_operation` stores the same metadata hash `RedisAdapter#initialize_map_operation` builds, including `created_at`, and sets `counter`.
  - `store_map_element_context_id` locks the map row, inserts `position = element_count`, and increments it.
  - Tail and `LINDEX` reads use the same index arithmetic as `RedisMapRollback#retrieve_map_element_context_ids_from_tail` and `LINDEX`.
  - `claim_map_owner_signal` ensures the row, then `MapOperation.where(id:, owner_signalled_at: nil).update_all(owner_signalled_at: Time.current) == 1`. `store_map_failed_context_id` follows the same pattern on `failed_context_id` (R-13).
  - `scan_maps` is limited to the R-08 window.
- [X] T022 [P] [US1] Write `lib/ruby_reactor/storage/active_record/map_rollback.rb` with every SA "Map rollback" method (DM §8, R-13).
  - `start_map_rollback`: insert, and on `RecordNotUnique` return `[false, existing_meta]`.
  - `claim_map_rollback_positions`: row-locked `offset += count`, returning `(stop - count)...[stop, total].min`.
  - `store_map_rollback_outcome`: insert the outcome, `RecordNotUnique` → `false`.
  - `map_rollback_indexes_seen`: one `pluck(:element_index).to_set` query, then map `indexes`.
  - `map_rollback_summary`: two aggregate `COUNT` queries, with `FAILED_OUTCOMES` from `RedisMapRollback`. Reference the constant; don't copy it.
  - `each_map_rollback_outcome`: `find_each`-style batches of 500 ordered by position.
  - `scan_map_rollbacks`: limited to the R-08 window.
- [X] T023 [P] [US1] Write `lib/ruby_reactor/storage/active_record/claims.rb` for interrupt resumes (DM §10, R-13).
  - `claim_interrupt_resume`: ensure the row, then `InterruptResume.where(pk…, payload: nil).update_all(payload:) == 1` means claimed.
  - `retrieve_interrupt_resumes`: `where(step_name: names).where.not(payload: nil).pluck(:step_name, :payload).to_h`.
  - `increment_interrupt_attempts`: row-locked `+= 1`, returning the new value.
  - `claim_idempotency_key`: insert into `IdempotencyKey`; on `RecordNotUnique` return the existing `context_id`, otherwise `nil` (DM §12). It is used by US6 and lives here with the other claims.
- [X] T024 [US1] Write `lib/ruby_reactor/storage/active_record/locking.rb`. It holds Ruby twins of `LOCK_ACQUIRE_SCRIPT`, `LOCK_RELEASE_SCRIPT`, `LOCK_EXTEND_SCRIPT`, `SEM_ACQUIRE_SCRIPT`, `SEM_RELEASE_SCRIPT` and `RATE_LIMIT_SCRIPT` from `lib/ruby_reactor/storage/redis_locking.rb`.
  - Each twin is one `atomically(KEYS) { |kv| … }` block that keeps the Lua's statement order, branches and comments. Put a `# twin of RedisLocking::<NAME>` header on each so reviewers can diff them.
  - Non-script **writes** go through `atomically`: `semaphore_init` (NX init plus token push, `SEMAPHORE_TTL`) and `semaphore_reset`.
  - Read-only inspectors go through `Coordination.peek`, with no lock and no insert: `semaphore_held`/`semaphore_held?`, `semaphore_exists?`, `lock_held?`, `lock_info`, `lock_ttl`, `semaphore_state`, `rate_limit_count`, `rate_limit_ttl`.
  - `semaphore_acquire(key, timeout:)` with `timeout > 0` polls `SEM_ACQUIRE` every 50 ms until `timeout` elapses. That replaces `BLPOP`; see the memory note on single-connection stalls.
  - Periods: `period_seen?`, `period_marker?` (`PeriodMarker.exists?(key_digest:)`); `period_mark(key, ttl, context_id: nil)`, which inserts `PeriodMarker` with first insert winning and `ttl` ignored (R-15); and `period_ttl`, which returns `-1` when the marker exists and `-2` otherwise.
- [X] T025 [US1] Write `lib/ruby_reactor/storage/active_record/ordered_locking.rb`. It holds Ruby twins of `ASSIGN_SCRIPT`, `CAN_PROCEED_SCRIPT`, `ADVANCE_SCRIPT`, `HEARTBEAT_SCRIPT` and `SKIP_SCRIPT`, plus `ordered_lock_reset` (`atomically`, deleting the five keys), `ordered_lock_peek` (`Coordination.peek`) and `ordered_lock_keys`, from `lib/ruby_reactor/storage/redis_ordered_locking.rb`. `ordered_lock_keys` is pure: it returns the same five key names as Redis and does no database access. Reuse `RedisOrderedLocking#ordered_lock_keys`; don't copy it.
  - Use the same key names (`ordered_lock:{<key>}:next|last_completed|assigned_at|first_failed|epoch`), each one coordination row with its own TTL.
  - Preserve exactly:
    - the stale-epoch fence;
    - the drained-batch fence (`!kv.exists(next) && !kv.exists(last)`);
    - the poison-drain loop bounded by `my`;
    - `set(..., keepttl: true)`;
    - GC that leaves `epoch` alone;
    - every return tuple and its string state.
  - This is the highest-risk port. Do it after T024 is green. It needs a second reviewer pass, comparing each twin against its Lua line by line before merge (Constitution II).
- [X] T026 [US1] Complete the adapter in `lib/ruby_reactor/storage/active_record_adapter.rb`.
  - Include `ActiveRecordContexts`, `ActiveRecordStepResults`, `ActiveRecordMaps`, `ActiveRecordMapRollback`, `ActiveRecordClaims`, `ActiveRecordLocking`, `ActiveRecordOrderedLocking` and `Coordination`.
  - `publish` is a no-op. `subscribe` does `loop { sleep 3600 }`, and `AsyncWaiter` kills the thread (R-14).
  - On MySQL, cache `@@max_allowed_packet` on first use and raise `Error::ContextTooLargeError` in `store_context` above it (R-10).

  Run T004 under AR on all three engines until it is green, including the surface guard.
- [X] T027 [US1] Call `RubyReactor.configuration.storage_adapter.purge_expired_coordination` once per `run_once` in `lib/ruby_reactor/sweeper.rb`, rescuing errors and logging them as a key=value line, `ruby_reactor.sweeper op=purge_expired_coordination error=<class> message=<msg>`, so a purge failure never stops a sweep (R-07, Constitution IV). Add an example to `spec/ruby_reactor/sweeper_spec.rb`: under AR an expired coordination row is deleted after `run_once`, and under Redis the call returns 0.
- [X] T028 [US1] Classify the Redis-coupled specs. **Rule**: an assertion on storage *behavior* moves to the public adapter API, which runs on both adapters. An assertion on Redis *layout, TTL or simulated expiry* becomes `:redis_only` with a reason, and its semantics must already be covered by T004.

  **Move to the public adapter API**:

  | file | change |
  |---|---|
  | `spec/ruby_reactor/interrupt_spec.rb:22,26` | `retrieve_context` / `retrieve_context_id_by_correlation_id` |
  | `spec/ruby_reactor/context_lock_spec.rb:82,90` | `storage_adapter.lock_held?("async:#{id}")` |
  | `spec/ruby_reactor/dsl/async_reactor_spec.rb:155-168` | `lock_held?("parking:prk1")` |
  | `spec/ruby_reactor/dsl/async_reactor_locks_spec.rb:60` | `lock_info("lock:account:acct-1")` is nil |
  | `spec/ruby_reactor/integration/locking_spec.rb` (all `redis.hset("lock:…")` setups) | `storage_adapter.lock_acquire("lock:…", "other_guy", 60)` |
  | `spec/map/infinite_loop_prevention_spec.rb:52` | `retrieve_map_offset` |
  | `spec/ruby_reactor/map/dispatcher_spec.rb:121` | `RubyReactor.configuration.storage_adapter` |

  **Tag `:redis_only` (TTL, layout or simulated expiry)**:

  - `spec/ruby_reactor/context_ttl_spec.rb` (whole file);
  - `spec/ruby_reactor/interrupt_claims_spec.rb:30,43` (TTL examples);
  - `spec/ruby_reactor/storage/step_result_spec.rb:55-57` (TTL example);
  - `spec/ruby_reactor/interrupt_undo_spec.rb:42` and `spec/ruby_reactor/interrupts/concurrent_interrupts_spec.rb:99` (raw attempts key; the count is covered by T004);
  - `spec/map/map_undo_all_spec.rb:134`, `spec/ruby_reactor/rollback/map_rollback_spec.rb:85,168` and `spec/ruby_reactor/rollback/map_fan_out_settle_spec.rb:180,221` (simulated expiry or raw counter);
  - `spec/map/map_owner_resume_spec.rb:109` (legacy Redis-written metadata);
  - `spec/ruby_reactor/storage/redis_adapter_spec.rb`: the remaining key-layout and TTL examples, after T004 moved the behavioral ones out;
  - `spec/ruby_reactor/async_waiter_spec.rb:39-54` ("wakes on a published signal… < 0.9 s" relies on Redis pub/sub). Add an `:active_record_only` twin in the same file: with no signal, the wait resolves within one fallback interval after the durable record appears (R-14).

  **Make adapter-agnostic**: `spec/ruby_reactor/storage/redis_ordered_locking_spec.rb`. It already uses `RubyReactor.configuration.storage_adapter`. Replace its raw `redis.hexists(at_k, n)` checks with `adapter.ordered_lock_peek(key)[:in_flight].include?(n)`, tag any example that still asserts raw keys or TTLs `:redis_only`, and run the rest under both adapters. It is the line-level parity proof for T025.

  **Split**: `spec/ruby_reactor/step_coordination/lock_spec.rb:183` makes the child-process config adapter-aware, and `:213` (simulated Redis outage) becomes `:redis_only`; its AR twin is T017.

  **Unchanged**, because Redis remains the scratchpad and queue under AR:

  - `spec/support/reactors/*.rb`, `spec/support/step_coordination_helpers.rb`, `spec/support/real_async_backend.rb`;
  - `spec/ruby_reactor/executor/resume_rollback_spec.rb`, `spec/ruby_reactor/step_coordination/{park,rollback_under_contention,ordering_parity}_spec.rb`;
  - the `instance_double(RedisAdapter)` unit specs (`map/result_summary_spec.rb`, `map/result_enumerator_spec.rb`, `web/api_spec.rb:435`, `adapters/{sidekiq,active_job}/worker_spec.rb`).
- [X] T029 [US1] Run the full gem suite under AR on SQLite, then PostgreSQL, then MySQL (quickstart §1). Fix every parity gap **in the AR adapter**, never by weakening a spec. Changing Redis code or a shared spec needs a note in the PR saying why the old assertion was Redis-specific.

  Re-verify against activerecord 8.0.x that `SQLite3Adapter` defaults `default_transaction_mode: :immediate`, as 8.1.1 does at `sqlite3_adapter.rb:162`. If it doesn't, force IMMEDIATE in `Coordination.atomically` and record the result in research R-01.

  Finish with T015–T018 green, and 0 failures plus only reasoned skips on all four targets (SC-001).
- [X] T030 [US1] Write the core of `documentation/storage_adapters.md`:
  - when to choose each adapter;
  - configuration (`storage.adapter`, `storage.database`);
  - supported engines and versions, including **Ruby ≥ 3.2** for the AR adapter (ActiveRecord 8), the SQLite single-host limitation and the host-transaction caveat (R-02);
  - MySQL `max_allowed_packet` (R-10);
  - pool sizing (worker threads + 1 per lock auto-extender + ordered-lock heartbeat);
  - switching adapters: drain in-flight work first, and existing Redis executions are not migrated;
  - the per-adapter difference table: TTL expiry vs permanent history, `:context_unavailable` only from Redis expiry, completion signals vs fallback re-checks.

  In the same change, update the adapter-neutral wording in:

  - `README.md` lines 8, 28, 111–127 (config block: add `storage.adapter = :active_record` and `storage.database`, and `context_ttl` meaning per adapter), 593, 724 and 1588;
  - `documentation/locks_and_semaphores.md` ("Redis-backed" → store-backed; TTL judged by the store's clock);
  - `documentation/data_pipelines.md:219` ("`context_ttl` is the rollback horizon" → Redis only);
  - `documentation/background_and_async.md` (pub/sub signal on Redis, fallback re-check on AR);
  - `documentation/getting_started.md` (choose an adapter).

**Checkpoint**: US1 is complete. Every existing behavior holds on PostgreSQL, MySQL and SQLite through the gem suite. This is the MVP.

---

## Phase 4: User Story 2 - Install and upgrade the schema with versioned migrations (Priority: P1)

**Goal**: The schema installs through a Rails generator or the non-Rails path, upgrades append-only, and a mismatch fails fast before any I/O.

**Independent Test**: quickstart §3, plus the demo_app generator spec.

### Tests for User Story 2 (write first, confirm FAIL) ⚠️

- [X] T031 [P] [US2] Write `spec/ruby_reactor/storage/active_record/schema_spec.rb` (`:active_record_only`, FR-019).
  - After the migrations, the default of `ruby_reactor_schema.version` (`connection.columns("ruby_reactor_schema")`) equals `ActiveRecordAdapter::SCHEMA_VERSION`, and every DM table exists.
  - **`schema.rb` path** (U1): dump the migrated schema with `ActiveRecord::SchemaDumper`, drop every `ruby_reactor_*` table, load the dump, and the check passes. This is the `db:prepare` / `db:test:prepare` / `maintain_test_schema!` path.
  - On a **new** adapter instance:
    - dropping `ruby_reactor_schema` makes the first `store_context` raise `RubyReactor::Error::StorageSchemaError` with a message containing `generate ruby_reactor:install`;
    - `change_column_default` of `version` to `0` gives a message with "run `bin/rails generate ruby_reactor:install` then `db:migrate`" and both versions;
    - changing it to `SCHEMA_VERSION + 1` gives "upgrade the ruby_reactor gem";
    - in every case, `Execution.count` is unchanged.
  - Seeded history is readable after install. SC-009 (an N−1→N upgrade keeps history) gets its spec with migration 002; `down` drops the tables by design, so no round-trip assertion is made at version 1.
- [X] T032 [P] [US2] Write `spec/ruby_reactor/storage/active_record/migrations_lock_spec.rb`. It runs under any adapter and needs no database. For every file in `migrations_path`, its SHA-256 must equal its entry in `lib/ruby_reactor/storage/active_record/migrations/migrations.lock` (YAML `filename: sha256`), and every file must have an entry (FR-018).
- [X] T033 [P] [US2] Write `demo_app/spec/generators/ruby_reactor_install_generator_spec.rb`. Use `Rails::Generators::TestCase` semantics through `Rails.application.load_generators` and `Rails::Generators.invoke` into a tmp destination.
  - The first invoke creates `db/migrate/<ts>_create_ruby_reactor_tables.rb` with the same body as the shipped file.
  - A second invoke creates nothing.

### Implementation for User Story 2

- [X] T034 [P] [US2] Write `lib/ruby_reactor/error/storage_schema_error.rb`: `class StorageSchemaError < Base`. It is **not** `SchemaVersionError`, which `Worker` and `StepWorker` rescue as a deserialization failure (R-16).
- [X] T035 [US2] Add `ensure_schema!` to `lib/ruby_reactor/storage/active_record_adapter.rb`. `with_db` calls it on first use, memoized per adapter instance under a `Mutex`. It reads the default of the `version` column (`conn.columns("ruby_reactor_schema").find { _1.name == "version" }&.default&.to_i`), treating a missing table (`conn.table_exists?` false) as "missing", and raises `StorageSchemaError` with the three messages in R-16 before the caller's query runs. Make T031 green.
- [X] T036 [US2] Write `lib/ruby_reactor/storage/active_record/migrations/migrations.lock` with the SHA-256 of `001_create_ruby_reactor_tables.rb`. Make T032 green. Add a comment block at the top of the lock file: "Released migrations are append-only. Add 00N_…, end it with change_column_default on ruby_reactor_schema.version, bump SCHEMA_VERSION, add its line here."
- [X] T037 [US2] Write `lib/generators/ruby_reactor/install/install_generator.rb`, `class RubyReactor::Generators::InstallGenerator < Rails::Generators::Base` with `include ActiveRecord::Generators::Migration`.
  - For each file in `ActiveRecordAdapter.migrations_path`, sorted, skip it if `db/migrate/*_<name>.rb` already exists. Otherwise copy it as `<next_migration_number>_<name>.rb`, stripping the `NNN_` prefix.
  - Rails discovers the generator at `lib/generators/` through the gem's load path. It is ignored by Zeitwerk (T007).
  - Make T033 green.
- [X] T038 [US2] Run `bin/rails generate ruby_reactor:install` in `demo_app/` and commit the generated `demo_app/db/migrate/<ts>_create_ruby_reactor_tables.rb` and the updated `demo_app/db/schema.rb`.
- [X] T039 [US2] Add an "Install and upgrade" section to `documentation/storage_adapters.md`:
  - Rails: `generate ruby_reactor:install` + `db:migrate`, and the same pair after every gem upgrade;
  - non-Rails: `ActiveRecord::MigrationContext.new(RubyReactor::Storage::ActiveRecordAdapter.migrations_path).migrate`;
  - what `StorageSchemaError` means and how to fix each message.

  Link it from the README "Choosing a storage adapter" section, created here.

**Checkpoint**: US2 is complete. A fresh app installs, a mismatched schema fails loudly, and released migrations are locked.

---

## Phase 5: User Story 3 - Test both adapters independently (Priority: P2)

**Goal**: The demo_app selects its adapter and queue through environment variables, docker-compose covers every combination, and CI runs the full matrix, with Redis-free AR demo jobs.

**Independent Test**: quickstart §4. The demo suite is green under Redis+Sidekiq and under AR+ActiveJob on each engine, and the `demo:all` acceptance run passes with Redis stopped.

### Tests for User Story 3 (write first, confirm FAIL) ⚠️

- [X] T040 [P] [US3] Write `demo_app/spec/config/storage_selection_spec.rb`.
  - With `RUBY_REACTOR_STORAGE=active_record`, `RubyReactor.configuration.storage_adapter` is an `ActiveRecordAdapter`.
  - With `RUBY_REACTOR_QUEUE=active_job`, `async_router` is `RubyReactor::Adapters::ActiveJob::Router`.
  - In that mode, a full `test_reactor` run of an async demo reactor opens **no** Redis connection. Assert it by running the spec with `REDIS_URL=redis://127.0.0.1:1` and expecting success (FR-006).

### Implementation for User Story 3

- [X] T041 [US3] Make `demo_app/config/initializers/ruby_reactor.rb` read `ENV.fetch("RUBY_REACTOR_STORAGE", "redis")` and `ENV.fetch("RUBY_REACTOR_QUEUE", "sidekiq")`:
  - `:active_record` storage leaves `storage.database` nil (primary DB);
  - `active_job` sets `config.async_router = RubyReactor::Adapters::ActiveJob::Router` and `Rails.application.config.active_job.queue_adapter = Rails.env.test? ? :test : :async`. `:test` makes `drain_async_jobs` work. `:async` runs jobs in-process, so the rake and docker demo needs no worker container. The Sidekiq initializer stays, and is used only when the queue is `sidekiq`;
  - the Redis settings stay but are only used when selected.

  Add `gem "pg"` and `gem "trilogy"` to `demo_app/Gemfile`. `DATABASE_URL` selects the engine through Rails' standard merge; `database.yml` is unchanged.
- [X] T042 [US3] In `demo_app/spec/support/redis_helpers.rb`, run `redis.flushdb` only when `RubyReactor.configuration.storage.adapter == :redis` or `ENV.fetch("RUBY_REACTOR_QUEUE", "sidekiq") == "sidekiq"`. A Redis-free run otherwise fails before the first example (FR-006).
- [X] T043 [US3] Make the `demo:flush_redis` task in `demo_app/lib/tasks/demo_reactors.rake` storage-agnostic. Keep its name, because Constitution VI references it, and update its `desc` to "reset reactor storage".
  - Under `:redis`: today's `flushdb`.
  - Under `:active_record`: `(RubyReactor::Storage::ActiveRecordAdapter::MODELS - [RubyReactor::Storage::ActiveRecordAdapter::Schema]).each(&:delete_all)`. No `Redis.new` is created.
  - Always: `Product.delete_all` and `RubyReactor.start_sweeper!`.

  `demo:all` **already exists** (`demo_reactors.rake` ~line 241). Do not redefine it, because Rake would merge the definitions and run tasks twice. Append the three new tasks to its existing prerequisite list as their stories land (`:active_record_history`, `:yearly_report`, `:idempotent_charge`).
- [X] T044 [US3] Run `demo_app` specs under `RUBY_REACTOR_STORAGE=active_record RUBY_REACTOR_QUEUE=active_job` on SQLite, then on PostgreSQL and MySQL via `DATABASE_URL`. Fix adapter gaps in `lib/`.
  - A demo spec that is inherently Sidekiq-specific gets the `:sidekiq_only` tag, with a skip hook added to `demo_app/spec/rails_helper.rb` keyed on `RUBY_REACTOR_QUEUE`, and a reason.
  - A demo spec that is inherently Redis-specific gets `:redis_only`, using the same hook pattern.
  - Confirm that `DatabaseCleaner` truncation (`demo_app/spec/rails_helper.rb`) empties the `ruby_reactor_*` tables between examples without breaking the schema check. The version is a column default (R-16), so truncation can't remove it.
  - Make T040 green.
- [X] T045 [P] [US3] Update `docker-compose.yml`:
  - add `demo-postgres` (`postgres:16-alpine`, port 6783) and `demo-mysql` (`mysql:8.4`, port 6784), with healthchecks and volumes;
  - pass `RUBY_REACTOR_STORAGE`, `RUBY_REACTOR_QUEUE` and `DATABASE_URL` through to `demo-app` and `demo-sidekiq` with `${VAR:-default}`.

  The Redis-free run is documented as `docker compose run --rm --no-deps -e RUBY_REACTOR_STORAGE=active_record -e RUBY_REACTOR_QUEUE=active_job demo-app bin/rails db:prepare demo:all`, with `docker compose stop redis-test demo-redis` first (quickstart §4, SC-005).
- [X] T046 [US3] Update `.github/workflows/main.yml`.
  - **`build`** (gem suite): add `matrix.storage: [redis, sqlite, postgres, mysql]`, keeping the Ruby matrix. Add `postgres:16` and `mysql:8.4` services, keep the `redis-stack-server` service, and set `RUBY_REACTOR_TEST_STORAGE` and `RUBY_REACTOR_TEST_DATABASE_URL` per matrix entry.
  - **`demo_app`**: add `matrix.combo`:
    - `redis-sidekiq`, with the Redis service, as today;
    - `ar-sqlite`, `ar-postgres` and `ar-mysql`, each with **no Redis service**, `RUBY_REACTOR_STORAGE=active_record`, `RUBY_REACTOR_QUEUE=active_job` and `DATABASE_URL`. Each runs `bin/rails db:prepare`, `bundle exec rspec` and `bin/rails demo:all`.
  - The `:stress` (SC-006) and `:slow` (SC-007) specs and the SC-008 timing are **not** PR-CI steps. They are the release checklist in quickstart §8.
- [X] T047 [US3] Update the `README.md` development section (lines 1610–1660: test databases, the four test targets, the environment variables, the Redis-free demo run, and the Ruby ≥ 3.2 needed to run the suite) and `documentation/testing.md` (`RUBY_REACTOR_TEST_STORAGE`, `RUBY_REACTOR_TEST_DATABASE_URL`, the `:redis_only` and `:active_record_only` tags, storage reset per adapter).

**Checkpoint**: US3 is complete. Both adapters are proven on every PR, and a Redis-free deployment is proven continuously.

---

## Phase 6: User Story 4 - Keep and query the full execution history from the dashboard (Priority: P2)

**Goal**: All history is listable and filterable by class, status, time and input value on AR. Redacted inputs are never shown or filterable. The Redis dashboard degrades gracefully.

**Independent Test**: quickstart §5. The API filters return exactly the matching executions, `/capabilities` reflects the adapter, and on Redis a filtered request gets a 422.

### Tests for User Story 4 (write first, confirm FAIL) ⚠️

- [X] T048 [P] [US4] Add a `query_executions` section to `spec/ruby_reactor/storage/adapter_contract_spec.rb` (`:active_record_only`).
  - **Seeding**: executions of two classes, with statuses `completed`/`failed`/`paused`, `user_id` inputs `100`/`200`, one input declared `redact: true`, one Hash input, and one 300-character input.
  - **Assertions**:
    - each filter alone and combined returns exactly the matching ids, ordered `started_at DESC, id DESC`;
    - paging with `count: 2` walks every match exactly once and ends with `"0"`;
    - a filter on the redacted input, the Hash input or the 300-character input returns `[]`;
    - an execution whose `updated_at` is older than `context_ttl` is still returned (FR-014);
    - `ExecutionInput` rows exist only for scalar, non-redacted values of 255 characters or fewer (R-11).
- [X] T049 [P] [US4] Extend `spec/ruby_reactor/web/api_spec.rb` with these examples (DA):
  - `GET /api/capabilities` returns `{"execution_query": true}` on AR and `false` on Redis;
  - `GET /api/reactors?input[user_id]=100&status=completed` returns only matches on AR and `422` with the DA message on Redis;
  - an invalid `status` or `from` returns `400`;
  - without filters, the response is unchanged on both adapters;
  - `GET /api/reactors/:id` shows `"[REDACTED]"` for a `redact: true` input on **both** adapters (FR-021).
- [X] T050 [P] [US4] Write `spec/ruby_reactor/storage/active_record/query_performance_spec.rb` (`:slow`, `:active_record_only`, skip on SQLite). Seed 100,000 executions with `insert_all` in batches, plus their input rows. The first page of `query_executions(filters: { inputs: { "user_id" => "100" } }, count: 50)` must return in under 2 s (SC-007).
- [X] T051 [P] [US4] Write a GUI test in `gui/src/components/__tests__/Dashboard.test.tsx`: the filter bar is rendered only when `/api/capabilities` returns `execution_query: true`, and submitting it requests `/api/reactors` with `class`, `status`, `from`, `to` and `input[name]` params.

### Implementation for User Story 4

- [X] T052 [US4] Add the input index write to `store_context` in `lib/ruby_reactor/storage/active_record/contexts.rb`, on every store, with duplicates skipped by `insert_all` (R-11, DM §3). Inputs never change after the first store, so repeats are no-ops. That costs one extra statement per checkpoint, which is a known ceiling. The upgrade path is to cache indexed ids per process.
  - Resolve the redacted input names via `RubyReactor::Context.resolve_reactor_class(data["reactor_class"])&.inputs&.select { |_, c| c[:redact] }&.keys`. If the class cannot be resolved, index nothing.
  - Deserialize `data["inputs"]` with `ContextSerializer.deserialize_value`, and keep top-level `String`/`Integer`/`Float`/`true`/`false`/`nil` values whose `to_s` is 255 characters or fewer (`nil` becomes `"null"`).
  - Write them with `ExecutionInput.insert_all`, skipping duplicates.
- [X] T053 [US4] Add `query_executions(filters:, cursor:, count:)` to `lib/ruby_reactor/storage/active_record/contexts.rb` (R-18).
  - Filters: `reactor_class`, `status`, `from` and `to` on `started_at`, and one `EXISTS (SELECT 1 FROM ruby_reactor_execution_inputs WHERE execution_id = executions.id AND name = ? AND value = ?)` per input.
  - Exclude children, as `scan_reactors_page` does, and reuse its keyset cursor and row shape.
  - Make T048 and T050 green.
- [X] T054 [US4] Update `lib/ruby_reactor/web/api.rb`:
  - add `r.on "capabilities"`, which returns `{ execution_query: adapter.respond_to?(:query_executions) }`;
  - in `GET /reactors`, if any of `class status from to input` is present, validate (`400`), return `422` when the adapter lacks `query_executions`, otherwise call it and set `X-Next-Cursor`;
  - in `GET /reactors/:id`, mask `inputs` keys declared `redact: true` on the resolved class with `RubyReactor::Step::InputContract::REDACTED`, including the `inputs` of hydrated `composed_contexts`. Step results are out of scope (FR-021).

  Make T049 green. Note the Redis-visible masking change for the CHANGELOG (plan, Spec Deltas).
- [X] T055 [US4] Add a filter bar to `gui/src/components/Dashboard.tsx`, with a `fetchCapabilities` and a filter-param builder in `gui/src/lib/reactors.ts`. The bar has class, status, from/to and repeatable input name=value fields, and renders only when `execution_query` is true. Make T051 green. Rebuild the assets into `lib/ruby_reactor/web/public/` with the project's existing build script.
- [X] T056 [P] [US4] Add the matcher `be_findable_by(**inputs)` to `lib/ruby_reactor/rspec/matchers.rb`, applied to a `test_reactor` subject (Constitution VI: extend the shared surface).
  - It passes when `storage_adapter.query_executions(filters: { reactor_class: subject's class name, inputs: inputs.transform_values(&:to_s) }, cursor: "0", count: 50)[:reactors]` includes the subject's execution id.
  - It raises a clear error when the adapter lacks `query_executions`.
  - Add a matcher spec in `spec/ruby_reactor/rspec/matchers_spec.rb`, under `:active_record_only`.
- [X] T057 [US4] Write the demo:
  - `demo_app/app/reactors/active_record_history_reactor.rb`: class-based steps, `input :user_id`, `input :card_token, redact: true`; a `charge` step with `compensate`, plus a failing variant input to show the failure path;
  - a rake task `demo:active_record_history` (`[:environment, :flush_redis]`) that runs it for `user_id` 100, 100 and 200, prints the ids, and prints the `/ruby_reactor/api/reactors?input[user_id]=100` URL. Under Redis it prints `⏭  SKIPPED: needs RUBY_REACTOR_STORAGE=active_record` and returns, so `demo:all` stays green. Add it to the `demo:all` prerequisites;
  - `demo_app/spec/reactors/active_record_history_reactor_spec.rb` (`type: :reactor`, `:active_record_only` via the T044 hook), using only `test_reactor`, `be_success`/`be_failure` and `be_findable_by(user_id: 100)`, plus `expect(reactor).not_to be_findable_by(card_token: "tok")` for the redacted input.
- [X] T058 [US4] Add a "History and dashboard filters" section to `documentation/storage_adapters.md`: what is kept, the filter params, which inputs are indexed (scalar, non-redacted, 255 characters or fewer), redaction masking, and the `be_findable_by` matcher. Also update the `README.md` dashboard paragraph and `documentation/testing.md` (matcher).

**Checkpoint**: US4 is complete. History is browsable and queryable from the dashboard.

---

## Phase 7: User Story 5 - Period markers that never expire (Priority: P3)

**Goal**: Each claimed period bucket is recorded permanently on AR, with the claiming execution and the time.

**Independent Test**: quickstart §6. A second `:year` run in the same bucket is halted, the marker names the claiming execution, and `period_ttl` is `-1` on AR.

### Tests for User Story 5 (write first, confirm FAIL) ⚠️

- [X] T059 [P] [US5] Add examples to `spec/ruby_reactor/storage/adapter_contract_spec.rb`:
  - `period_marker_info(base, every)` returns `{ context_id:, claimed_at: }` after `period_mark(key, ttl, context_id: "c1")` on both adapters. On Redis, `claimed_at` is `nil`, and `context_id` is `nil` when the marker was written without one (the value `"1"`).
  - `:active_record_only`: a second `period_mark` for the same key keeps the first `context_id`; `period_ttl` is `-1`; the marker is still seen after `Period.ttl_seconds(:year)` would have elapsed. Use `RubyReactor::Period.key(base, :year, now:)` on Jan 1 and Dec 31 of the same year, giving the same key and the same marker (SC-010).
- [X] T060 [P] [US5] Extend `spec/ruby_reactor/step_coordination/period_spec.rb`, or the existing `with_period` spec found by `grep -rl with_period spec`: after a reactor-level and a step-level `with_period` run, `period_marker_info` names that run's `context_id`.

### Implementation for User Story 5

- [X] T061 [US5] Pass `context_id: @context.context_id` to `period_mark` in `lib/ruby_reactor/executor.rb` (~line 645) and `lib/ruby_reactor/executor/step_coordination.rb` (~line 648).
  - Add `period_marker_info(key_base, every, now: Time.now.utc)`:
    - Redis (`lib/ruby_reactor/storage/redis_locking.rb`): `GET` the key, so the value is the `context_id` or `"1"`, and return `nil` when absent;
    - AR (`lib/ruby_reactor/storage/active_record/locking.rb`): the marker row.
  - Declare it in `lib/ruby_reactor/storage/adapter.rb`.
  - Make T059 and T060 green.
- [X] T062 [US5] In `lib/ruby_reactor/web/coordination_serializer.rb` (~line 269), add `claimed_by:` and `claimed_at:` from `period_marker_info` to a marked period's entry. Render them in `gui/src/components/CoordinationPanel.tsx`, then rebuild the assets.
- [X] T063 [P] [US5] Add the chain `.by(execution_id)` to `be_period_marked` in `lib/ruby_reactor/rspec/matchers.rb`, comparing `period_marker_info(...)[:context_id]`. Add a matcher spec example.
- [X] T064 [US5] Write the demo:
  - `demo_app/app/reactors/yearly_report_reactor.rb`: `with_period every: :year` keyed on `report_name`, with a class-based `build_report` step;
  - a rake task `demo:yearly_report` (`[:environment, :flush_redis]`) that runs it twice and prints `completed` then `halted (already ran this year)`. Add it to the `demo:all` prerequisites;
  - `demo_app/spec/reactors/yearly_report_reactor_spec.rb`, which runs under both adapters: the first run `be_success`, the second `be_halted`, and `expect("annual:#{name}").to be_period_marked.for(:year).by(first.execution_id)`.
- [X] T065 [US5] Update the `with_period` section of `documentation/locks_and_semaphores.md`: markers are permanent on AR and record the claiming execution; on Redis they live `Period.ttl_seconds`; the `.by(...)` matcher chain.

**Checkpoint**: US5 is complete.

---

## Phase 8: User Story 6 - Run-level idempotency keys (Priority: P3)

**Goal**: `Reactor.run(inputs, idempotency_key:)` runs once per key and class, and repeats replay the original outcome. Keys are permanent on AR and kept for `context_ttl` on Redis.

**Independent Test**: quickstart §6. A repeated key returns `be_idempotent_replay` with the original `execution_id` and no step re-run, and concurrent duplicates produce one execution.

### Tests for User Story 6 (write first, confirm FAIL) ⚠️

- [X] T066 [P] [US6] Write `spec/ruby_reactor/idempotency_spec.rb` (PA "Run-level idempotency"). Both adapters unless noted:
  - **Outcomes**:
    - a completed run, then a repeat with the same key and **different** inputs, returns `Success` with the original value, the same `execution_id` and `idempotent_replay? == true`, and a step-counter fixture shows no step ran again;
    - a failed original → a `Failure` replay with the original reason;
    - a paused original (interrupt) → the interrupt result replay;
    - an original still running (async, not drained) → a `DispatchResult` with the original `execution_id`.
  - **Claiming**:
    - invalid inputs do not claim, so a valid run with the same key afterwards executes;
    - the same key on a different reactor class executes;
    - 5 threads behind a barrier start the same key: exactly 1 execution, and every result has its `execution_id`.
  - **Retention**:
    - `:redis_only`: with `context_ttl = 1` and `sleep 1.2`, the key runs again;
    - `:active_record_only`: with the claim row's `created_at` moved past `context_ttl`, it still replays.
- [X] T067 [P] [US6] Add `be_idempotent_replay` to `spec/ruby_reactor/rspec/matchers_spec.rb`: passes for an `extend`ed result, fails with a clear message otherwise.

### Implementation for User Story 6

- [X] T068 [US6] Add `module RubyReactor::IdempotentReplay; def idempotent_replay? = true; end` to `lib/ruby_reactor.rb`, next to `DispatchResult`.
- [X] T069 [US6] Add `run(inputs = {}, idempotency_key: nil)` to `lib/ruby_reactor/dsl/reactor.rb` and `lib/ruby_reactor/reactor.rb` (R-15).
  - Claim the key **after** `validate_inputs` succeeds and **before** `assign_ordered_lock_nonce!` and any `save_context`, using `storage_adapter.claim_idempotency_key(key, @context.context_id, RubyReactor.reactor_storage_name(self.class))`.
  - If an existing id comes back, poll `self.class.find(existing)` every 100 ms for up to 2 s, rescuing `ValidationError` "not found".
    - **Found**: take `reactor.result`. If it is `:unexecuted`, which means running or pending, use `DispatchResult.new(job_id: nil, execution_id: existing)`.
    - **Not found** after 2 s: `DispatchResult.new(job_id: nil, execution_id: existing)`.
    - Either way, `result.extend(IdempotentReplay)`, `attach_execution_id!`, and return without saving anything.
  - Make T066 green.
- [X] T070 [US6] Add `be_idempotent_replay` to `lib/ruby_reactor/rspec/matchers.rb`. Let `test_reactor(klass, inputs, idempotency_key: nil)` and `TestSubject` (`lib/ruby_reactor/rspec/helpers.rb`, `lib/ruby_reactor/rspec/test_subject.rb`) forward `idempotency_key:` to `run`. Make T067 green.
- [X] T071 [US6] Write the demo:
  - `demo_app/app/reactors/idempotent_charge_reactor.rb`: class-based `reserve` and `charge` steps, each with `compensate`; inputs `order_id`, `amount` and `decline` (boolean, default false). `charge` fails when `decline` is true;
  - a rake task `demo:idempotent_charge` (`[:environment, :flush_redis]`) with two scenarios, each run twice with `idempotency_key: "charge-order-#{order_id}"`:
    - a successful order prints `charged`, then `replayed (no second charge), execution <id>`;
    - a declined order prints `failed (reserve compensated)`, then `replayed failure, execution <id>`.
    Add it to the `demo:all` prerequisites;
  - `demo_app/spec/reactors/idempotent_charge_reactor_spec.rb`, which runs under both adapters:
    - success path: the first call `be_success` and `have_run_step(:charge)`; the second `be_idempotent_replay` and `be_success` with the same `execution_id`;
    - failure path (Principle VI): the first call `be_failure` and shows `reserve` compensated through the shipped matchers; the second, with the same key, `be_failure` and `be_idempotent_replay`, and nothing runs again.
- [X] T072 [US6] Document `idempotency_key:` in `README.md` (core usage section near `run`), `documentation/core_concepts.md` and `documentation/storage_adapters.md`: semantics, replay result types, retention per adapter, inputs ignored on a repeat, concurrency, and the `be_idempotent_replay` matcher in `documentation/testing.md`.

**Checkpoint**: All six user stories are complete.

---

## Phase 9: Polish & Cross-Cutting Concerns

- [X] T073 [P] Update the remaining Redis-specific wording wherever the claim is adapter-neutral, in `documentation/README.md`, `documentation/interrupts.md` and `documentation/retry_configuration.md`. Check with `grep -n Redis documentation/*.md README.md`: every remaining hit must be Redis-specific.
- [X] T074 [P] Add a `CHANGELOG.md` **Features** entry:
  - the ActiveRecord storage adapter (PostgreSQL, MySQL, SQLite), with install and upgrade;
  - dashboard history filters and `/api/capabilities`;
  - permanent period markers and `be_period_marked.by`;
  - `run(idempotency_key:)` and `be_idempotent_replay`;
  - `be_findable_by`.

  Add a **Bug Fixes** entry: the dashboard detail now masks `redact: true` inputs.
- [X] T075 Audit SC-002. Write `specs/011-active-record-adapter/checklists/claims.md`: one row per behavioral claim in `README.md` and `documentation/*.md` (locks, semaphores, rate limits, periods, ordered locks, durability, recovery, rollback, interrupts, maps, signals, retention). Each row names the spec that covers it under both adapters, or the documented per-adapter difference (`documentation/storage_adapters.md`). Any claim with neither is a gap: fix the code, the spec or the documentation before merge.
- [X] T076 Run `bundle exec rubocop` on all new and changed Ruby files. The Lua-twin methods may carry the same `rubocop:disable` set as their Redis modules (`Metrics/*`, `Naming/PredicateMethod`); nothing else.
- [X] T077 Execute quickstart §1–§7 end to end on a clean checkout, plus the §8 release checklist (stress, slow query, SC-008 timing). Record any deviation in `specs/011-active-record-adapter/quickstart.md`.
- [X] T078 Run the `demo-app-e2e-verify` skill twice, once with Redis+Sidekiq and once with `RUBY_REACTOR_STORAGE=active_record RUBY_REACTOR_QUEUE=active_job`. Fix every finding in `lib/`, or record why it is out of scope.

---

## Dependencies & Execution Order

### Phase dependencies

- **Setup (Phase 1)** comes first.
- **Foundational (Phase 2)** depends on Setup and blocks all stories.
- **US1 (Phase 3)** depends on Foundational. It is the MVP, and every later story assumes AR parity.
- **US2 (Phase 4)** depends on Foundational (T009 migration). It is independent of US1's methods, so it can run in parallel with US1 after T014.
- **US3 (Phase 5)** depends on US1 (a demo under AR needs the full adapter) and US2 (T038 demo migration).
- **US4 (Phase 6)** depends on US1 (contexts.rb). Its API, GUI and doc parts are independent of US3, but its demo spec (T057) needs T044's tag hook.
- **US5 (Phase 7)** depends on US1 (T024). Its demo spec (T064) needs US3's demo setup.
- **US6 (Phase 8)** depends on Foundational (T005 Redis `claim_idempotency_key`) and US1 (T023 AR claim). Its demo spec (T071) needs US3.
- **Polish (Phase 9)** comes after the stories it touches. The constitution amendment (T003) is in Phase 1, so it lands before any Redis-free work.

### Within each story

- Tests first, and confirmed failing.
- Adapter modules, then integration (sweeper, executor, API), then demo, then docs.
- T025 (ordered locking) only after T024 is green.
- T029 (the full-suite gate) after T019–T028.

### Parallel opportunities

- **Phase 2**: T004 (contract spec) comes first, then T005 (Redis additions it specifies). T006, T013 and T014 run alongside the T007→T008→T009→T011 chain. T010 is written before T011.
- **US1**: T015–T018 (four spec files) in parallel. Then T019–T023 (five independent modules) in parallel. Then T024 → T025 → T026 sequentially.
- **US2**: T031–T033 in parallel, and T034 in parallel with the specs.
- **US4**: T048–T051 in parallel. T056 can run in parallel with T052–T055.
- **US5 and US6** can proceed in parallel with each other once US1 and US3 are done.

## Parallel Example: User Story 1

```bash
# Specs (write first, all must fail under AR):
Task: "T015 transaction_independence_spec.rb"
Task: "T016 history_window_spec.rb"
Task: "T017 failure_modes_spec.rb"
Task: "T018 stress_spec.rb"

# Independent history modules:
Task: "T019 contexts.rb"     Task: "T020 step_results.rb"
Task: "T021 maps.rb"         Task: "T022 map_rollback.rb"
Task: "T023 claims.rb"

# Then sequentially: T024 locking.rb → T025 ordered_locking.rb → T026 adapter assembly → T027 → T028 → T029
```

## Implementation Strategy

### MVP first (US1 + US2, both P1)

1. Phase 1 and Phase 2: the contract spec green on Redis, and coordination core green on AR.
2. Phase 3 (US1): the full gem suite green on SQLite, PostgreSQL and MySQL. **Stop and validate** with quickstart §1, §2 and §7.
3. Phase 4 (US2): installable and upgrade-safe. Together with US1, that is a shippable adapter.

### Incremental delivery

4. US3: CI matrix plus a Redis-free demo, which locks parity in for every future PR.
5. US4: history and dashboard filters, the main reason users choose AR.
6. US5 and US6: permanent periods and idempotency keys.
7. Polish: docs sweep, CHANGELOG, the SC-002 claims audit, rubocop, end-to-end verification and the release checklist.

### Review hot spots (Constitution II)

- **T025**: each ordered-lock twin is reviewed line by line against its Lua.
- **T011**: lock ordering, retry purity, database clock.
- **T019**: status projection and `finished_at`.
- **T021**: the append position under the map lock.
- **T069**: the claim placement relative to validation and the first save.
