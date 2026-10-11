# frozen_string_literal: true

require "spec_helper"
require "securerandom"

# 011 SC-007: an input-value filter over 100,000 executions returns its first
# page in under 2 s. Release checklist (quickstart §8): `--tag slow`.
RSpec.describe "ActiveRecord history query performance", :active_record_only, :slow do
  let(:models) { RubyReactor::Storage::ActiveRecordAdapter }

  before do
    skip "SQLite is single-host only" if ActiveRecord::Base.connection_db_config.adapter == "sqlite3"
  end

  it "finds executions by input value among 100,000 in under 2 seconds" do
    now = Time.current
    100.times do |batch|
      rows = Array.new(1_000) do |i|
        id = SecureRandom.uuid
        { id: id, user: ((batch * 1_000) + i) % 5_000 }
      end
      models::Execution.insert_all(rows.map do |row|
        { id: row[:id], storage_name: "Perf", reactor_class: "Perf", status: "completed",
          context: { "context_id" => row[:id], "reactor_class" => "Perf" }.to_json,
          started_at: now - row[:user], created_at: now, updated_at: now }
      end)
      models::ExecutionInput.insert_all(rows.map do |row|
        { execution_id: row[:id], name: "user_id", value: row[:user].to_s }
      end)
    end
    adapter = RubyReactor.configuration.storage_adapter

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    page = adapter.query_executions(filters: { inputs: { "user_id" => "100" } }, cursor: "0", count: 50)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    expect(page[:reactors].size).to eq(20)
    expect(elapsed).to be < 2
  end
end
