# frozen_string_literal: true

require "spec_helper"

# 011 SC-004, FR-013, FR-017, hop-protocol §3: a crash at any hop boundary —
# forward or during rollback — and duplicate deliveries still end with the run
# completed once, or rolled back fully, each step and undo run exactly once.
# Crashes are simulated at the router boundary and by losing or replaying jobs.
RSpec.describe "queue hop crash windows (US2)", type: :reactor do
  let(:storage) { RubyReactor.configuration.storage_adapter }

  def perform_all(limit: 50)
    count = 0
    while (job = QueueProbe.next_job)
      job.perform!
      count += 1
      raise "more than #{limit} jobs" if count > limit
    end
    count
  end

  def started(reactor_class)
    test_reactor(reactor_class, {}, process_jobs: false).tap(&:run)
  end

  def run_id(subject)
    subject.reactor_instance.context.context_id
  end

  def delete_job(job)
    if async_backend == :sidekiq
      job.worker_class.jobs.delete(job.raw)
    else
      ActiveJob::Base.queue_adapter.enqueued_jobs.delete(job.raw)
    end
  end

  # A redelivery of `job`: equal arguments, a distinct entry (performing one
  # must not remove the other).
  def duplicate(job)
    if async_backend == :sidekiq
      job.worker_class.jobs << job.raw.merge("jid" => SecureRandom.hex(12))
    else
      ActiveJob::Base.queue_adapter.enqueued_jobs << job.raw.merge(redelivery: true)
    end
  end

  # The job crashes on the enqueue. Sidekiq surfaces the error (its server
  # would retry the job); ActiveJob's `retry_on` re-enqueues it at once.
  def perform_crashing(job)
    job.perform!
  rescue Redis::CannotConnectError
    nil
  end

  def runs_once?
    events = QueueFixtures.run_log.grep(/\Arun:/)
    events == events.uniq
  end

  # A router that raises once when asked for `queue`, then delegates.
  def flaky_router(queue)
    real = RubyReactor.configuration.async_router
    failed = false
    Class.new(SimpleDelegator) do
      define_method(:perform_async) do |*args, **options|
        if options[:queue] == queue && !failed
          failed = true
          raise Redis::CannotConnectError, "backend down"
        end
        __getobj__.perform_async(*args, **options)
      end
    end.new(real)
  end

  for_each_async_backend do
    describe "forward" do
      it "recovers a hop lost after the save, before its dispatch was recorded (W1)" do
        subject = started(QueueFixtures::Main)
        QueueProbe.next_job.perform! # main: :second, then the hop to stripe
        delete_job(QueueFixtures.jobs_on(:stripe).first)
        storage.store_run_dispatch(run_id(subject), "QueueFixtures::Main", "main")

        expect(RubyReactor::Sweeper.run_once).to eq(1)
        expect(QueueFixtures.queues_of_pending).to eq(["main"])

        perform_all
        expect(subject).to be_success
        expect(runs_once?).to be(true)
        expect(QueueFixtures.run_log.grep(/\Arun:/).size).to eq(5)
      end

      it "recovers a hop whose enqueue failed after its dispatch was recorded (W2)" do
        allow(RubyReactor.configuration).to receive(:async_router).and_return(flaky_router("stripe"))
        subject = started(QueueFixtures::Main)

        perform_crashing(QueueProbe.next_job)
        expect(storage.retrieve_run_dispatch(run_id(subject), "QueueFixtures::Main")["queue"]).to eq("stripe")
        perform_all # an ActiveJob retry of the crashed job finds the stripe dispatch pending, and stops
        expect(QueueFixtures.count("run:s.one")).to eq(0)

        expect(RubyReactor::Sweeper.run_once).to eq(1)
        expect(QueueFixtures.queues_of_pending).to eq(["stripe"])
        perform_all
        expect(subject).to be_success
        expect(runs_once?).to be(true)
      end

      it "stops a replayed predecessor without enqueueing or running anything (W3)" do
        subject = started(QueueFixtures::Main)
        duplicate(QueueProbe.next_job)

        QueueProbe.next_job.perform!
        expect(QueueFixtures.queues_of_pending.sort).to eq(%w[main stripe])
        QueueFixtures.jobs_on(:main).first.perform!
        expect(QueueFixtures.queues_of_pending).to eq(["stripe"])

        perform_all
        expect(subject).to be_success
        expect(subject).to have_hopped_queues(:stripe, :main)
        expect(runs_once?).to be(true)
      end

      it "lets only one copy of a duplicated hop job advance the run (AS5)" do
        subject = started(QueueFixtures::Main)
        QueueProbe.next_job.perform!
        duplicate(QueueFixtures.jobs_on(:stripe).first)

        perform_all
        expect(subject).to be_success
        expect(subject).to have_hopped_queues(:stripe, :main)
        expect(QueueFixtures.count("run:s.one")).to eq(1)
        expect(runs_once?).to be(true)
      end

      it "enqueues every hop while the job still holds the run's lock (H-2)" do
        held = []
        allow(RubyReactor::Queues).to receive(:enqueue_run).and_wrap_original do |original, id, *args, **options|
          held << storage.lock_held?("async:#{id}")
          original.call(id, *args, **options)
        end
        subject = started(QueueFixtures::Main)
        perform_all

        expect(subject).to be_success
        expect(held.size).to eq(3)
        expect(held).to all(be(true))
      end
    end

    describe "rollback" do
      def drive_to_rollback_hop
        started(QueueFixtures::MainFailing).tap do
          QueueProbe.next_job.perform! # main: :second, hop to stripe
          QueueProbe.next_job.perform! # stripe: the child, hop to main
        end
      end

      def undos
        QueueFixtures.run_log.grep(/\Aundo:/)
      end

      it "recovers a rollback hop lost before its dispatch was recorded (W1)" do
        subject = drive_to_rollback_hop
        QueueProbe.next_job.perform! # main: :third fails, rollback hops to stripe
        delete_job(QueueFixtures.jobs_on(:stripe).first)
        storage.store_run_dispatch(run_id(subject), "QueueFixtures::MainFailing", "main")

        expect(RubyReactor::Sweeper.run_once).to eq(1)
        perform_all

        expect(subject).to be_failure
        expect(undos).to eq(%w[undo:s.two undo:s.one undo:m.second undo:m.first])
      end

      it "recovers a rollback hop whose enqueue failed (W2)" do
        subject = drive_to_rollback_hop
        allow(RubyReactor.configuration).to receive(:async_router).and_return(flaky_router("stripe"))

        perform_crashing(QueueProbe.next_job)
        expect(QueueFixtures::MainFailing.find(run_id(subject)).context.status.to_s).to eq("rolling_back")
        perform_all # an ActiveJob retry finds the stripe dispatch pending, and stops

        expect(RubyReactor::Sweeper.run_once).to eq(1)
        perform_all
        expect(subject).to be_failure
        expect(undos).to eq(%w[undo:s.two undo:s.one undo:m.second undo:m.first])
        expect(QueueFixtures.count("compensate:m.third")).to eq(1)
      end

      it "stops a replayed job of a rolling-back run without a second hop (W3)" do
        subject = drive_to_rollback_hop
        duplicate(QueueProbe.next_job)

        QueueFixtures.jobs_on(:main).first.perform!
        QueueFixtures.jobs_on(:main).first.perform!
        expect(QueueFixtures.queues_of_pending).to eq(["stripe"])

        perform_all
        expect(subject).to be_failure
        expect(subject).to have_hopped_queues(:stripe, :main).during_rollback
        expect(undos).to eq(%w[undo:s.two undo:s.one undo:m.second undo:m.first])
      end
    end
  end
end
