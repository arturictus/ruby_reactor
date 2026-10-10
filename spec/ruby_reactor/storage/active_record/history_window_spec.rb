# frozen_string_literal: true

require "spec_helper"

# 011 R-08/FR-016: history is never expired, but the sweeper-facing scans only
# see rows written within context_ttl — what Redis would still hold — so old
# stranded work is never revived.
RSpec.describe "ActiveRecord history and the sweeper window", :active_record_only do # rubocop:disable RSpec/DescribeClass
  let(:adapter) { RubyReactor.configuration.storage_adapter }
  let(:models) { RubyReactor::Storage::ActiveRecordAdapter }
  let(:aged) { Time.current - RubyReactor.configuration.context_ttl - 60 }
  let(:reactor_class) { Class.new { def self.name = "HistoryWindowReactor" } }

  def store_running_context
    context = RubyReactor::Context.new({ n: 1 }, reactor_class)
    context.status = :running
    context.current_step = :work
    adapter.store_context(context.context_id, RubyReactor::ContextSerializer.serialize(context), reactor_class.name)
    context.context_id
  end

  def age!(model) = model.update_all(updated_at: aged)

  it "keeps old executions readable and listed, but out of the sweeper's scan" do
    id = store_running_context
    age!(models::Execution)

    expect(adapter.retrieve_context(id, reactor_class.name)).to include("context_id" => id)
    expect(adapter.find_context_by_id(id)).to include("context_id" => id)
    expect(adapter.scan_reactors_page(cursor: "0", count: 10)[:reactors].map { |r| r[:id] }).to eq([id])
    expect(adapter.scan_reactors(count: 10, include_dispatched_children: true)).to be_empty
  end

  it "does not re-enqueue a run stranded longer than context_ttl" do
    store_running_context
    age!(models::Execution)
    enqueued = []
    router = Class.new { define_singleton_method(:perform_async) { |*args| enqueued << args } }

    expect(RubyReactor::Sweeper.new(storage: adapter, async_router: router).run_once).to eq(0)
    expect(enqueued).to be_empty
  end

  it "ages step results, maps and map rollbacks out of their scans" do
    adapter.store_step_result("ctx-1", "send", { "status" => "dispatched" }, "P")
    adapter.initialize_map_operation("p1:m", 2, "P", reactor_class_info: {})
    adapter.start_map_rollback("p1:m", "P", total: 2, batch_size: 1, step_name: "m", reactor_class_info: {})
    [models::StepResult, models::MapOperation, models::MapRollback].each { |model| age!(model) }

    expect(adapter.scan_step_results(count: 10)).to be_empty
    expect(adapter.scan_maps(count: 10)).to be_empty
    expect(adapter.scan_map_rollbacks(count: 10)).to be_empty
    expect(adapter.retrieve_step_result("ctx-1", "send", "P")).to eq("status" => "dispatched")
    expect(adapter.retrieve_map_metadata("p1:m", "P")).to include("map_id" => "p1:m")
  end
end
