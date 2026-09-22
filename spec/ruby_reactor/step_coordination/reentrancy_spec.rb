# frozen_string_literal: true

require "spec_helper"

# US4: step holds follow the nested-reactor rules already established for
# reactor-level locks — owned by the root context, nested holds counted, one
# shared registry, and a hand-off that would deadlock refused before dispatch.
RSpec.describe "step-scoped coordination re-entrancy", :step_coordination do
  def unique_account_id
    SecureRandom.random_number(10**9)
  end

  def capture_middleware
    events = []
    mw = Class.new do
      define_method(:on) { |event, *args| events << [event, args] }
    end.new
    [mw, events]
  end

  around do |example|
    original = RubyReactor.configuration.middlewares
    example.run
    RubyReactor.configuration.middlewares = original
  end

  it "completes with no wait: reactor lock, then step lock, on the same key (US4-1)" do
    account_id = unique_account_id
    result = ReentrancyChainReactor.run(run_id: step_coord_run_id, account_id: account_id)

    expect(result).to be_a(RubyReactor::Success)
  end

  it "runs two steps locking the same key in order and completes (US4-4)" do
    # Same fixture/run as above: :charge then :charge2 both lock "acct:X".
    account_id = unique_account_id
    result = ReentrancyChainReactor.run(run_id: step_coord_run_id, account_id: account_id)

    expect(result).to be_a(RubyReactor::Success)
    expect(overlap_recorder.entries(:charge)).not_to be_empty
  end

  it "keeps the key locked, with a single registry entry, after the step releases but while the " \
     "reactor still holds it (US4-3, FR-020, Finding 1)" do
    account_id = unique_account_id
    result = ReentrancyChainReactor.run(run_id: step_coord_run_id, account_id: account_id)

    expect(result).to be_a(RubyReactor::Success)
    expect(result.value[:locked]).to be(true)
    expect(result.value[:held_count]).to eq(1)
  end

  it "completes when a locked step's body drives a child reactor execution directly, compose-style " \
     "(US4-2, SC-006)" do
    account_id = unique_account_id
    result = ComposeStyleReactor.run(run_id: step_coord_run_id, account_id: account_id)

    expect(result).to be_a(RubyReactor::Success)
    expect(result.value).to eq("RubyReactor::Success")
  end

  describe "async_step dispatch refusal (FR-022)" do
    it "refuses at dispatch when the reactor holds a key the async_step's class also declares, " \
       "and enqueues no job" do
      account_id = unique_account_id
      RubyReactor::Adapters::Sidekiq::StepWorker.jobs.clear

      result = AsyncStepDeadlockReactor.run(account_id: account_id)

      expect(result).to be_a(RubyReactor::Failure)
      expect(result.message).to include("acct:#{account_id}")
      expect(result.message).to include("would deadlock")
      expect(RubyReactor::Adapters::Sidekiq::StepWorker.jobs).to be_empty
    end
  end

  describe "a live-Sidekiq async_step whose step class locks K (US4-5, SC-005)" do
    include_context "with a real async worker", :sidekiq

    it "the owner during the body is NOT the root context id, and two dispatches never overlap" do
      run_id = step_coord_run_id
      account_id = unique_account_id

      d1 = AsyncStepLockedReactor.run(run_id: run_id, account_id: account_id)
      d2 = AsyncStepLockedReactor.run(run_id: run_id, account_id: account_id)

      # Poll the lock while at least one dispatch should be inside its body.
      # Generous deadline: the live worker's own `lock_snooze_base_delay`/
      # `lock_snooze_jitter` are this PROCESS's config, not the worker's (a
      # genuinely separate OS process) — the loser can snooze up to the
      # worker's default ~5-10s before its next attempt even starts.
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 8
      owner = nil
      while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
        info = RubyReactor.configuration.storage_adapter.lock_info("lock:acct:#{account_id}")
        if info
          owner = info[:owner]
          break
        end
        sleep 0.05
      end

      expect(owner).not_to be_nil
      expect(owner).not_to eq(d1.execution_id)
      expect(owner).not_to eq(d2.execution_id)

      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 25
      loop do
        lock_free = RubyReactor.configuration.storage_adapter.lock_info("lock:acct:#{account_id}").nil?
        both_ran = overlap_recorder.entries(:async_step_charge).size >= 4
        break if lock_free && both_ran
        raise "async_step dispatches never both completed" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

        sleep 0.1
      end

      expect(overlap_recorder.max_concurrency(:async_step_charge)).to eq(1)
    end
  end

  it "fails after waiting when a direct class-step call contends on an externally-held key (FR-023)" do
    account_id = unique_account_id
    key = "acct:#{account_id}"
    holder = RubyReactor::Lock.new(key, owner: "external-holder", ttl: 5, wait: 0, auto_extend: true)
    holder.acquire

    # A direct `Step.run` call has no StepExecutor around it, so a
    # contention raise propagates as-is (the same way `enforce_contract!`'s
    # `InputValidationError` already does from this entry point) rather than
    # returning a Failure value.
    expect do
      WaitOneLockedChargeStep.run({ run_id: step_coord_run_id, account_id: account_id }, nil)
    end.to raise_error(RubyReactor::Executor::StepCoordination::Contended)

    holder.release
    result = WaitOneLockedChargeStep.run({ run_id: step_coord_run_id, account_id: account_id }, nil)
    expect(result).to be_a(RubyReactor::Success)
  end

  it "records exactly one :lock_acquired for an executor-driven class step (never a second time by " \
     "the executor)" do
    mw, events = capture_middleware
    RubyReactor.configuration.middlewares = [mw]
    account_id = unique_account_id

    result = LockedChargeReactor.run(run_id: step_coord_run_id, account_id: account_id)

    expect(result).to be_a(RubyReactor::Success)
    expect(events.count { |event, _args| event == :lock_acquired }).to eq(1)
  end

  describe "stand-alone direct calls vs a running reactor (US4-7)" do
    it "contends with a REACTOR-level hold on the same key" do
      account_id = unique_account_id
      holder = Thread.new do
        ReactorLevelOnlyLockedReactor.run(run_id: step_coord_run_id, account_id: account_id, sleep_for: 1.0)
      end

      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
      until RubyReactor.configuration.storage_adapter.lock_info("lock:acct:#{account_id}")
        raise "reactor never took the lock" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

        sleep 0.02
      end

      expect do
        WaitZeroLockedChargeStep.run({ run_id: step_coord_run_id, account_id: account_id }, nil)
      end.to raise_error(RubyReactor::Executor::StepCoordination::Contended)

      holder.join
    end

    it "contends with a STEP-level hold on the same key" do
      account_id = unique_account_id
      holder = Thread.new do
        LockedChargeReactor.run(run_id: step_coord_run_id, account_id: account_id, sleep_for: 1.0)
      end

      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
      until RubyReactor.configuration.storage_adapter.lock_info("lock:acct:#{account_id}")
        raise "step never took the lock" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

        sleep 0.02
      end

      expect do
        WaitZeroLockedChargeStep.run({ run_id: step_coord_run_id, account_id: account_id }, nil)
      end.to raise_error(RubyReactor::Executor::StepCoordination::Contended)

      holder.join
    end

    it "never lets two stand-alone calls on the same key overlap, and different keys overlap" do
      run_id = step_coord_run_id
      account_id = unique_account_id

      threads = Array.new(2) do
        Thread.new { LockedChargeStep.run({ run_id: run_id, account_id: account_id, sleep_for: 0.2 }, nil) }
      end
      threads.each(&:join)
      expect(overlap_recorder.max_concurrency(:charge)).to eq(1)
    end
  end

  describe "a locked step's body calling another class step directly (US4-8)" do
    it "proceeds re-entrantly on the SAME key, which stays locked by the root id afterward" do
      account_id = unique_account_id
      result = ReentrantInnerCallReactor.run(run_id: step_coord_run_id, account_id: account_id)

      expect(result).to be_a(RubyReactor::Success)
      expect(result.value[:inner_class]).to eq("RubyReactor::Success")
    end

    it "contends on a DIFFERENT inner key held by another execution — re-entrancy exempts only its " \
       "own key" do
      account_id = unique_account_id
      other_account_id = unique_account_id
      key = "acct:#{other_account_id}"
      holder = RubyReactor::Lock.new(key, owner: "external-holder", ttl: 5, wait: 0, auto_extend: true)
      holder.acquire

      result = ReentrantInnerCallReactor.run(run_id: step_coord_run_id, account_id: account_id,
                                             inner_account_id: other_account_id)

      expect(result).to be_a(RubyReactor::Success)
      expect(result.value[:inner_class]).to eq("RubyReactor::Executor::StepCoordination::Contended")
      expect(result.value[:inner_message]).to include(key)
    ensure
      holder&.release
    end

    it "contends with its OWN execution's hold when the inner call passes no context (documents that " \
       "re-entrancy requires passing the execution)" do
      account_id = unique_account_id
      result = ReentrantInnerCallReactor.run(run_id: step_coord_run_id, account_id: account_id,
                                             pass_context: false)

      expect(result).to be_a(RubyReactor::Success)
      expect(result.value[:inner_class]).to eq("RubyReactor::Executor::StepCoordination::Contended")
    end
  end

  it "never serializes coordination_owner (research D5)" do
    context = RubyReactor::Context.new({ account_id: 1 }, LockedChargeReactor)
    context.coordination_owner = "should-not-be-serialized"

    serialized = RubyReactor::ContextSerializer.serialize(context)

    expect(serialized).not_to include("should-not-be-serialized")
    expect(serialized).not_to include("coordination_owner")
  end
end
