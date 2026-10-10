# frozen_string_literal: true

require "spec_helper"

# 010 US5 (FR-017–FR-021, P-4): a resume for another ready interrupt that
# arrives while the run is executing is accepted and applied once, through a
# Worker that takes the run once it is free.
RSpec.describe "Resuming several pending interrupts at once (010 US5)" do
  let(:storage) { RubyReactor.configuration.storage_adapter }
  let(:logger) { RubyReactor.configuration.logger }
  let(:klass) { ResumeFixtures::DualApproval }

  before { allow(logger).to receive(:info).and_call_original }

  def pause(reactor_class, inputs = {})
    reactor = reactor_class.new
    expect(reactor.run(inputs)).to be_a(RubyReactor::InterruptResult)
    reactor.context.context_id
  end

  def wait_until(timeout = 3)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until yield
      raise "condition not met within #{timeout}s" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.02
    end
  end

  def drain
    RubyReactor::RSpec::AsyncTestHelpers.drain_async_jobs
  end

  # Resume :a in a thread; `after_a` then blocks on its latch, holding the run.
  def resume_a_and_block(id, payload = { a: 1 })
    latch = ResumeFixtures.latch(:after_a)
    thread = Thread.new { klass.continue(id: id, payload: payload, step_name: :a) }
    wait_until { latch.waiting? && storage.lock_held?("async:#{id}") }
    [thread, latch]
  end

  it "accepts :b while :a's resume executes, and applies it once the run is free" do
    id = pause(klass)
    thread, latch = resume_a_and_block(id)

    result = klass.continue(id: id, payload: { ok: true }, step_name: :b)

    expect(result).to be_a(RubyReactor::DispatchResult)
    expect(logger).to have_received(:info).with(/event="ruby_reactor.resume.deferred".*step="b".*reason="run_busy"/)
    latch.open!
    expect(thread.value).to be_a(RubyReactor::InterruptResult) # paused at :b, briefly

    drain
    context = klass.find(id).context
    expect(context.status.to_s).to eq("completed")
    expect(context.get_result(:a)).to eq(a: 1)
    expect(context.get_result(:b)).to eq(ok: true)
    expect(RollbackRecorder.log.count("run:after_a")).to eq(1)
    expect(RollbackRecorder.log.count("run:done")).to eq(1)
  end

  (2..5).each do |count|
    it "accepts all #{count} ready interrupts resumed at the same instant" do
      many = ResumeFixtures.many_approvals(count)
      id = pause(many)
      barrier = ResumeFixtures.barrier(count)

      threads = (0...count).map do |k|
        Thread.new do
          barrier.wait
          many.continue(id: id, payload: { n: k }, step_name: :"i#{k}")
        end
      end
      threads.each(&:value) # none raised

      drain
      context = many.find(id).context
      expect(context.status.to_s).to eq("completed")
      (0...count).each { |k| expect(context.get_result(:"i#{k}")).to eq(n: k) }
      expect(RollbackRecorder.log.count("run:done")).to eq(1)
    end
  end

  it "answers an invalid :b with its validation failure, claiming and writing nothing" do
    id = pause(klass)
    thread, latch = resume_a_and_block(id)

    failure = klass.find(id).continue(payload: { ok: "nope" }, step_name: :b)

    expect(failure).to be_failure
    expect(failure.invalid_payload?).to be(true)
    expect(storage.retrieve_interrupt_resumes(id, klass.name, ["b"])).to eq({})
    latch.open!
    thread.join(5)

    context = klass.find(id).context
    expect(context.status.to_s).to eq("paused")
    expect(context.get_result(:after_a)).to eq(a: 1)
    expect(redis.get("reactor:#{klass.name}:context:#{id}:resume_attempts:b")).to eq("1")
    expect(context.private_data).not_to have_key(:interrupt_attempts)
  end

  # API §1: running out of attempts fails the run under its lock (R-08, R-09);
  # while another resume holds the run, that wait gives up and nothing fails.
  it "raises, failing nothing, when :b runs out of attempts while :a's resume holds the run" do
    stub_const("RubyReactor::Reactor::UNDO_LOCK_WAIT", 0.2)
    id = pause(klass)
    thread, latch = resume_a_and_block(id)

    2.times { klass.find(id).continue(payload: { ok: "nope" }, step_name: :b) }
    expect { klass.find(id).continue(payload: { ok: "nope" }, step_name: :b) }
      .to raise_error(RubyReactor::Lock::AcquisitionError)

    latch.open!
    thread.join(5)
    expect(klass.find(id).context.status.to_s).to eq("paused")
  end

  it "never applies an accepted :b when :a's resume fails first" do
    id = pause(klass, { fail_after_a: true })
    thread, latch = resume_a_and_block(id)
    expect(klass.continue(id: id, payload: { ok: true }, step_name: :b)).to be_a(RubyReactor::DispatchResult)

    latch.open!
    expect(thread.value).to be_failure
    expect_any_instance_of(RubyReactor::Executor).not_to receive(:resume_execution)
    drain

    context = klass.find(id).context
    expect(context.status.to_s).to eq("failed")
    expect(context.has_result?(:b)).to be(false)
  end

  it "accepts a resume that arrives before a background run has even started" do
    async_klass = ResumeFixtures::DualApprovalAsync
    id = async_klass.run({}).execution_id

    result = async_klass.continue(id: id, payload: { early: true }, step_name: :b)

    expect(result).to be_a(RubyReactor::DispatchResult)
    drain
    context = async_klass.find(id).context
    expect(context.status.to_s).to eq("paused")
    expect(context.current_step.to_s).to eq("a")
    expect(context.get_result(:b)).to eq(early: true)
  end
end
