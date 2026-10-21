# frozen_string_literal: true

require "spec_helper"

# 011 R-04, data-model §3.1: where a run was last dispatched, and since when
# it has been waiting there.
RSpec.describe "run dispatch record" do
  let(:storage) { RubyReactor.configuration.storage_adapter }
  let(:id) { SecureRandom.uuid }

  it "stores the queue with the time the dispatch started, for the context's lifetime" do
    storage.store_run_dispatch(id, "K", "stripe")

    record = storage.retrieve_run_dispatch(id, "K")
    expect(record["queue"]).to eq("stripe")
    expect(Time.iso8601(record["since"])).to be_within(5).of(Time.now)

    redis = storage.instance_variable_get(:@redis)
    expect(redis.ttl("reactor:K:context:#{id}:dispatch")).to be_within(5).of(RubyReactor.configuration.context_ttl)
  end

  it "clears the wait only for a job on the recorded queue" do
    storage.store_run_dispatch(id, "K", "stripe")

    storage.clear_run_dispatch_wait(id, "K", "other")
    expect(storage.retrieve_run_dispatch(id, "K")["since"]).not_to be_empty

    storage.clear_run_dispatch_wait(id, "K", "stripe")
    expect(storage.retrieve_run_dispatch(id, "K")).to eq("queue" => "stripe", "since" => "")
  end

  it "returns nil when the run has no record" do
    expect(storage.retrieve_run_dispatch(id, "K")).to be_nil
  end

  it "stays out of the reactor listings" do
    reactor = Class.new(RubyReactor::Reactor) do
      define_singleton_method(:name) { "DispatchRecordReactor" }
      step(:a) { run { |_inputs, _ctx| RubyReactor.Success(1) } }
    end
    stub_const("DispatchRecordReactor", reactor)
    result = DispatchRecordReactor.run({})
    storage.store_run_dispatch(result.execution_id, "DispatchRecordReactor", "stripe")

    ids = storage.scan_reactors(count: 100).map { |r| r[:id] }
    expect(ids).to eq([result.execution_id])
    page = storage.scan_reactors_page(count: 100)[:reactors].map { |r| r[:id] }
    expect(page).to eq([result.execution_id])
  end
end
