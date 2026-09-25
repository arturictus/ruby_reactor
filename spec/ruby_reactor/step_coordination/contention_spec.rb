# frozen_string_literal: true

require "spec_helper"

# US3: losing contention on a step-level primitive parks the execution
# (requeues at that step) in a worker, instead of failing it — bounded by
# `lock_snooze_max_attempts`, with its own counter so a busy key never eats
# the retry budget meant for genuine failures (Finding 2). Synchronously
# there is no queue to park into, so that path waits then fails.
RSpec.describe "step-level contention parks instead of failing", :step_coordination do
  def unique_account_id
    SecureRandom.random_number(10**9)
  end

  def eventually_terminal(reactor_class, execution_id, timeout: 20)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    loop do
      found = reactor_class.find(execution_id)
      return found if found.context.finished?

      if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        raise "#{reactor_class}##{execution_id} never reached a terminal status within #{timeout}s " \
              "(status: #{found.context.status})"
      end
      sleep 0.2
    end
  end

  # Live-Sidekiq lane (Constitution III): `Sidekiq::Testing.inline!` would
  # re-enter the worker inside the frame holding the lock and deadlock.
  # `RubyReactor.configuration` overrides set in THIS process (the spec
  # runner) never reach the live worker — it is a genuinely separate OS
  # process booted from spec/support/sidekiq_boot.rb — so only tests whose
  # assertions do not depend on a specific `lock_snooze_*` value belong here.
  context "with a real sidekiq worker" do
    include_context "with a real async worker", :sidekiq

    it "lets both executions complete, with the loser's trace showing a contention_park and no compensation " \
       "(SC-004, US3-1, US3-2)" do
      run_id = step_coord_run_id
      account_id = unique_account_id

      d1 = BackgroundLockedChargeReactor.run(run_id: run_id, account_id: account_id, sleep_for: 1.0)
      d2 = BackgroundLockedChargeReactor.run(run_id: run_id, account_id: account_id, sleep_for: 1.0)

      r1 = eventually_terminal(BackgroundLockedChargeReactor, d1.execution_id)
      r2 = eventually_terminal(BackgroundLockedChargeReactor, d2.execution_id)

      expect(r1.context.status.to_s).to eq("completed")
      expect(r2.context.status.to_s).to eq("completed")

      park_entries = [r1, r2].map do |r|
        r.context.execution_trace.select { |e| e[:type].to_s == "contention_park" && e[:step].to_s == "charge" }
      end
      expect(park_entries.count(&:any?)).to eq(1), "expected exactly one of the two runs to have parked"

      [r1, r2].each do |r|
        trace_types = r.context.execution_trace.map { |e| e[:type].to_s }
        expect(trace_types).not_to include("compensate", "undo")
      end

      # (2) The :charge body recorder tag appears exactly once per execution.
      expect(overlap_recorder.entries(:charge).size).to eq(4) # 2 runs x (enter + leave)
    end

    it "gives back the contention park's attempt so real failures still get their full retry budget " \
       "(Finding 2)" do
      account_id = unique_account_id
      key = "acct:#{account_id}"
      holder = RubyReactor::Lock.new(key, owner: "external-holder", ttl: 5, wait: 0, auto_extend: true)
      holder.acquire
      Thread.new do
        sleep 0.5
        holder.release
      end

      dispatch = FlakyLockedReactor.run(run_id: step_coord_run_id, account_id: account_id)
      result = eventually_terminal(FlakyLockedReactor, dispatch.execution_id)

      expect(result.context.status.to_s).to eq("failed")
      expect(result.context.retry_context.attempts_for_step(:charge)).to eq(2)
    end

    it "keeps a reactor-level hold across a step-level contention park (FR-018, US3-3)" do
      run_id = step_coord_run_id
      reactor_key = SecureRandom.hex(6)
      account_id = unique_account_id
      charge_key = "acct:#{account_id}"

      charge_holder = RubyReactor::Lock.new(charge_key, owner: "external-holder", ttl: 5, wait: 0,
                                                        auto_extend: true)
      charge_holder.acquire

      dispatch = ReactorAndStepLockedReactor.run(run_id: run_id, reactor_key: reactor_key, account_id: account_id,
                                                 sleep_for: 0)

      # While parked, the reactor-level K1 hold must still be visible, owned
      # by the execution's root context id — never released across the gap.
      sleep 0.3
      info = RubyReactor.configuration.storage_adapter.lock_info("lock:reactor:#{reactor_key}")
      expect(info).not_to be_nil
      expect(info[:owner]).to eq(dispatch.execution_id)

      charge_holder.release

      result = eventually_terminal(ReactorAndStepLockedReactor, dispatch.execution_id)
      expect(result.context.status.to_s).to eq("completed")
      expect("reactor:#{reactor_key}").not_to be_locked
    ensure
      charge_holder&.release
    end

    it "does not consume the reactor-level rate limit a second time across a park (Finding 4)" do
      run_id = step_coord_run_id
      account_id = unique_account_id
      key = "acct:#{account_id}"

      holder = RubyReactor::Lock.new(key, owner: "external-holder", ttl: 5, wait: 0, auto_extend: true)
      holder.acquire
      Thread.new do
        sleep 0.4
        holder.release
      end

      dispatch = RateLimitedFirstStepLockedReactor.run(run_id: run_id, account_id: account_id, sleep_for: 0)
      result = eventually_terminal(RateLimitedFirstStepLockedReactor, dispatch.execution_id)

      expect(result.context.status.to_s).to eq("completed")
      expect("rl:finding4:#{account_id}").to have_rate_limit_count(1).for(:minute)
    end
  end

  # `lock_snooze_max_attempts` must be a low, precise value for this
  # assertion, which the live-worker process (a separate OS process) cannot
  # see when set from here. Driving `Worker#perform` directly, in-process,
  # is the established pattern for exercising snooze/escalation logic
  # deterministically (see spec/ruby_reactor/integration/ordered_lock_spec.rb) —
  # it exercises the exact same `StepExecutor#handle_contention` /
  # `Worker#handle_snooze` code a live redelivery would run.
  describe "the contention ceiling" do
    it "gives up after the configured ceiling, naming the key and attempt count (FR-017, US3-5)" do
      original_max = RubyReactor.configuration.lock_snooze_max_attempts
      RubyReactor.configuration.lock_snooze_max_attempts = 2
      account_id = unique_account_id
      key = "acct:#{account_id}"
      holder = RubyReactor::Lock.new(key, owner: "external-holder", ttl: 60, wait: 0, auto_extend: true)
      holder.acquire

      RubyReactor::Adapters::Sidekiq::Worker.jobs.clear
      dispatch = BackgroundLockedChargeReactor.run(run_id: step_coord_run_id, account_id: account_id, sleep_for: 0)
      job = RubyReactor::Adapters::Sidekiq::Worker.jobs.last

      6.times do
        RubyReactor::Adapters::Sidekiq::Worker.jobs.clear
        RubyReactor::Adapters::Sidekiq::Worker.new.perform(*job["args"].first(2))
        found = BackgroundLockedChargeReactor.find(dispatch.execution_id)
        break if found.context.finished?
      end

      found = BackgroundLockedChargeReactor.find(dispatch.execution_id)
      expect(found.context.status.to_s).to eq("failed")
      message = found.result.message
      expect(message).to include("contention")
      expect(message).to include(key)
      expect(message).to include("2")
    ensure
      RubyReactor.configuration.lock_snooze_max_attempts = original_max
      holder&.release
    end
  end

  describe "the synchronous path" do
    it "waits then fails, naming reactor/step/key, after compensating the prior step (US3-4, FR-016)" do
      account_id = unique_account_id
      key = "acct:#{account_id}"
      holder = RubyReactor::Lock.new(key, owner: "external-holder", ttl: 5, wait: 0, auto_extend: true)
      holder.acquire

      start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = TwoStepLockedReactor.run(run_id: step_coord_run_id, account_id: account_id)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start

      expect(result).to be_a(RubyReactor::Failure)
      # Proves it waited roughly the configured `wait: 1` rather than failing
      # immediately, without being a precise timing assertion — under system
      # load the exact wall time varies on the slow side.
      expect(elapsed).to be >= 0.5
      expect(elapsed).to be < 6.0
      expect(result.message).to include("TwoStepLockedReactor")
      expect(result.message).to include("charge")
      expect(result.message).to include(key)
      expect(result.exception_class).to eq("RubyReactor::Lock::AcquisitionError")
      expect(overlap_recorder.entries(:setup_compensate)).not_to be_empty
    ensure
      holder&.release
    end
  end
end
