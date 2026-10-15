# frozen_string_literal: true

require "spec_helper"

# 011 R-03/R-04: a Worker job knows the queue it runs on (its 4th argument),
# stamps it on the trace, clears the run's wait when it picks the run up, and
# keeps its queue when it snoozes.
RSpec.describe "Worker queues" do
  include RubyReactor::RSpec::Helpers

  let(:storage) { RubyReactor.configuration.storage_adapter }

  def pending
    RubyReactor::RSpec::AsyncTestHelpers.pending_async_jobs
  end

  def args_of(job)
    async_backend == :sidekiq ? job.args : ActiveJob::Arguments.deserialize(job.raw[:args])
  end

  def worker
    async_backend == :sidekiq ? RubyReactor::Adapters::Sidekiq::Worker : RubyReactor::Adapters::ActiveJob::Worker
  end

  def perform(*args)
    async_backend == :sidekiq ? worker.new.perform(*args) : worker.new(*args).perform_now
  end

  def clear_jobs
    async_backend == :sidekiq ? Sidekiq::Worker.clear_all : ActiveJob::Base.queue_adapter.enqueued_jobs.clear
  end

  before do
    stub_const("WorkerQueueLocked", Class.new(RubyReactor::Reactor) do
      queue :locked_q
      with_lock { |_inputs| "wq:lock" }
      background all: true
      step(:a) { run { |_inputs, _ctx| RubyReactor.Success(1) } }
    end)
    stub_const("WorkerQueuePlainLocked", Class.new(RubyReactor::Reactor) do
      with_lock { |_inputs| "wq:plain-lock" }
      background all: true
      step(:a) { run { |_inputs, _ctx| RubyReactor.Success(1) } }
    end)
  end

  for_each_async_backend do
    it "stamps the job's queue on the trace, and the global one without a queue argument" do
      result = QueueFixtures::SoloMain.run({})
      clear_jobs
      perform(result.execution_id, "QueueFixtures::SoloMain", 0, "my_specific_queue")

      trace = QueueFixtures::SoloMain.find(result.execution_id).context.execution_trace
      runs = trace.select { |entry| entry[:type].to_s == "run" }
      expect(runs.to_h { |entry| [entry[:step].to_s, entry[:queue]] })
        .to eq("first" => nil, "second" => "my_specific_queue", "third" => "my_specific_queue")

      plain = QueueFixtures::SoloUndeclared.run({})
      clear_jobs
      perform(plain.execution_id, "QueueFixtures::SoloUndeclared")
      trace = QueueFixtures::SoloUndeclared.find(plain.execution_id).context.execution_trace
      expect(trace.select { |entry| entry[:type].to_s == "run" }.map { |entry| entry[:queue] })
        .to eq([nil, "default", "default"])
    end

    it "clears the run's wait when it picks the run up from the recorded queue" do
      result = QueueFixtures::SoloMain.run({})
      storage.store_run_dispatch(result.execution_id, "QueueFixtures::SoloMain", "my_specific_queue")
      clear_jobs

      perform(result.execution_id, "QueueFixtures::SoloMain", 0, "my_specific_queue")
      expect(storage.retrieve_run_dispatch(result.execution_id, "QueueFixtures::SoloMain")["since"]).to eq("")
    end

    it "snoozes on its own queue, carrying the snooze count, and records the wait" do
      result = WorkerQueueLocked.run({})
      clear_jobs

      hold_lock("wq:lock") { perform(result.execution_id, "WorkerQueueLocked", 0, "locked_q") }

      job = pending.first
      expect(pending.size).to eq(1)
      expect(job.queue).to eq("locked_q")
      expect(args_of(job)).to eq([result.execution_id, "WorkerQueueLocked", 1, "locked_q"])
      expect(storage.retrieve_run_dispatch(result.execution_id, "WorkerQueueLocked")["since"]).not_to be_empty
    end

    it "snoozes exactly as before without a queue argument" do
      result = WorkerQueuePlainLocked.run({})
      clear_jobs

      hold_lock("wq:plain-lock") { perform(result.execution_id, "WorkerQueuePlainLocked") }

      expect(pending.map(&:queue)).to eq(["default"])
      expect(args_of(pending.first)).to eq([result.execution_id, "WorkerQueuePlainLocked", 1])
      expect(storage.retrieve_run_dispatch(result.execution_id, "WorkerQueuePlainLocked")["queue"]).to eq("default")
    end

    it "keeps its queue when it snoozes before loading, on a busy run lock" do
      stub_const("RubyReactor::Worker::CONTEXT_LOCK_WAIT", 0.1)
      result = WorkerQueueLocked.run({})
      clear_jobs

      hold_lock("async:#{result.execution_id}") do
        perform(result.execution_id, "WorkerQueueLocked", 0, "locked_q")
      end

      expect(pending.map(&:queue)).to eq(["locked_q"])
      expect(args_of(pending.first)).to eq([result.execution_id, "WorkerQueueLocked", 1, "locked_q"])
    end
  end
end
