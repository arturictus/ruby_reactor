# frozen_string_literal: true

require "spec_helper"

# US3 (005 quickstart R3, P1–P3): a step-level strict ordered lock follows the
# reactor-level gate rules — one exhaustive classifier for both levels, one
# position lifecycle at the step level. State is built in real Redis through
# `OrderedLock`'s own API; nothing here stubs `OrderedLock`.
RSpec.describe "step-level ordered-lock parity", :step_coordination do
  let(:run_id) { step_coord_run_id }
  let(:worker_class) { RubyReactor::Adapters::Sidekiq::Worker }

  def ordered_lock(key, nonce, epoch)
    RubyReactor::OrderedLock.new(key, nonce: nonce, epoch: epoch)
  end

  def sync_run(tag, sleep_seconds: 0.0)
    OspSyncReactor.run(run_id: run_id, tag: tag, sleep_seconds: sleep_seconds)
  end

  def wait_until(timeout: 5)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    sleep 0.02 until yield || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
  end

  def perform_last_job
    job = worker_class.jobs.last
    worker_class.jobs.clear
    worker_class.new.perform(*job["args"])
  end

  describe "a synchronous out-of-turn arrival (R3)" do
    it "fails without poisoning the chain, so a later arrival still runs its body" do
      key = "osp:#{run_id}"
      e1 = Thread.new { sync_run("e1", sleep_seconds: 1.0) }
      wait_until { OspSupport.log(run_id).include?("e1") }

      e2 = sync_run("e2")
      expect(e2).to be_a(RubyReactor::Failure)
      expect(e2.exception_class).to eq("RubyReactor::OrderedLock::WaitError")

      expect(e1.value).to be_a(RubyReactor::Success)
      # E2 never held the turn, so it must not be the chain's failure marker.
      expect(RubyReactor::OrderedLock.peek(key)[:first_failed]).to eq(0)

      e3 = sync_run("e3")
      expect(e3).to be_a(RubyReactor::Success)
      expect(e3.value).to eq("e3")
      expect(OspSupport.log(run_id)).to eq(%w[e1 e3])
    end
  end

  describe "a step whose batch expired before its retry (P1)" do
    it "is skipped with :ordered_lock_stale_batch instead of running unordered" do
      key = "osp:retry:#{run_id}"
      context = RubyReactor::Context.new({ run_id: run_id }, OspRetryReactor)
      context.inline_async_execution = true

      # First attempt fails retryably: a retry is requeued, the position kept.
      expect(RubyReactor::Executor.new(OspRetryReactor, {}, context).execute)
        .to be_a(RubyReactor::RetryQueuedResult)

      # The batch drains past the kept position, and a new batch starts on the
      # same key — the kept nonce now belongs to a dead generation.
      RubyReactor::OrderedLock.skip!(key, nonce: 1)
      RubyReactor::OrderedLock.assign(key)

      executor = perform_last_job

      skipped = executor.execution_trace.find { |e| e[:type].to_s == "skipped" && e[:step].to_s == "ordered" }
      expect(skipped).not_to be_nil
      expect(skipped[:reason].to_s).to eq("ordered_lock_stale_batch")
      expect(redis.get("osp:count:#{run_id}").to_i).to eq(1)
    end
  end

  describe "an abnormal exit from inside the position (P2)" do
    it "stops the heartbeat and leaves the position for the poison pill, without advancing it" do
      key = "osp:abort:#{run_id}"
      heartbeats = []
      allow(RubyReactor::Executor::OrderedLockSupport).to receive(:start_heartbeat).and_wrap_original do |m, *args|
        m.call(*args).tap { |heartbeat| heartbeats << heartbeat }
      end

      expect { OspAbortReactor.run(run_id: run_id, abort: true) }.to raise_error(NoMemoryError)

      thread = heartbeats.last.instance_variable_get(:@thread)
      thread.join(0.3)
      expect(thread).not_to be_alive
      expect(key).to have_ordered_lock_last_completed(0)
      expect(key).to have_ordered_lock_in_flight(1)
    ensure
      heartbeats&.each(&:stop)
    end
  end

  # P3: the data-model "Gate classification" table, run at both levels.
  describe "gate parity (P3)" do
    def reactor_outcome(state)
      key = "osp:r:#{run_id}"
      RubyReactor::OrderedLock.assign(key) if state == :wait
      blockers = Array.new(2) { RubyReactor::OrderedLock.assign(key) } if state == :skip_chain

      dispatch = OspReactorLevel.run(run_id: run_id, tag: "reactor")

      force_state_after_assign(key, state, blockers, target: 1)
      executor = perform_last_job

      return :snoozed if worker_class.jobs.any?
      return [:halted, executor.result.reason] if executor.result.is_a?(RubyReactor::Halt)
      return :ran if OspSupport.log(run_id).include?("reactor")

      [:unexpected, dispatch.execution_id]
    end

    def step_outcome(state)
      key = "osp:#{run_id}"
      context = RubyReactor::Context.new({ run_id: run_id, tag: "step", sleep_seconds: 0.0 }, OspSyncReactor)
      RubyReactor::OrderedLock.assign(key) if state == :wait
      if state == :skip_chain
        blockers = Array.new(2) { RubyReactor::OrderedLock.assign(key) }
        force_state_after_assign(key, state, blockers, target: nil)
      end
      if %i[stale drained].include?(state)
        nonce, epoch = RubyReactor::OrderedLock.assign(key)
        force_state_after_assign(key, state, nil, target: nonce)
        context.private_data[:step_ordered_locks] = {
          "ordered" => { key: key, nonce: nonce, epoch: epoch, poison_pill_timeout: 30,
                         ttl: RubyReactor::OrderedLock::DEFAULT_TTL, strict: true }
        }
      end

      result = RubyReactor::Executor.new(OspSyncReactor, {}, context).execute

      return :contention_failure if result.is_a?(RubyReactor::Failure) &&
                                    result.exception_class == "RubyReactor::OrderedLock::WaitError"

      skipped = context.execution_trace.find { |e| e[:type].to_s == "skipped" }
      return [:skipped, skipped[:reason].to_sym] if skipped
      return :ran if OspSupport.log(run_id).include?("step")

      [:unexpected, result]
    end

    # skip_chain: the SECOND blocker fails (out of order, recording the chain
    # marker), then the first completes — the target passes the dead second
    # blocker by poison and meets the marker. stale/drained: the target's own
    # batch is drained past it; stale then starts a new generation.
    def force_state_after_assign(key, state, blockers, target:)
      case state
      when :skip_chain
        (first, first_epoch), (second, second_epoch) = blockers
        ordered_lock(key, second, second_epoch).advance!(failed: true)
        ordered_lock(key, first, first_epoch).advance!(failed: false)
      when :stale
        RubyReactor::OrderedLock.skip!(key, nonce: target)
        RubyReactor::OrderedLock.assign(key)
      when :drained
        RubyReactor::OrderedLock.skip!(key, nonce: target)
      end
    end

    {
      go: { reactor: :ran, step: :ran },
      wait: { reactor: :snoozed, step: :contention_failure },
      skip_chain: { reactor: %i[halted ordered_lock_chain_failed], step: %i[skipped ordered_lock_chain_failed] },
      stale: { reactor: %i[halted ordered_lock_stale_batch], step: %i[skipped ordered_lock_stale_batch] },
      drained: { reactor: :ran, step: :ran }
    }.each do |state, expected|
      it "#{state}: reactor level #{expected[:reactor].inspect}, step level #{expected[:step].inspect}" do
        expect(reactor_outcome(state)).to eq(expected[:reactor])
        redis.del(OspSupport.log_key(run_id))
        expect(step_outcome(state)).to eq(expected[:step])
      end
    end
  end

  describe "a synchronous contention under a step-level ordered lock" do
    it "advances the position instead of stalling every successor for the poison_pill_timeout" do
      run_id = SecureRandom.uuid
      account_id = unique_account_id
      holder = RubyReactor::Lock.new("sync_seq_lock:#{account_id}", owner: "external-holder", ttl: 60, wait: 0,
                                                                    auto_extend: true)
      holder.acquire

      result = SyncOrderedContendedReactor.run(run_id: run_id, account_id: account_id)

      expect(result).to be_a(RubyReactor::Failure)
      # Nothing will ever redeliver this execution, so a nonce left in flight
      # is a nonce nobody comes back for.
      expect("sync_seq:#{run_id}").to be_ordered_lock_drained
    ensure
      holder&.release
    end
  end

  describe "a step-level ordered lock re-entered on the same key in one thread" do
    before { RubyReactor::Executor::OrderedLockSupport.active_keys.clear }

    it "skips the inner nonce instead of waiting for a turn that can never come" do
      run_id = SecureRandom.uuid

      result = NestedOrderedOuterReactor.run(run_id: run_id)

      # Without the guard the inner assigns nonce 2, is told to wait for the
      # outer's nonce 1, and fails synchronously — `result.value` would be a
      # Failure instead of the inner reactor's own return.
      expect(result).to be_a(RubyReactor::Success)
      expect(result.value).to eq(:inner)
      expect(RubyReactor::Executor::OrderedLockSupport.active_keys).to be_empty
      expect("nested_step_seq:#{run_id}").to be_ordered_lock_drained
    end
  end
end
