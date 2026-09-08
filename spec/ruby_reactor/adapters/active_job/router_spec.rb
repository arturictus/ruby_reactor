# frozen_string_literal: true

require "spec_helper"
require "active_job"
require "ruby_reactor/adapters/active_job/router"

# End-to-end smoke test that a full reactor run can go through the
# ActiveJob backend top to bottom: enqueue via `Router.perform_async`,
# drain via the ActiveJob `:test` queue adapter, resume via `Worker#perform`.
# Mirrors the equivalent Sidekiq coverage in spec/async_retry_integration_spec.rb.
RSpec.describe RubyReactor::Adapters::ActiveJob::Router do
  around do |example|
    original = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    example.run
  ensure
    ActiveJob::Base.queue_adapter = original
  end

  before do
    allow(RubyReactor::Configuration.instance).to receive(:async_router).and_return(described_class)
    RubyReactor::Adapters::ActiveJob::Worker.queue_adapter.enqueued_jobs.clear
  end

  it "queues a job immediately and returns an DispatchResult" do
    reactor = TestAsyncReactor.new
    result = reactor.run(user_id: 123, email: "test@example.com")

    expect(result).to be_a(RubyReactor::DispatchResult)
    expect(result.async?).to be true
    expect(RubyReactor::Adapters::ActiveJob::Worker.queue_adapter.enqueued_jobs.size).to eq(1)
  end

  it "executes the full reactor once the enqueued job is performed" do
    reactor = TestAsyncReactor.new
    result = reactor.run(user_id: 123, email: "test@example.com")

    enqueued = RubyReactor::Adapters::ActiveJob::Worker.queue_adapter.enqueued_jobs.first
    RubyReactor::Adapters::ActiveJob::Worker.new(*enqueued[:args]).perform_now

    instance = TestAsyncReactor.find(result.execution_id)
    expect(instance.context.status.to_s).to eq("completed")
  end
end
