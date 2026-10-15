# frozen_string_literal: true

require "spec_helper"

# 011 F-1 and FR-024: without declarations every job lands on the global
# `queue_name` — read when the job is enqueued, on every job class — and
# carries exactly the arguments it did before queues existed.
RSpec.describe "job placement without declarations" do
  def pending
    RubyReactor::RSpec::AsyncTestHelpers.pending_async_jobs
  end

  def args_of(job)
    async_backend == :sidekiq ? job.args : ActiveJob::Arguments.deserialize(job.raw[:args])
  end

  before do
    stub_const("PlacementAsyncStep", Class.new(RubyReactor::Reactor) do
      async_step(:send) { run { |_inputs, _ctx| RubyReactor.Success(1) } }
    end)
    stub_const("PlacementFanOut", Class.new(RubyReactor::Reactor) do
      input :items
      map :each, QueueFixtures::UndeclaredDeposit do
        source input(:items)
        argument :i, element(:each)
        fan_out batch_size: 2
      end
    end)
  end

  def run_everything
    QueueFixtures::SoloUndeclared.run({})
    PlacementAsyncStep.run({})
    PlacementFanOut.run(items: [1, 2])
  end

  for_each_async_backend do
    around do |example|
      original = RubyReactor.configuration.queue_name
      example.run
    ensure
      RubyReactor.configuration.queue_name = original
    end

    it "puts every job class on a queue_name configured after the adapters loaded" do
      RubyReactor.configuration.queue_name = :critical
      run_everything

      classes = pending.map { |job| job.worker_class.name.split("::").last }
      expect(classes).to include("Worker", "StepWorker", "MapElementWorker", "MapCollectorWorker")
      expect(pending.map(&:queue)).to all(eq("critical"))
    end

    it "adds no queue to any job's arguments" do
      run_everything

      expect(pending).not_to be_empty
      pending.each do |job|
        args = args_of(job)
        expect(args.size).to eq(2) if job.worker_class.name.end_with?("::Worker")
        expect(args.first.keys).not_to include("queue", "owner_queue") if args.first.is_a?(Hash)
      end
    end
  end
end
