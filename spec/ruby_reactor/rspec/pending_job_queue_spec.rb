# frozen_string_literal: true

require "spec_helper"

RSpec.describe "PendingJob#queue" do
  for_each_async_backend do
    let(:worker) do
      async_backend == :sidekiq ? RubyReactor::Adapters::Sidekiq::Worker : RubyReactor::Adapters::ActiveJob::Worker
    end

    it "names the queue each pending job is on" do
      RubyReactor.configuration.async_router.perform_async("ctx-1", "SomeReactor")
      if async_backend == :sidekiq
        worker.set(queue: "x").perform_async("ctx-2", "SomeReactor")
      else
        worker.set(queue: "x").perform_later("ctx-2", "SomeReactor")
      end

      queues = RubyReactor::RSpec::AsyncTestHelpers.pending_async_jobs.map(&:queue)
      expect(queues).to contain_exactly(RubyReactor.configuration.queue_name.to_s, "x")
    end
  end
end
