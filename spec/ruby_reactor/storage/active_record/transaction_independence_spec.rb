# frozen_string_literal: true

require "spec_helper"

class TxIndependenceReactor < RubyReactor::Reactor
  input :n

  step :work do
    argument :n, input(:n)
    run { |args, _ctx| RubyReactor.Success(args.n * 2) }
  end
end

class TxIndependenceLockReactor < RubyReactor::Reactor
  input :n

  with_lock(ttl: 30) { |inputs| "tx-independence:#{inputs[:n]}" }

  returns :probe

  # Asks a second connection, mid-run, whether the lock is visible.
  step :probe do
    argument :n, input(:n)
    run do |args, _ctx|
      seen = Thread.new { RubyReactor.configuration.storage_adapter.lock_held?("tx-independence:#{args.n}") }.value
      RubyReactor.Success(seen)
    end
  end
end

# 011 FR-010, R-02: reactor storage has its own pool, so its writes commit
# independently of any transaction the host app has open.
RSpec.describe "ActiveRecord storage inside a host transaction", :active_record_only do # rubocop:disable RSpec/DescribeClass
  before do
    if ActiveRecord::Base.connection_db_config.adapter == "sqlite3"
      skip "SQLite serializes writers: a host transaction blocks reactor writes (documented limitation, R-02)"
    end
  end

  def host_transaction
    ActiveRecord::Base.transaction do
      ActiveRecord::Base.lease_connection.execute("SELECT 1") # materialize the lazy transaction
      yield
    end
  end

  it "keeps the run's history when the host transaction rolls back" do
    id = nil
    host_transaction do
      id = TxIndependenceReactor.run(n: 2).execution_id
      raise ActiveRecord::Rollback
    end

    expect(RubyReactor::Storage::ActiveRecordAdapter::Execution.find(id).status).to eq("completed")
  end

  it "makes a lock visible to other connections before the host transaction ends" do
    result = nil
    host_transaction { result = TxIndependenceLockReactor.run(n: 7) }

    expect(result).to be_success
    expect(result.value).to be(true)
  end
end
