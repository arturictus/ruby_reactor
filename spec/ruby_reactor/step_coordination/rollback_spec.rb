# frozen_string_literal: true

require "spec_helper"

# US6: `compensate` and `undo` of a step run under that step's OWN lock and
# semaphore (never rate limit, period, or the ordered lock), keyed from the
# same arguments — closing the race where a concurrent forward execution
# could enter the step's critical section while rollback undoes it.
RSpec.describe "step-scoped coordination on rollback (compensate/undo)", :step_coordination do
  around do |example|
    original = RubyReactor.configuration.middlewares
    example.run
    RubyReactor.configuration.middlewares = original
  end

  def unique_account_id
    SecureRandom.random_number(10**9)
  end

  def wait_until_locked(key, timeout: 5)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until RubyReactor.configuration.storage_adapter.lock_info("lock:#{key}")
      if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        raise "#{key} was never observed locked within #{timeout}s"
      end

      sleep 0.02
    end
  end

  it "holds the step's own lock, owned by the root context id, while undo runs (US6-1)" do
    account_id = unique_account_id
    context = RubyReactor::Context.new({ run_id: step_coord_run_id, account_id: account_id, sleep_for: 1.0 },
                                       RollbackReactor)

    Thread.new { RubyReactor::Executor.new(RollbackReactor, {}, context).execute }

    wait_until_locked("acct:#{account_id}")
    info = RubyReactor.configuration.storage_adapter.lock_info("lock:acct:#{account_id}")
    expect(info[:owner]).to eq(context.context_id)

    # Wait for the whole run (charge + undo) to actually finish before the
    # example tears down, so the next example starts from a clean key.
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
    until RubyReactor.configuration.storage_adapter.lock_info("lock:acct:#{account_id}").nil?
      raise "never released" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.05
    end
  end

  it "keeps a concurrent forward run from overlapping the undo (SC-009, US6-2)" do
    run_id = step_coord_run_id
    account_id = unique_account_id

    undo_thread = Thread.new do
      RollbackReactor.run(run_id: run_id, account_id: account_id, sleep_for: 1.0)
    end

    # Give the first run a head start into :charge so its undo (not a second
    # :charge run) is the one holding the key when the second run starts.
    sleep 0.3
    forward_thread = Thread.new do
      LockedChargeReactor.run(run_id: run_id, account_id: account_id, sleep_for: 0.3)
    end

    [undo_thread, forward_thread].each(&:join)

    expect(overlap_recorder.overlapped?(:charge_undo, :charge)).to be(false)
  end

  it "keeps a concurrent forward run from overlapping compensate, when :charge itself fails" do
    run_id = step_coord_run_id
    account_id = unique_account_id

    compensate_thread = Thread.new do
      CompensateReactor.run(run_id: run_id, account_id: account_id, sleep_for: 1.0)
    end

    sleep 0.3
    forward_thread = Thread.new do
      LockedChargeReactor.run(run_id: run_id, account_id: account_id, sleep_for: 0.3)
    end

    [compensate_thread, forward_thread].each(&:join)

    expect(overlap_recorder.overlapped?(:charge_compensate, :charge)).to be(false)
  end

  it "re-takes a limit:1 semaphore for undo" do
    run_id = step_coord_run_id
    resource_id = unique_account_id

    result = SemaphoreRollbackReactor.run(run_id: run_id, resource_id: resource_id)

    expect(result).to be_a(RubyReactor::Failure)
    expect(overlap_recorder.entries(:semrb_run)).not_to be_empty
    expect(overlap_recorder.entries(:semrb_undo)).not_to be_empty
  end

  it "runs undo even when the step's rate limit and period quotas are already exhausted (US6-3, " \
     "FR-025)" do
    run_id = step_coord_run_id
    account_id = unique_account_id

    # :charge's own (limit: 1) rate-limit slot and period bucket are
    # consumed by its OWN successful run — by the time :boom fails and
    # rollback re-takes :charge's lock for undo, both are already
    # naturally exhausted. Neither must gate `around_rollback`.
    result = QuotaGatedRollbackReactor.run(run_id: run_id, account_id: account_id)

    expect(result).to be_a(RubyReactor::Failure)
    expect(overlap_recorder.entries(:quota_run)).not_to be_empty
    expect(overlap_recorder.entries(:quota_undo)).not_to be_empty
    expect("quota_rl:#{account_id}").to have_rate_limit_count(1).for(:minute)
  end

  it "reports (never silently skips) a rollback that cannot re-acquire its key (US6-4, FR-026)" do
    account_id = unique_account_id
    key = "acct:#{account_id}"
    holder = RubyReactor::Lock.new(key, owner: "external-holder", ttl: 5, wait: 0, auto_extend: true)
    holder.acquire

    # `compensate_step` returning a Failure (the re-acquire failure) is what
    # `CompensationManager#handle_step_failure` turns into a raised
    # `CompensationError` — a compensation failure is more serious than an
    # ordinary step failure, so it must never look like a clean rollback.
    result = CompensateReactor.run(run_id: step_coord_run_id, account_id: account_id)

    expect(result).to be_a(RubyReactor::Failure)
    expect(result.message).to include(key)
  ensure
    holder&.release
  end

  it "reports (never silently skips) an undo that cannot re-acquire its key, via :failed_undo and " \
     "a recorded trace entry naming it (US6-4, FR-026)" do
    account_id = unique_account_id
    key = "acct:#{account_id}"

    events = []
    mw = Class.new do
      define_method(:on) { |event, *args| events << [event, args] }
    end.new
    original_mw = RubyReactor.configuration.middlewares
    RubyReactor.configuration.middlewares = [mw]

    # A single-step reactor (no :boom) — :charge succeeds and nothing
    # triggers automatic rollback, so `undo_all` below is the only rollback
    # (an operator-triggered undo, matching `Reactor#undo`'s public API).
    context = RubyReactor::Context.new({ run_id: step_coord_run_id, account_id: account_id }, LockedChargeReactor)
    executor = RubyReactor::Executor.new(LockedChargeReactor, {}, context)
    executor.execute

    holder = RubyReactor::Lock.new(key, owner: "external-holder", ttl: 5, wait: 0, auto_extend: true)
    holder.acquire

    executor.undo_all

    expect(events.map(&:first)).to include(:failed_undo)
    entry = context.execution_trace.reverse.find { |e| e[:type] == :undo && e[:step].to_s == "charge" }
    expect(entry).not_to be_nil
    expect(entry[:result].to_s).to include(key)
  ensure
    RubyReactor.configuration.middlewares = original_mw
    holder&.release
  end

  describe "rollback of an inline step with no argument wiring" do
    it "re-takes the key the forward run held, not one built from an empty hash" do
      mw, events = capture_step_events
      RubyReactor.configuration.middlewares = [mw]
      account_id = unique_account_id

      expect(InlineNoArgsRollbackReactor.run(account_id: account_id)).to be_a(RubyReactor::Failure)

      keys = events.select { |event, *| event == :lock_acquired }.map { |_e, key, _s| key }
      # Twice: once forward, once for the undo — and both on the SAME key.
      expect(keys).to eq(["inline_rollback:#{account_id}"] * 2)
    end
  end

  describe "the async_step dispatch deadlock guard" do
    it "unwinds the steps that already ran, without compensating the refused step" do
      DEADLOCK_GUARD_UNDONE.clear
      RubyReactor::Adapters::Sidekiq::StepWorker.jobs.clear
      account_id = unique_account_id

      result = DeadlockGuardRollbackReactor.run(account_id: account_id)

      expect(result).to be_a(RubyReactor::Failure)
      expect(result.message).to include("would deadlock")
      expect(DEADLOCK_GUARD_UNDONE).to eq([:side_effect])
      expect(RubyReactor::Adapters::Sidekiq::StepWorker.jobs).to be_empty
    end
  end

  describe "an async_step deadlock guard whose key proc raises" do
    before { ROUND4_COUNTS.clear }

    it "fails the step with a KeyError and still rolls the earlier step back" do
      result = Round4GuardKeyReactor.run(account_id: unique_account_id)

      expect(result).to be_a(RubyReactor::Failure)
      expect(result.error.to_s).to match(/key proc raised RuntimeError/)
      expect(result.to_h[:exception_class]).to eq("RubyReactor::Executor::StepCoordination::KeyError")
      expect(ROUND4_COUNTS[:setup_undo]).to eq(1)
    end
  end
end
