# frozen_string_literal: true

require "spec_helper"

# 010 US1 (FR-001–FR-004, R-01, J-1, J-3): a run executing in the caller's
# process holds its liveness lock, so the recovery sweep never re-runs it while
# its process is alive, and recovers it once the lock lapses.
RSpec.describe "Caller-process run liveness (010 US1)" do
  let(:storage) { RubyReactor.configuration.storage_adapter }
  let(:sweeper) { RubyReactor::Sweeper.new(async_router: router) }
  let(:enqueued) { [] }
  let(:router) do
    captured = enqueued
    Class.new { define_singleton_method(:perform_async) { |id, klass| captured << [id, klass] } }
  end

  def wait_until(timeout = 3)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until yield
      raise "condition not met within #{timeout}s" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.02
    end
  end

  def running_ids(klass_name)
    storage.scan_reactors(count: 1000).select { |r| r[:class] == klass_name && r[:status] == "running" }
           .map { |r| r[:id] }
  end

  # Start SlowSync in a thread and wait until it holds its lock mid-step.
  def start_slow_run
    ResumeFixtures.latch(:slow)
    reactor = ResumeFixtures::SlowSync.new
    thread = Thread.new { reactor.run({}) }
    wait_until { ResumeFixtures.counter(:slow) == 1 && reactor.context.is_a?(RubyReactor::Context) }
    id = reactor.context.context_id
    wait_until { storage.lock_held?("async:#{id}") }
    [reactor, thread, id]
  end

  it "is not re-enqueued by a sweep while its step runs" do
    reactor, thread, id = start_slow_run

    expect(sweeper.run_once).to eq(0)
    expect(enqueued).to be_empty

    ResumeFixtures.latch(:slow).open!
    thread.join(5)
    expect(ResumeFixtures.counter(:slow)).to eq(1)
    expect(reactor.context.status.to_s).to eq("completed")
    expect(storage.lock_held?("async:#{id}")).to be(false)
  end

  context "with a liveness timeout shorter than the step" do
    around do |example|
      original = RubyReactor.configuration.context_lock_ttl
      # 2s, not 1s: `Lock` extends at most once a second (MIN_EXTEND_INTERVAL).
      RubyReactor.configuration.context_lock_ttl = 2
      example.run
    ensure
      RubyReactor.configuration.context_lock_ttl = original
    end

    it "keeps renewing the lock, so no sweep re-enqueues it" do
      _reactor, thread, = start_slow_run

      8.times do # 4s: twice the liveness timeout
        expect(sweeper.run_once).to eq(0)
        sleep 0.5
      end

      ResumeFixtures.latch(:slow).open!
      thread.join(5)
      expect(enqueued).to be_empty
      expect(ResumeFixtures.counter(:slow)).to eq(1)
    end
  end

  it "is recovered by the sweep once its killed process stops renewing the lock", :fork do
    skip "fork is not available" unless Process.respond_to?(:fork)

    pid = fork do
      RubyReactor.configuration.context_lock_ttl = 2
      ResumeFixtures.latch(:slow) # never opened: the child blocks until killed
      ResumeFixtures::SlowSync.run({})
    end
    wait_until(5) { running_ids("ResumeFixtures::SlowSync").any? }
    id = running_ids("ResumeFixtures::SlowSync").first
    expect(sweeper.run_once).to eq(0) # alive: lock held

    Process.kill(:KILL, pid)
    Process.wait(pid)

    wait_until(4) { !storage.lock_held?("async:#{id}") }
    expect(sweeper.run_once).to eq(1)
    expect(enqueued).to eq([[id, "ResumeFixtures::SlowSync"]])
  end

  it "releases the lock when it hands off at a fan-out map, leaving the sweep as today" do
    result = ResumeFixtures::SyncFanOut.run(items: [1, 2, 3])

    expect(result).to be_a(RubyReactor::DispatchResult)
    expect(storage.lock_held?("async:#{result.execution_id}")).to be(false)
  end

  it "is stored aborted, with its lock released, after an interruption" do
    klass = Class.new(RollbackRecorder::Reactor) do
      def self.name = "LivenessSpecInterrupted"
      recording_step(:a) { run { |_inputs, _ctx| raise Interrupt } }
    end
    stub_const("LivenessSpecInterrupted", klass)
    reactor = klass.new

    expect { reactor.run({}) }.to raise_error(Interrupt)

    id = reactor.context.context_id
    expect(klass.find(id).context.status.to_s).to eq("aborted")
    expect(storage.lock_held?("async:#{id}")).to be(false)
    expect(sweeper.run_once).to eq(0)
  end

  it "saves its final state before it releases the lock" do
    order = []
    allow_any_instance_of(RubyReactor::Lock).to receive(:release).and_wrap_original do |m, *args|
      order << [:release, m.receiver.key]
      m.call(*args)
    end
    allow(storage).to receive(:store_context).and_wrap_original do |m, *args|
      order << [:store, args.first]
      m.call(*args)
    end

    reactor = ResumeFixtures::PlainApproval.new
    reactor.run({})

    id = reactor.context.context_id
    release = order.index([:release, "lock:async:#{id}"])
    expect(release).not_to be_nil
    expect(order.rindex([:store, id])).to be < release
  end

  # FR-001: a manual undo cannot interleave with the live run.
  it "makes a manual undo wait for, then give up on, the live run" do
    stub_const("RubyReactor::Reactor::UNDO_LOCK_WAIT", 0.2)
    _reactor, thread, id = start_slow_run

    expect { ResumeFixtures::SlowSync.undo(id) }.to raise_error(RubyReactor::Lock::AcquisitionError)

    ResumeFixtures.latch(:slow).open!
    thread.join(5)
    expect(ResumeFixtures::SlowSync.find(id).context.status.to_s).to eq("completed")
  end
end
