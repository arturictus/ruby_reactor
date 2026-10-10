# Contract: Public API

All changes are additive (SemVer MINOR). Existing Redis configuration and call sites are unchanged.

## Configuration

```ruby
RubyReactor.configure do |config|
  config.storage.adapter  = :active_record   # default :redis
  config.storage.database = nil              # optional: :ruby_reactor (database.yml name) | "postgres://…" | { adapter: …, … }
end
```

| setting | default | meaning |
|---|---|---|
| `storage.adapter` | `:redis` | `:redis` or `:active_record` |
| `storage.database` | `nil` | The database for the adapter's dedicated pool. `nil` means the host's primary database config (R-02). Ignored by `:redis`. |
| `context_ttl` | `86_400` | Redis: retention TTL, unchanged. AR: only the sweeper's scan window (R-08). Rows are never expired. |

**Errors**:

- `:active_record` without the `activerecord` gem raises `LoadError`, whose message names the gem and the Gemfile line to add.
- ActiveRecord below 8.0 raises `LoadError` with a version message.
- A missing or mismatched schema raises `RubyReactor::Error::StorageSchemaError` on the adapter's first operation, before any read or write. The message gives the expected and installed versions and the command to run.

## Schema installation (Rails)

```bash
bin/rails generate ruby_reactor:install   # copies missing migrations into db/migrate (timestamped)
bin/rails db:migrate
```

After upgrading the gem, run the same two commands. The generator copies only migrations not already present, matched by migration class name. It never edits existing files.

## Schema installation (ActiveRecord without Rails)

```ruby
RubyReactor::Storage::ActiveRecordAdapter.migrations_path # => absolute path of the shipped migrations
ActiveRecord::MigrationContext.new(RubyReactor::Storage::ActiveRecordAdapter.migrations_path).migrate
```

## Run-level idempotency (US6, both adapters)

```ruby
result = ChargeReactor.run({ order_id: 7, amount: 100 }, idempotency_key: "charge-order-7")
```

- `idempotency_key:` is an optional String, scoped per reactor class. It is claimed after input validation passes and before any step runs or any state is saved. A run whose inputs fail validation does not claim the key.
- **First call**: runs normally and returns its usual result.
- **Repeat call** with the same class and key: no step runs and nothing is written. It returns the original execution's result, with the original `execution_id`, extended with `idempotent_replay? # => true`:
  - completed → `Success` with the original value;
  - failed → `Failure` with the original reason;
  - paused → the original interrupt result;
  - running, pending, or not yet saved after a 2 s wait → `DispatchResult` (`job_id: nil`, `execution_id:` the original).
- **Retention of the key**: `:active_record` keeps it permanently. `:redis` keeps it for `context_ttl`; after that, the key starts a new run. This is documented.
- **Concurrent calls**: exactly one claims the key and runs. Every other call takes the repeat-call path.
- **Inputs on a repeat call** are ignored, including inputs that differ from the original. This is documented: the key identifies the run.

## RSpec surface (`lib/ruby_reactor/rspec`)

- **New matchers**:
  - `be_idempotent_replay`: passes when `result.respond_to?(:idempotent_replay?) && result.idempotent_replay?`.
  - `be_findable_by(**inputs)`, on a `test_reactor` subject: passes when `query_executions` filtered by the subject's class and `inputs` returns its execution. It needs the AR adapter; on Redis it raises a clear error.
- **New matcher chain**: `be_period_marked.for(every).by(execution_id)` compares `period_marker_info[:context_id]`.
- **Helper change**: `test_reactor(klass, inputs, idempotency_key: nil)` forwards the key to `run`.
- **Unchanged under both adapters**:
  - matchers: `be_locked`, `have_available_tokens`, `have_held_tokens`, `have_rate_limit_count`, `be_period_marked`, the ordered-lock matchers and all the others;
  - helpers: `test_reactor`, `drain_async_jobs`.
- **Storage reset between examples**: `reset!` is installed on both adapters. The AR version runs `delete_all` on every `ruby_reactor_*` table except `ruby_reactor_schema`.

## Environment variables (test and demo only, not gem runtime)

| variable | read by | values |
|---|---|---|
| `RUBY_REACTOR_TEST_STORAGE` | gem `spec/spec_helper.rb` | `redis` (default), `active_record` |
| `RUBY_REACTOR_TEST_DATABASE_URL` | gem `spec/spec_helper.rb` | `sqlite3:tmp/ruby_reactor_test.sqlite3?timeout=5000` (default under AR), `postgres://…`, `trilogy://…` |
| `RUBY_REACTOR_STORAGE` | `demo_app/config/initializers/ruby_reactor.rb` | `redis` (default), `active_record` |
| `RUBY_REACTOR_QUEUE` | `demo_app/config/initializers/ruby_reactor.rb` | `sidekiq` (default), `active_job` |
| `DATABASE_URL` | Rails (demo_app) | overrides `database.yml` per engine |
