# frozen_string_literal: true

require "spec_helper"

# 011 US2-AS7, FR-015: a fan-out map's element jobs — forward, retries,
# rollback, recovery — run on the element reactor's queue; the collector and
# the owner's resume run on the owner's. An inline map hops in and out whole.
RSpec.describe "map queues (US2)", type: :reactor do
  def perform_all(limit: 100)
    count = 0
    while (job = QueueProbe.next_job)
      job.perform!
      count += 1
      raise "more than #{limit} jobs" if count > limit
    end
    count
  end

  def started(reactor_class, inputs = {})
    test_reactor(reactor_class, inputs, process_jobs: false).tap(&:run)
  end

  def jobs_of(worker_name)
    pending_async_jobs.select { |job| job.worker_class.name.end_with?("::#{worker_name}") }
  end

  def delete_job(job)
    if async_backend == :sidekiq
      job.worker_class.jobs.delete(job.raw)
    else
      ActiveJob::Base.queue_adapter.enqueued_jobs.delete(job.raw)
    end
  end

  # Performs every job; returns `[worker class short name, queue]` for each.
  def perform_observing(limit: 100)
    seen = []
    limit.times do
      job = QueueProbe.next_job or break
      seen << [job.worker_class.name.split("::").last, job.queue]
      job.perform!
    end
    seen
  end

  def queues_by_class(seen)
    seen.group_by(&:first).transform_values { |pairs| pairs.map(&:last).uniq }
  end

  # Performs jobs until none of `worker_name` is pending, then returns.
  def perform_until_none(worker_name, limit: 100)
    limit.times do
      break if jobs_of(worker_name).empty?

      QueueProbe.next_job.perform!
    end
  end

  before do
    stub_const("RetryingDeposit", Class.new(RollbackRecorder::Reactor) do
      tag "d"
      queue :deposits
      input :i
      recording_step :d, idx: true, fail: 1 do
        retries max_attempts: 2, backoff: :fixed, base_delay: 0
      end
    end)
    QueueFixtures.build_map_owner(:RetryingOwner, RetryingDeposit) unless defined?(QueueFixtures::RetryingOwner)
  end

  for_each_async_backend do
    it "runs element jobs on the element's queue, the collector and the owner's resume on the owner's (AS7)" do
      subject = started(QueueFixtures::FanOutOwner, items: [1, 2, 3])
      expect(QueueFixtures.queues_of_pending).to eq(["main"])

      QueueProbe.next_job.perform!
      expect(jobs_of("MapElementWorker").map(&:queue)).to all(eq("deposits"))
      expect(jobs_of("MapElementWorker")).not_to be_empty
      expect(jobs_of("MapCollectorWorker").map(&:queue)).to eq(["main"])

      perform_until_none("MapElementWorker")
      perform_until_none("MapCollectorWorker")
      expect(jobs_of("Worker").map(&:queue)).to eq(["main"])

      perform_all
      expect(subject).to be_success
      expect(subject).to have_run_step(:after_map).on_queue(:main)
    end

    it "requeues an element's retry on the element's queue" do
      subject = started(QueueFixtures::RetryingOwner, items: [1, 2])
      seen = perform_observing

      expect(subject).to be_success
      expect(QueueFixtures.count("run:d.d[1]")).to eq(2)
      expect(seen.count { |klass, _| klass == "MapElementWorker" }).to eq(4)
      expect(queues_by_class(seen)["MapElementWorker"]).to eq(["deposits"])
    end

    it "rolls each element back on the element's queue, and resumes the owner on its own" do
      subject = started(QueueFixtures::FanOutOwnerFailing, items: [1, 2, 3])
      seen = perform_observing

      expect(subject).to be_failure
      expect(QueueFixtures.run_log.grep(/\Aundo:d/).size).to eq(3)
      expect(queues_by_class(seen)).to eq(
        "Worker" => ["main"], "MapElementWorker" => ["deposits"], "MapCollectorWorker" => ["main"],
        "MapElementRollbackWorker" => ["deposits"]
      )
    end

    it "recovers lost element and collector jobs onto their queues" do
      started(QueueFixtures::FanOutOwner, items: [1, 2])
      QueueProbe.next_job.perform!

      # Every index without a result and without a live element looks lost
      # (a job still queued included): each is re-dispatched, to its queue.
      delete_job(jobs_of("MapElementWorker").first)
      expect(RubyReactor::Map::Sweeper.run_once[:redispatched]).to be >= 1
      expect(jobs_of("MapElementWorker").map(&:queue)).to all(eq("deposits"))

      jobs_of("MapElementWorker").first.perform! until jobs_of("MapElementWorker").empty?
      jobs_of("MapCollectorWorker").each { |job| delete_job(job) }
      expect(RubyReactor::Map::Sweeper.run_once[:recollected]).to eq(1)
      expect(jobs_of("MapCollectorWorker").map(&:queue)).to eq(["main"])
    end

    it "hops an inline map into its element's queue and back" do
      subject = started(QueueFixtures::InlineMapOwner, items: [1, 2])
      perform_all

      expect(subject).to be_success
      expect(subject).to have_hopped_queues(:deposits, :main)
      expect(subject).to have_run_step(:after_map).on_queue(:main)
    end

    it "keeps an undeclared element reactor on the owner's queue, with no hop" do
      subject = started(QueueFixtures::FanOutUndeclaredOwner, items: [1, 2])
      QueueProbe.next_job.perform!
      expect(jobs_of("MapElementWorker").map(&:queue)).to all(eq("main"))

      perform_all
      expect(subject).to be_success
      expect(subject).to have_hopped_queues
    end
  end
end
