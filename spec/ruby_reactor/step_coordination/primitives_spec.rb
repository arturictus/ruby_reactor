# frozen_string_literal: true

require "spec_helper"

# US5: semaphore, rate limit, and period (dedup) at step level, in the fixed
# order of contract §3. The step-level ordered lock is Phase 11 (T058+),
# added as a later section of this same file.
RSpec.describe "step-scoped semaphore, rate limit, and period", :step_coordination do
  def unique_id
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

  describe "with_semaphore" do
    it "lets at most `limit` executions run concurrently, and all succeed (US5-1)" do
      run_id = step_coord_run_id
      resource_id = unique_id

      # wait: 0 on the fixture (see its comment) — retry client-side on
      # contention instead of a blocking server-side wait.
      threads = Array.new(5) do
        Thread.new do
          result = nil
          10.times do
            result = StepSemaphoreReactor.run(run_id: run_id, resource_id: resource_id, sleep_for: 0.2)
            break if result.is_a?(RubyReactor::Success)

            sleep 0.05
          end
          result
        end
      end
      results = threads.map(&:value)

      expect(results).to all(be_a(RubyReactor::Success))
      expect(overlap_recorder.max_concurrency(:sem)).to eq(2)
    end

    it "registers a limit:1 semaphore key in the held-keys registry during the body" do
      result = SemaphoreLimitOneReactor.run(run_id: step_coord_run_id, resource_id: unique_id)

      expect(result).to be_a(RubyReactor::Success)
      expect(result.value[:held]).to be(true)
    end
  end

  describe "with_rate_limit" do
    it "allows exactly `limit` runs per window, then fails the next one (US5-2)" do
      account_id = unique_id

      results = Array.new(3) { StepRateLimitedReactor.run(account_id: account_id) }

      expect(results.first(2)).to all(be_a(RubyReactor::Success))
      expect(results.last).to be_a(RubyReactor::Failure)
      expect(results.last.exception_class).to eq("RubyReactor::RateLimit::ExceededError")
    end

    it "uses config.rate_limits for a named limit" do
      RubyReactor.configuration.rate_limits.register(:step_coordination_named_limit, limit: 1, period: :minute)
      account_id = unique_id

      first = StepNamedRateLimitedReactor.run(account_id: account_id)
      second = StepNamedRateLimitedReactor.run(account_id: account_id)

      expect(first).to be_a(RubyReactor::Success)
      expect(second).to be_a(RubyReactor::Failure)
      expect(second.exception_class).to eq("RubyReactor::RateLimit::ExceededError")
    end

    it "gives a non-retryable Failure (not a park) for an unknown named limit" do
      result = UnknownRateLimitedReactor.run(account_id: unique_id)

      # A park would raise `Error::StepContentionPark` (in a worker) instead of
      # returning; a result at all means it was not treated as contention.
      expect(result).to be_a(RubyReactor::Failure)
      # Confirms it was not retried (the retry loop's own "attempts" count
      # stayed at 1) rather than asserting `.retryable?` directly — once a
      # non-retryable Failure passes through
      # `RetryManager#handle_non_retryable_failure`, the framework's
      # `MaxRetriesExhaustedFailure` wrapper does not thread the original
      # `retryable:` flag through to its own `.retryable?` (a pre-existing
      # characteristic of that wrapper, not specific to this feature).
      expect(result.message).to include("failed after 1 attempts")
    end
  end

  describe "with_period" do
    it "skips the step on the second call in the same bucket; the reactor still succeeds, later steps " \
       "run (FR-003, US5-3)" do
      run_id = step_coord_run_id
      bucket_key = unique_id

      first = PeriodReactor.run(run_id: run_id, bucket_key: bucket_key)
      second = PeriodReactor.run(run_id: run_id, bucket_key: bucket_key)

      expect(first).to be_a(RubyReactor::Success)
      expect(second).to be_a(RubyReactor::Success)
      expect(second).not_to be_a(RubyReactor::Halt)
      expect(overlap_recorder.entries(:period_body).size).to eq(2) # only the first run's enter+leave
      expect(overlap_recorder.entries(:after_period)).not_to be_empty
    end

    it "does not mark the bucket when the step body fails" do
      bucket_key = unique_id

      first = PeriodReactor.run(run_id: step_coord_run_id, bucket_key: bucket_key, fail_body: true)
      expect(first).to be_a(RubyReactor::Failure)

      expect("period:#{bucket_key}").not_to be_period_marked.for(:hour)
    end

    it "closes the race between two threads racing a fresh bucket: exactly one body execution (D3 " \
       "step 6)" do
      run_id = step_coord_run_id
      bucket_key = unique_id

      threads = Array.new(2) { Thread.new { PeriodPlusLockReactor.run(run_id: run_id, bucket_key: bucket_key) } }
      results = threads.map(&:value)

      expect(results).to all(be_a(RubyReactor::Success))
      expect(overlap_recorder.entries(:period_lock_body).size).to eq(2) # one enter + one leave
    end
  end

  describe "lock and semaphore together" do
    it "runs without deadlock, releasing semaphore before lock (FR-008)" do
      mw, events = capture_middleware
      RubyReactor.configuration.middlewares = [mw]
      key_id = unique_id

      result = LockAndSemaphoreReactor.run(run_id: step_coord_run_id, key_id: key_id)

      expect(result).to be_a(RubyReactor::Success)
      release_events = events.map(&:first).select { |e| %i[semaphore_released lock_released].include?(e) }
      expect(release_events).to eq(%i[semaphore_released lock_released])
    end
  end

  # Phase 11 (T058): step-level `with_ordered_lock`. Live-Sidekiq lane —
  # the gate's WaitError/park behavior is a genuine worker-redelivery claim.
  describe "with_ordered_lock" do
    include_context "with a real async worker", :sidekiq

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

    it "runs the FIRST step's body in nonce order, never overlapping, across 5 background runs, and " \
       "drains cleanly (US5-4, item 7)" do
      run_id = step_coord_run_id
      key = "seq:#{run_id}"

      dispatches = Array.new(5) { |i| OrderedLockFirstReactor.run(run_id: run_id, position: i) }
      results = dispatches.map { |d| eventually_terminal(OrderedLockFirstReactor, d.execution_id) }

      expect(results.map { |r| r.context.status.to_s }).to all(eq("completed"))
      expect(overlap_recorder.max_concurrency(:seq)).to eq(1)
      # A fully-drained sequence self-GCs (next/last_completed both reset to
      # 0) — that reset IS "drains cleanly", checked via be_ordered_lock_drained.
      # have_ordered_lock_next/_last_completed are exercised pre-drain in the
      # strict-mode chain-skip example below.
      expect(key).to be_ordered_lock_drained
    end

    it "lets a later unordered step of one run overlap another run's ordered step — surrounding " \
       "steps are unaffected (item 2)" do
      run_id = step_coord_run_id

      d0 = OrderedLockFirstReactor.run(run_id: run_id, position: 0, sleep_for: 0.02)

      # Wait for run0's :seq to finish (both its enter and leave recorded) —
      # it is now sleeping through its wide (fixture) :after window — before
      # dispatching run1. The live worker here only has 2 threads (T058),
      # so drawing on queue timing for BOTH runs' dispatch order AND their
      # overlap is a coin flip; gating run1's dispatch on run0 already being
      # inside :after makes the overlap opportunity deterministic instead.
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
      until overlap_recorder.entries(:seq).size >= 2
        raise "run0's :seq never completed" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

        sleep 0.05
      end

      d1 = OrderedLockFirstReactor.run(run_id: run_id, position: 1, sleep_for: 0.02)

      [d0, d1].each { |d| eventually_terminal(OrderedLockFirstReactor, d.execution_id) }
      expect(overlap_recorder.overlapped?(:after_seq, :seq)).to be(true)
    end

    it "with strict: false, runs every position regardless of an earlier failure (item 4)" do
      run_id = step_coord_run_id

      d1 = OrderedLockLenientReactor.run(run_id: run_id, position: 1)
      r1 = eventually_terminal(OrderedLockLenientReactor, d1.execution_id)
      expect(r1.context.status.to_s).to eq("completed")

      d2 = OrderedLockLenientReactor.run(run_id: run_id, position: 2, fail_at: true)
      r2 = eventually_terminal(OrderedLockLenientReactor, d2.execution_id)
      expect(r2.context.status.to_s).to eq("failed")

      d3 = OrderedLockLenientReactor.run(run_id: run_id, position: 3)
      r3 = eventually_terminal(OrderedLockLenientReactor, d3.execution_id)
      expect(r3.context.status.to_s).to eq("completed")
      expect(r3).not_to be_skipped.at_step(:seq)

      expect(overlap_recorder.entries(:lenient_seq).size).to eq(6) # 3 positions x (enter + leave)
    end

    it "advances past a position that INCRed but never arrives, once poison_pill_timeout elapses " \
       "(item 6)" do
      run_id = step_coord_run_id
      key = "poison:#{run_id}"
      nonce1, = RubyReactor::OrderedLock.assign(key) # never runs — simulates a crashed caller
      expect(nonce1).to eq(1)

      dispatch = OrderedLockPoisonReactor.run(run_id: run_id, position: 2)
      result = eventually_terminal(OrderedLockPoisonReactor, dispatch.execution_id, timeout: 15)

      expect(result.context.status.to_s).to eq("completed")
    ensure
      RubyReactor::OrderedLock.reset!(key)
    end

    it "is never re-taken for rollback (data-model rollback table, item 8)" do
      run_id = step_coord_run_id
      key = "rollback_seq:#{run_id}"

      # A single-position sequence self-GCs (next resets to 0) the moment it
      # fully drains, so a before/after counter read can't tell "never
      # re-taken" from "drained" — counting real `.assign` calls can.
      assign_calls = 0
      allow(RubyReactor::OrderedLock).to receive(:assign).and_wrap_original do |original, *args|
        assign_calls += 1
        original.call(*args)
      end

      result = OrderedLockRollbackReactor.run(run_id: run_id, position: 1)

      expect(result).to be_a(RubyReactor::Failure)
      expect(overlap_recorder.entries(:ordered_rollback_compensate)).not_to be_empty
      # Only the forward run's own gate assigns a nonce — `around_rollback`
      # never calls into the ordered-lock gate at all for compensate.
      expect(assign_calls).to eq(1)
    ensure
      RubyReactor::OrderedLock.reset!(key)
    end
  end

  # No live worker needed: driven directly through Executor#execute /
  # #resume_execution with `inline_async_execution` set, the same in-process
  # park simulation observability_spec.rb uses — keeps this out of the real
  # Sidekiq lane so no live worker races the manual `resume_execution` call.
  describe "with_ordered_lock contention redelivery" do
    it "reuses the same nonce across a park instead of assigning a fresh one (item 5)" do
      run_id = step_coord_run_id
      key = "seq:#{run_id}"
      RubyReactor::OrderedLock.assign(key) # occupies nonce 1, so ours (nonce 2) is out of turn

      context = RubyReactor::Context.new({ run_id: run_id, position: 2 }, OrderedLockFirstReactor)
      context.inline_async_execution = true
      executor = RubyReactor::Executor.new(OrderedLockFirstReactor, {}, context)

      expect { executor.execute }.to raise_error(RubyReactor::Error::StepContentionPark)
      first_nonce = context.private_data[:step_ordered_locks]["seq"][:nonce]
      expect(first_nonce).to eq(2)

      expect { executor.resume_execution }.to raise_error(RubyReactor::Error::StepContentionPark)
      second_nonce = context.private_data[:step_ordered_locks]["seq"][:nonce]
      expect(second_nonce).to eq(first_nonce)
    ensure
      RubyReactor::OrderedLock.reset!(key)
    end
  end

  # Driven directly (no live worker) for full control over exactly which
  # position fails: a single-position-wide sequence self-GCs (both counters
  # AND the poison marker) the instant it fully drains, so letting live,
  # concurrently-dispatched runs decide arrival order can silently erase the
  # very poison marker this scenario needs position 3 to still see.
  describe "with_ordered_lock strict-mode chain skip" do
    def stash_ordered_lock!(context, key, nonce, epoch)
      context.private_data[:step_ordered_locks] = {
        "seq" => {
          key: key, nonce: nonce, epoch: epoch,
          poison_pill_timeout: RubyReactor::OrderedLock::DEFAULT_POISON_PILL_TIMEOUT,
          ttl: RubyReactor::OrderedLock::DEFAULT_TTL, strict: true
        }
      }
    end

    def drive(reactor_class, inputs, key, nonce, epoch)
      context = RubyReactor::Context.new(inputs, reactor_class)
      stash_ordered_lock!(context, key, nonce, epoch)
      context.inline_async_execution = true
      [RubyReactor::Executor.new(reactor_class, {}, context).execute, context]
    end

    it "with strict: true, skips the ordered step for positions after a failed one, whose later " \
       "steps still run (FR-004, US5-5, item 3)" do
      run_id = step_coord_run_id
      key = "seq:#{run_id}"

      nonce1, epoch1 = RubyReactor::OrderedLock.assign(key)
      nonce2, epoch2 = RubyReactor::OrderedLock.assign(key)
      nonce3, epoch3 = RubyReactor::OrderedLock.assign(key)
      # Phantom position 4, never advanced: keeps `next` ahead of
      # `last_completed` through positions 1-3 so the sequence never
      # self-drains (and wipes the poison marker) between them.
      RubyReactor::OrderedLock.assign(key)
      expect(key).to have_ordered_lock_next(4) # item 7: exercised pre-drain, unlike the 5-run example above

      r1, = drive(OrderedLockFirstReactor, { run_id: run_id, position: 1 }, key, nonce1, epoch1)
      expect(r1).to be_a(RubyReactor::Success)

      r2, = drive(OrderedLockFailingReactor, { run_id: run_id, position: 2 }, key, nonce2, epoch2)
      expect(r2).to be_a(RubyReactor::Failure)
      expect(key).to have_ordered_lock_last_completed(2) # item 7

      r3, c3 = drive(OrderedLockFirstReactor, { run_id: run_id, position: 3 }, key, nonce3, epoch3)

      expect(r3).to be_a(RubyReactor::Success) # :after still ran — the reactor completes normally
      skipped = c3.execution_trace.find { |e| e[:type].to_s == "skipped" && e[:step].to_s == "seq" }
      expect(skipped).not_to be_nil
      expect(skipped[:reason]).to eq(:ordered_lock_chain_failed)
      after_entry = c3.execution_trace.find { |e| e[:step].to_s == "after" && e[:type].to_s == "run" }
      expect(after_entry).not_to be_nil
    ensure
      RubyReactor::OrderedLock.reset!(key)
    end
  end

  describe "a once-per-window step whose output contract rejects its value" do
    before { ROUND4_COUNTS.clear }

    it "leaves the bucket unmarked, so the next execution runs the step again" do
      account_id = unique_account_id

      2.times { expect(Round4PeriodReactor.run(account_id: account_id)).to be_a(RubyReactor::Failure) }

      expect(ROUND4_COUNTS[:period_body]).to eq(2)
    end
  end
end
