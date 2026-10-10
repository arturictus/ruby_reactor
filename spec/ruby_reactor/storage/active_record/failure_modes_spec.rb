# frozen_string_literal: true

require "spec_helper"

class FailureModesLockReactor < RubyReactor::Reactor
  input :n

  with_lock(ttl: 5) { |inputs| "failure-modes:#{inputs[:n]}" }

  step :work do
    argument :n, input(:n)
    run { |args, _ctx| RubyReactor.Success(args.n) }
  end
end

# 011 spec edge cases: an unreachable database, MySQL's packet limit, SQLite
# write contention and pool exhaustion all fail loudly — never as silent
# success or lost state.
RSpec.describe "ActiveRecord storage failure modes", :active_record_only do # rubocop:disable RSpec/DescribeClass
  let(:adapter_class) { RubyReactor::Storage::ActiveRecordAdapter }
  let(:engine) { ActiveRecord::Base.connection_db_config.adapter }

  # Re-point the shared pool back at the suite's database.
  after { adapter_class.new(database: RubyReactor.configuration.storage.database) }

  it "raises, never succeeds silently, when the database is unreachable" do
    adapter_class.new(database: { adapter: "postgresql", host: "127.0.0.1", port: 1, database: "x",
                                  connect_timeout: 1 })

    expect { RubyReactor.configuration.storage_adapter.store_context("ctx-1", "{}", "X") }
      .to raise_error(ActiveRecord::ConnectionNotEstablished)
  end

  it "rejects a context above MySQL's max_allowed_packet with ContextTooLargeError, writing nothing" do
    skip "MySQL only" unless engine.match?(/mysql|trilogy/)
    adapter = RubyReactor.configuration.storage_adapter
    packet = ActiveRecord::Base.lease_connection.select_value("SELECT @@max_allowed_packet").to_i
    huge = { "context_id" => "big", "reactor_class" => "X", "blob" => "x" * packet }.to_json

    expect { adapter.store_context("big", huge, "X") }.to raise_error(RubyReactor::Error::ContextTooLargeError)
    expect(adapter_class::Execution.where(id: "big")).not_to exist
  end

  it "surfaces SQLite write contention as an error, and succeeds once the writer commits" do
    skip "SQLite only" unless engine == "sqlite3"
    adapter = RubyReactor.configuration.storage_adapter
    blocker = SQLite3::Database.new(ActiveRecord::Base.connection_db_config.database)
    blocker.busy_timeout = 0
    blocker.execute("BEGIN IMMEDIATE")
    adapter_class::Record.connection_pool.with_connection { |c| c.raw_connection.busy_timeout = 200 }

    expect { adapter.lock_acquire("lock:contended", "me", 30) }.to raise_error(ActiveRecord::StatementInvalid)

    blocker.execute("COMMIT")
    expect(adapter.lock_acquire("lock:contended", "me", 30)).to be(true)
  ensure
    blocker&.close
  end

  it "returns pooled connections, so lock auto-extend threads never exhaust a small pool" do
    url = RubyReactor.configuration.storage.database
    config = ActiveRecord::Base.configurations.resolve(url).configuration_hash.merge(pool: 2, checkout_timeout: 2)
    adapter_class.new(database: config)

    results = Array.new(10) { |n| Thread.new { FailureModesLockReactor.run(n: n) } }.map(&:value)

    expect(results).to all(be_success)
  end
end
