# frozen_string_literal: true

require "spec_helper"

# 011 US2, P-1/P-2: a run in a worker moves to a composed child's queue for the
# child's work and back afterwards — one extra job per queue change — keeping
# its holds across every hop (H-3).
RSpec.describe "queue hops through compose (US2)", type: :reactor do
  # Performs pending jobs one at a time, oldest first; returns how many ran.
  def perform_all(limit: 50)
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

  for_each_async_backend do
    it "runs the child on its own queue and hops back, in one job per queue change (AS1, SC-003)" do
      subject = started(QueueFixtures::Main)

      expect(QueueFixtures.queues_of_pending).to eq(["main"])
      expect(perform_all).to eq(3)

      expect(subject).to be_success
      expect(subject).to have_run_step(:second).on_queue(:main)
      expect(subject).to have_run_step(:third).on_queue(:main)
      expect(subject.composed(:bank_deposit)).to have_run_step(:one).on_queue(:stripe)
      expect(subject.composed(:bank_deposit)).to have_run_step(:two).on_queue(:stripe)
      expect(subject).to have_hopped_queues(:stripe, :main)
      expect(QueueFixtures.run_log).to eq(%w[run:m.first run:m.second run:s.one run:s.two run:m.third])
    end

    it "keeps an undeclared child on its parent's queue, in one job (AS2, AS3)" do
      subject = started(QueueFixtures::MainUndeclaredChild)

      expect(perform_all).to eq(1)
      expect(subject).to be_success
      expect(subject.composed(:bank_deposit)).to have_run_step(:u1).on_queue(:main)
      expect(subject).to have_hopped_queues
    end

    it "hops for a step inside the child that declares another queue, without hopping the compose (P-2)" do
      subject = started(QueueFixtures::MainNested)

      perform_all
      expect(subject).to be_success
      expect(subject).to have_hopped_queues(:stripe, :ledger, :stripe, :main)
      expect(subject.composed(:bank_deposit)).to have_run_step(:two).on_queue(:ledger)
      expect(subject.composed(:bank_deposit)).to have_run_step(:three).on_queue(:stripe)
      expect(QueueFixtures.count("run:ledger")).to eq(1)
    end

    it "hops into each deeper queue and back out of each, in order (three-level compose)" do
      stub_const("HopLeaf", Class.new(RollbackRecorder::Reactor) do
        tag "leaf"
        queue :leaf
        input :prev, optional: true
        recording_step :l1
      end)
      stub_const("HopMiddle", Class.new(RollbackRecorder::Reactor) do
        tag "mid"
        queue :mid
        input :prev, optional: true
        recording_step :m1
        compose(:leaf, HopLeaf) { argument :prev, result(:m1) }
        recording_step :m2, after: :leaf
      end)
      stub_const("HopRoot", Class.new(RollbackRecorder::Reactor) do
        tag "root"
        queue :main
        background all: true
        recording_step :r1
        compose(:middle, HopMiddle) { argument :prev, result(:r1) }
        recording_step :r2, after: :middle
      end)
      subject = started(HopRoot)

      perform_all
      expect(subject).to be_success
      expect(subject).to have_hopped_queues(:mid, :leaf, :mid, :main)
    end

    it "keeps the reactor's lock held by the run while it waits in another queue (H-3)" do
      RubyReactor.configuration.context_lock_ttl = 2
      subject = started(QueueFixtures::MainLocked)
      QueueProbe.next_job.perform!

      expect(QueueFixtures.queues_of_pending).to eq(["stripe"])
      sleep 3 # past the lock's normal ttl: only the hop's lease keeps it
      expect("qfx:lock").to be_locked

      perform_all
      expect(subject).to be_success
      expect("qfx:lock").not_to be_locked
    ensure
      RubyReactor.configuration.context_lock_ttl = 60
    end

    it "keeps the reactor's semaphore slot across a hop (H-3)" do
      subject = started(QueueFixtures::MainSemaphore)
      QueueProbe.next_job.perform!

      expect(QueueFixtures.queues_of_pending).to eq(["stripe"])
      semaphore = "qfx:sem"
      expect(semaphore).to have_held_tokens(1)

      perform_all
      expect(subject).to be_success
      expect(semaphore).to have_available_tokens(1)
    end

    it "never reports a hop as a failure, and starts the hopping step only where it runs" do
      events = []
      recorder = Class.new do
        define_method(:on) { |event, *args| events << [event, args.first] }
      end
      stub_const("HopEventRecorder", recorder)
      RubyReactor.configuration.middlewares << HopEventRecorder
      subject = started(QueueFixtures::Main)
      perform_all

      expect(subject).to be_success
      expect(events.map(&:first)).not_to include(:failed_step, :failed_reactor)
      expect(events.count { |event, name| event == :start_step && name == :bank_deposit }).to eq(1)
      expect(events.count { |event, _| event == :before_async_enqueue }).to eq(3)
    ensure
      RubyReactor.configuration.middlewares.delete(HopEventRecorder)
    end
  end
end
