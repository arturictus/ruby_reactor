# frozen_string_literal: true

require "spec_helper"

# 011 US1: a reactor declaring `queue` runs all of its background work there —
# the hand-off, retries, sweeper recovery, a background resume — and an
# undeclared reactor runs exactly as before.
RSpec.describe "a reactor on its own queue (US1)" do
  def pending
    RubyReactor::RSpec::AsyncTestHelpers.pending_async_jobs
  end

  def drain
    RubyReactor::RSpec::AsyncTestHelpers.drain_async_jobs
  end

  def args_of(job)
    async_backend == :sidekiq ? job.args : ActiveJob::Arguments.deserialize(job.raw[:args])
  end

  def clear_jobs
    async_backend == :sidekiq ? Sidekiq::Worker.clear_all : ActiveJob::Base.queue_adapter.enqueued_jobs.clear
  end

  # Performs pending jobs one at a time; returns how many ran.
  def perform_all(limit: 50)
    count = 0
    while (job = QueueProbe.next_job)
      job.perform!
      count += 1
      raise "too many jobs" if count > limit
    end
    count
  end

  def run_queues(reactor_class, id)
    reactor_class.find(id).context.execution_trace
                 .select { |entry| entry[:type].to_s == "run" }
                 .to_h { |entry| [entry[:step].to_s, entry[:queue]] }
  end

  for_each_async_backend do
    it "hands off to the declared queue, and runs every later step there (AS1)" do
      result = QueueFixtures::SoloMain.run({})

      expect(QueueFixtures.run_log).to eq(["run:solo.first"])
      expect(QueueFixtures.queues_of_pending).to eq(["my_specific_queue"])

      drain
      expect(QueueFixtures::SoloMain.find(result.execution_id).context.status.to_s).to eq("completed")
      expect(run_queues(QueueFixtures::SoloMain, result.execution_id))
        .to eq("first" => nil, "second" => "my_specific_queue", "third" => "my_specific_queue")
    end

    it "requeues a retry with backoff on the declared queue (AS2)" do
      result = QueueFixtures::SoloRetry.run({})

      QueueProbe.next_job.perform!
      expect(QueueFixtures.queues_of_pending).to eq(["my_specific_queue"])

      perform_all
      expect(QueueFixtures::SoloRetry.find(result.execution_id).context.status.to_s).to eq("completed")
      expect(QueueFixtures.count("run:solo.second")).to eq(2)
    end

    it "recovers a lost job onto the declared queue (AS3)" do
      result = QueueFixtures::SoloMain.run({})
      clear_jobs

      expect(RubyReactor::Sweeper.run_once).to eq(1)
      expect(QueueFixtures.queues_of_pending).to eq(["my_specific_queue"])

      drain
      expect(QueueFixtures::SoloMain.find(result.execution_id).context.status.to_s).to eq("completed")
    end

    it "runs a whole `background all: true` run in one job on the declared queue (AS4)" do
      result = QueueFixtures::SoloAll.run(x: 1)

      expect(QueueFixtures.queues_of_pending).to eq(["my_specific_queue"])
      drain
      expect(run_queues(QueueFixtures::SoloAll, result.execution_id)).to eq("a" => "my_specific_queue")
    end

    it "keeps an undeclared reactor's jobs, arguments and count as they were (AS5, FR-024)" do
      result = QueueFixtures::SoloUndeclared.run({})

      expect(pending.map(&:queue)).to eq(["default"])
      expect(args_of(pending.first)).to eq([result.execution_id, "QueueFixtures::SoloUndeclared"])
      expect(perform_all).to eq(1)
      expect(QueueFixtures::SoloUndeclared.find(result.execution_id).context.status.to_s).to eq("completed")
    end

    it "never moves work out of the calling process because of a queue (AS6, FR-006)" do
      result = QueueFixtures::SoloNoBackground.run({})

      expect(result).to be_success
      expect(pending).to be_empty
      trace = QueueFixtures::SoloNoBackground.find(result.execution_id).context.execution_trace
      expect(trace.none? { |entry| entry.key?(:queue) }).to be(true)
    end

    it "resumes a background interrupt on the declared queue" do
      result = QueueFixtures::SoloApproval.run({})
      expect(pending).to be_empty

      QueueFixtures::SoloApproval.continue(id: result.execution_id, payload: { ok: true }, step_name: :approve)
      expect(QueueFixtures.queues_of_pending).to eq(["my_specific_queue"])

      drain
      expect(run_queues(QueueFixtures::SoloApproval, result.execution_id)["after"]).to eq("my_specific_queue")
    end
  end
end
