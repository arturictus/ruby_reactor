# frozen_string_literal: true

require "rails_helper"

# 011 US3: the demo picks its storage and queue backend from the environment,
# and the active_record + active_job combination never touches Redis (FR-006).
RSpec.describe "Demo storage selection", type: :reactor do
  let(:storage) { ENV.fetch("RUBY_REACTOR_STORAGE", "redis") }
  let(:queue) { ENV.fetch("RUBY_REACTOR_QUEUE", "sidekiq") }

  it "uses the storage adapter RUBY_REACTOR_STORAGE names" do
    expected = storage == "active_record" ? "RubyReactor::Storage::ActiveRecordAdapter" : "RubyReactor::Storage::RedisAdapter"

    # By name: the ActiveRecord adapter class only exists once it is selected.
    expect(RubyReactor.configuration.storage_adapter.class.name).to eq(expected)
  end

  it "routes background work through the queue RUBY_REACTOR_QUEUE names" do
    expected = queue == "active_job" ? RubyReactor::Adapters::ActiveJob::Router : RubyReactor::Adapters::Sidekiq::Router

    expect(RubyReactor.configuration.async_router).to eq(expected)
  end

  it "runs a background reactor end to end without opening a Redis connection", :active_record_only do
    skip "needs RUBY_REACTOR_QUEUE=active_job" unless queue == "active_job"
    allow(Redis).to receive(:new).and_raise("a Redis-free run must not connect to Redis")

    expect(test_reactor(StepLockDemoReactor, { account_id: "acct_redis_free" })).to be_success
  end
end
