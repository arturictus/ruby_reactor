# frozen_string_literal: true

require "spec_helper"
require_relative "../../examples/locking_reactors"

RSpec.describe "Locking Integration" do
  # `redis` + `flushdb` come from spec_helper's RedisHelpers + global `before`.

  describe "Exclusive Locks" do
    it "succeeds when lock is available" do
      result = SimpleLockReactor.run(user_id: 1)
      expect(result).to be_success
      expect(result.value).to eq(process: { processed: true })
    end

    it "supports re-entrancy for the same execution" do
      result = NestedLockReactor.run(user_id: 1)
      expect(result).to be_success
      expect(result.value).to eq(parent: { child: { child_done: true } })
    end

    it "fails synchronously when lock is held by someone else" do
      # Manually hold the lock
      redis.hset("lock:user_1", "owner", "other_guy")
      redis.hset("lock:user_1", "count", "1")

      expect do
        SimpleLockReactor.run(user_id: 1)
      end.to raise_error(RubyReactor::Lock::AcquisitionError)
    end

    describe "inheritance" do
      it "propagates lock config to subclasses" do
        expect(InheritedLockReactor.lock_config).to eq(SimpleLockReactor.lock_config)
      end

      it "lets a subclass acquire the inherited lock" do
        result = InheritedLockReactor.run(user_id: 42)
        expect(result).to be_success
      end
    end

    describe "auto-extend" do
      let(:adapter) { RubyReactor.configuration.storage_adapter }

      it "refreshes the lock TTL while held" do
        lock = RubyReactor::Lock.new(
          "extend_test",
          owner: "owner-1",
          ttl: 2,
          auto_extend: true
        )
        lock.acquire

        # Wait past the original TTL. Extender (interval = ttl/3 ≈ 0.67s)
        # should have refreshed the key at least twice.
        sleep 2.5
        expect(redis.exists?("lock:extend_test")).to be true

        lock.release
        expect(redis.exists?("lock:extend_test")).to be false
      end

      it "stops extending after release" do
        lock = RubyReactor::Lock.new(
          "extend_stop_test",
          owner: "owner-2",
          ttl: 2,
          auto_extend: true
        )
        lock.acquire
        lock.release

        # No more extender activity: another holder takes the key, and our
        # (dead) extender must not refresh someone else's lock.
        redis.hset("lock:extend_stop_test", "owner", "someone_else")
        redis.hset("lock:extend_stop_test", "count", "1")
        redis.expire("lock:extend_stop_test", 1)

        sleep 1.2
        expect(redis.exists?("lock:extend_stop_test")).to be false
      end
    end

    it "reschedules asynchronously when lock is held" do
      # Manually hold the lock
      redis.hset("lock:user_1", "owner", "other_guy")
      redis.hset("lock:user_1", "count", "1")

      RubyReactor.configuration.lock_snooze_base_delay = 5
      RubyReactor.configuration.lock_snooze_jitter = 0

      # Stub SidekiqWorker to capture rescheduling (snooze counter starts at 1)
      allow(RubyReactor::Adapters::Sidekiq::Worker).to receive(:perform_in)

      # Persist the context, then drive the worker by id (identity-only payload).
      context = RubyReactor::Context.new({ user_id: 1 }, SimpleLockReactor)
      RubyReactor.configuration.storage_adapter.store_context(
        context.context_id, RubyReactor::ContextSerializer.serialize(context), "SimpleLockReactor"
      )

      worker = RubyReactor::Adapters::Sidekiq::Worker.new
      worker.perform(context.context_id, "SimpleLockReactor")

      expect(RubyReactor::Adapters::Sidekiq::Worker).to have_received(:perform_in)
        .with(5.0, instance_of(String), "SimpleLockReactor", 1)
    end
  end

  describe "Periods" do
    before { PeriodicCounters.reset }

    it "runs the first time and marks the bucket" do
      result = PeriodicReactor.run(org_id: 7)

      expect(result).to be_success
      expect(result.skipped?).to be false
      expect(PeriodicCounters.runs).to eq(1)

      bucket_key = RubyReactor::Period.key("daily_report:7", :day)
      expect(redis.exists?(bucket_key)).to be true
    end

    it "skips subsequent runs in the same bucket without executing steps" do
      PeriodicReactor.run(org_id: 7)
      result = PeriodicReactor.run(org_id: 7)

      expect(result).to be_a(RubyReactor::Skipped)
      expect(result.skipped?).to be true
      expect(result.success?).to be true
      expect(result.period_key).to end_with(":#{RubyReactor::Period.bucket_id(:day)}")
      expect(PeriodicCounters.runs).to eq(1)
    end

    it "isolates buckets per key" do
      PeriodicReactor.run(org_id: 7)
      result = PeriodicReactor.run(org_id: 8)

      expect(result).to be_success
      expect(result.skipped?).to be false
      expect(PeriodicCounters.runs).to eq(2)
    end

    it "does not mark the bucket when the run fails" do
      first = FailingPeriodicReactor.run(org_id: 1)
      expect(first).to be_failure

      bucket_key = RubyReactor::Period.key("failing_daily:1", :day)
      expect(redis.exists?(bucket_key)).to be false

      second = FailingPeriodicReactor.run(org_id: 1)
      expect(second).to be_failure
    end

    it "combines with with_lock for at-most-one-per-bucket" do
      LockedPeriodicReactor.run(id: 99)
      result = LockedPeriodicReactor.run(id: 99)

      expect(result.skipped?).to be true
      expect(PeriodicCounters.locked_runs).to eq(1)
    end

    it "re-checks the period gate after lock acquisition (racer wrote the marker while we contended)" do
      adapter = RubyReactor.configuration.storage_adapter
      marker_key = RubyReactor::Period.key("locked_periodic:9", :day)

      # Simulate the race: both callers pass the pre-lock gate (no marker yet),
      # then serialize on the lock. By the time WE hold the lock, the winner
      # has completed and marked the bucket. Without the post-lock re-check
      # this run would execute the steps a second time.
      allow(adapter).to receive(:lock_acquire).and_wrap_original do |m, *args|
        acquired = m.call(*args)
        adapter.period_mark(marker_key, 3600) if acquired
        acquired
      end

      result = LockedPeriodicReactor.run(id: 9)

      expect(result).to be_a(RubyReactor::Skipped)
      expect(result.reason).to eq(:period)
      expect(PeriodicCounters.locked_runs).to eq(0)
      # The lock must still be released on the skip path.
      expect(redis.exists?("lock:locked_periodic:9")).to be false
    end

    it "uses TTL = 2x the period length" do
      PeriodicReactor.run(org_id: 7)
      bucket_key = RubyReactor::Period.key("daily_report:7", :day)
      ttl = redis.ttl(bucket_key)
      expect(ttl).to be > 86_400 # > 1 day
      expect(ttl).to be <= 86_400 * 2 # ≤ 2 days
    end
  end

  # Our state matchers take a bare key string as their subject (e.g.
  # `expect("order:42").to be_locked`). RuboCop's ExpectActual cop flags
  # literal subjects, but here the literal IS the key under test.
  # rubocop:disable RSpec/ExpectActual
  describe "RSpec matchers" do
    describe "be_skipped" do
      it "matches a Skipped result returned by a step" do
        result = StepSkipReactor.run(should_skip: true)

        expect(result).to be_skipped
        expect(result).to be_skipped.because("no work to do")
        expect(result).to be_skipped.at_step(:second)
      end

      it "matches a Skipped result from the period gate" do
        PeriodicReactor.run(org_id: 7)
        result = PeriodicReactor.run(org_id: 7)

        expect(result).to be_skipped.because(:period)
      end

      it "does not match a plain Success" do
        result = StepSkipReactor.run(should_skip: false)
        expect(result).not_to be_skipped
      end
    end

    describe "be_locked" do
      let(:adapter) { RubyReactor.configuration.storage_adapter }

      it "matches a held lock" do
        redis.hset("lock:order:42", "owner", "ctx-abc")
        redis.hset("lock:order:42", "count", "1")

        expect("order:42").to be_locked
        expect("order:42").to be_locked.by("ctx-abc")
      end

      it "rejects a free key" do
        expect("order:42").not_to be_locked
      end

      it "rejects a wrong-owner assertion" do
        redis.hset("lock:order:42", "owner", "ctx-abc")
        redis.hset("lock:order:42", "count", "1")

        expect("order:42").not_to be_locked.by("someone-else")
      end
    end

    describe "have_available_tokens / have_held_tokens" do
      it "reports semaphore pool state" do
        s = RubyReactor::Semaphore.new("api_limit", limit: 3)
        s.acquire
        s.acquire

        expect("api_limit").to have_available_tokens(1)
        expect("api_limit").to have_held_tokens(2)
      end
    end

    describe "have_rate_limit_count" do
      it "reports the current bucket count" do
        2.times { RateLimitedReactor.run(account_id: 99) }

        expect("api:99").to have_rate_limit_count(2).for(:second)
      end

      it "raises a clear error if .for(period) is missing" do
        expect do
          expect("api:99").to have_rate_limit_count(0)
        end.to raise_error(ArgumentError, /\.for\(period\)/)
      end
    end

    describe "be_period_marked" do
      it "matches after a successful periodic run" do
        PeriodicReactor.run(org_id: 7)
        expect("daily_report:7").to be_period_marked.for(:day)
      end

      it "does not match before the first run" do
        expect("daily_report:7").not_to be_period_marked.for(:day)
      end
    end
  end
  # rubocop:enable RSpec/ExpectActual

  describe "Skipped step result" do
    before { SkippedStepCounters.reset }

    it "halts the reactor when a step returns Skipped" do
      result = StepSkipReactor.run(should_skip: true)

      expect(result).to be_a(RubyReactor::Skipped)
      expect(result.skipped?).to be true
      expect(result.reason).to eq("no work to do")
      expect(result.step_name).to eq(:second)
    end

    it "does not execute downstream steps after a skip" do
      StepSkipReactor.run(should_skip: true)

      expect(SkippedStepCounters.first_ran).to eq(1)
      expect(SkippedStepCounters.second_ran).to eq(1)
      expect(SkippedStepCounters.third_ran).to eq(0)
    end

    it "does NOT compensate previously completed steps" do
      StepSkipReactor.run(should_skip: true)

      expect(SkippedStepCounters.undo_count).to eq(0)
    end

    it "still runs the full chain when the step returns Success" do
      result = StepSkipReactor.run(should_skip: false)

      expect(result).to be_success
      expect(result.skipped?).to be false
      expect(SkippedStepCounters.first_ran).to eq(1)
      expect(SkippedStepCounters.second_ran).to eq(1)
      expect(SkippedStepCounters.third_ran).to eq(1)
      expect(SkippedStepCounters.undo_count).to eq(0)
    end

    it "still satisfies result.success? (Skipped is a Success subclass)" do
      result = StepSkipReactor.run(should_skip: true)
      expect(result.success?).to be true
    end

    it "is constructible via RubyReactor.Skipped(...)" do
      skipped = RubyReactor.Skipped(reason: "manual")
      expect(skipped).to be_a(RubyReactor::Skipped)
      expect(skipped.reason).to eq("manual")
    end

    it "records the skip in the execution trace" do
      reactor = StepSkipReactor.new
      reactor.run(should_skip: true)

      skipped_entries = reactor.execution_trace.select { |e| e[:type] == :skipped }
      expect(skipped_entries.size).to eq(1)
      expect(skipped_entries.first[:step]).to eq(:second)
      expect(skipped_entries.first[:reason]).to eq("no work to do")
    end
  end

  describe "Rate Limits" do
    before { RateLimitCounters.reset }

    def capture_rate_limit_error
      yield
      nil
    rescue RubyReactor::RateLimit::ExceededError => e
      e
    end

    it "allows up to `limit` calls per period" do
      3.times do
        result = RateLimitedReactor.run(account_id: 1)
        expect(result).to be_success
      end
      expect(RateLimitCounters.runs).to eq(3)
    end

    it "raises ExceededError when the window is full" do
      3.times { RateLimitedReactor.run(account_id: 1) }

      error = capture_rate_limit_error { RateLimitedReactor.run(account_id: 1) }

      expect(error).to be_a(RubyReactor::RateLimit::ExceededError)
      expect(error.limit).to eq(3)
      expect(error.period_seconds).to eq(1)
      expect(error.period_name).to eq("second")
      expect(error.retry_after_seconds).to be_between(1, 1)
      expect(error.key_base).to eq("api:1")
    end

    it "does not persist an orphan context when the window is full" do
      3.times { RateLimitedReactor.run(account_id: 99) }

      adapter = RubyReactor.configuration.storage_adapter
      before_ids = adapter.scan_reactors.map { |r| r[:id] }

      capture_rate_limit_error { RateLimitedReactor.run(account_id: 99) }

      after_ids = adapter.scan_reactors.map { |r| r[:id] }
      expect(after_ids - before_ids).to be_empty
    end

    it "isolates buckets per key" do
      3.times { RateLimitedReactor.run(account_id: 1) }
      result = RateLimitedReactor.run(account_id: 2)

      expect(result).to be_success
      expect(RateLimitCounters.runs).to eq(4)
    end

    it "does not consume a slot (or grab a lock) when input validation fails" do
      reactor = Class.new(RubyReactor::Reactor) do
        input :account_id, :integer
        with_lock(ttl: 10) { |i| "validated:#{i[:account_id]}" }
        with_rate_limit(limit: 3, period: :second) { |i| "validated_api:#{i[:account_id]}" }

        step :call_api do
          run { |_inputs| RubyReactor.Success(ok: true) }
        end
      end

      adapter = RubyReactor.configuration.storage_adapter
      allow(adapter).to receive(:lock_acquire).and_call_original

      # Drive the executor directly: this is the layer that orders
      # validation vs. gating (Reactor.run also pre-validates above it).
      result = RubyReactor::Executor.new(reactor, { account_id: "nope" }).execute

      expect(result).to be_a(RubyReactor::Failure)
      expect(result.error).to be_a(RubyReactor::Error::InputValidationError)
      expect(adapter.rate_limit_count("validated_api:nope", :second)).to eq(0)
      expect(adapter).not_to have_received(:lock_acquire)
    end

    it "does not consume a slot when the window is full" do
      3.times { RateLimitedReactor.run(account_id: 1) }

      bucket_key = "rate:api:1:second:#{Time.now.to_i / 1}"
      before_failed = redis.get(bucket_key).to_i

      raised = nil
      begin
        RateLimitedReactor.run(account_id: 1)
      rescue RubyReactor::RateLimit::ExceededError => e
        raised = e
      end
      expect(raised).not_to be_nil

      after_failed = redis.get(bucket_key).to_i
      expect(after_failed).to eq(before_failed)
    end

    describe "multi-window" do
      it "passes when both windows have headroom" do
        2.times do
          result = MultiWindowRateLimitedReactor.run(account_id: 5)
          expect(result).to be_success
        end
      end

      it "fails when the tightest (per-second) window is full" do
        2.times { MultiWindowRateLimitedReactor.run(account_id: 5) }

        error = capture_rate_limit_error { MultiWindowRateLimitedReactor.run(account_id: 5) }

        expect(error).to be_a(RubyReactor::RateLimit::ExceededError)
        expect(error.period_name).to eq("second")
        expect(error.limit).to eq(2)
      end

      it "does not increment any window when one fails" do
        2.times { MultiWindowRateLimitedReactor.run(account_id: 5) }

        minute_key = "rate:multi_api:5:minute:#{Time.now.to_i / 60}"
        before = redis.get(minute_key).to_i

        raised = nil
        begin
          MultiWindowRateLimitedReactor.run(account_id: 5)
        rescue RubyReactor::RateLimit::ExceededError => e
          raised = e
        end
        expect(raised).not_to be_nil

        after = redis.get(minute_key).to_i

        # Minute window still has headroom, but should not have been incremented
        # because the second window failed first.
        expect(after).to eq(before)
      end
    end

    describe "named global limits" do
      before do
        RubyReactor.configure do |config|
          config.rate_limits.register(:stripe, limit: 3, period: :second)
        end
      end

      it "resolves windows from the registry and allows up to `limit` calls" do
        3.times do
          expect(NamedRateLimitedReactor.run(account_id: 1)).to be_success
        end
        expect(RateLimitCounters.runs).to eq(3)
      end

      it "uses the name as the shared key base" do
        NamedRateLimitedReactor.run(account_id: 1)

        error = capture_rate_limit_error do
          4.times { NamedRateLimitedReactor.run(account_id: 1) }
        end

        expect(error).to be_a(RubyReactor::RateLimit::ExceededError)
        expect(error.key_base).to eq("stripe")
        expect(error.limit).to eq(3)
      end

      it "shares one bucket across different reactors using the same name" do
        2.times { NamedRateLimitedReactor.run(account_id: 1) }
        # Same :stripe quota, so only one slot remains for the other reactor.
        expect(OtherNamedRateLimitedReactor.run(account_id: 2)).to be_success

        error = capture_rate_limit_error { OtherNamedRateLimitedReactor.run(account_id: 3) }
        expect(error).to be_a(RubyReactor::RateLimit::ExceededError)
      end

      it "supports the multi-window `limits:` form" do
        RubyReactor.configure do |config|
          config.rate_limits.register(:stripe, limits: { second: 2, minute: 5 })
        end

        2.times { expect(NamedRateLimitedReactor.run(account_id: 1)).to be_success }

        error = capture_rate_limit_error { NamedRateLimitedReactor.run(account_id: 1) }
        expect(error.period_name).to eq("second")
        expect(error.limit).to eq(2)
      end

      it "raises a clear error when the name is not registered" do
        RubyReactor.configuration.instance_variable_set(:@rate_limits, RubyReactor::RateLimitRegistry.new)

        expect do
          NamedRateLimitedReactor.run(account_id: 1)
        end.to raise_error(RubyReactor::RateLimitRegistry::UnknownLimitError, /Unknown rate limit :stripe/)
      end
    end
  end

  # An async reactor's FIRST run reaches the worker through resume_execution
  # (it never calls Executor#execute), so the period and rate-limit gates must
  # be enforced there too — but only on first runs, never on genuine resumes.
  describe "Async first-run gating (worker resume path)" do
    let(:worker) { RubyReactor::Adapters::Sidekiq::Worker.new }

    # Identity-only payload: the worker rehydrates from storage by id, so a fresh
    # async first-run must be persisted before the worker is driven.
    def store_fresh_context(reactor_class, inputs)
      context = RubyReactor::Context.new(inputs, reactor_class)
      persist(context, reactor_class)
      context.context_id
    end

    def persist(context, reactor_class)
      RubyReactor.configuration.storage_adapter.store_context(
        context.context_id, RubyReactor::ContextSerializer.serialize(context), reactor_class.name
      )
    end

    before do
      PeriodicCounters.reset
      RateLimitCounters.reset
      RubyReactor.configuration.lock_snooze_jitter = 0
    end

    describe "period gate" do
      it "runs the first worker pass and marks the bucket" do
        worker.perform(store_fresh_context(PeriodicReactor, { org_id: 70 }), "PeriodicReactor")

        expect(PeriodicCounters.runs).to eq(1)
        expect(redis.exists?(RubyReactor::Period.key("daily_report:70", :day))).to be true
      end

      it "skips a fresh worker pass when the bucket is already marked" do
        allow(RubyReactor::Adapters::Sidekiq::Worker).to receive(:perform_in)
        PeriodicReactor.run(org_id: 71)
        PeriodicCounters.reset

        executor = worker.perform(store_fresh_context(PeriodicReactor, { org_id: 71 }), "PeriodicReactor")

        expect(executor.result).to be_a(RubyReactor::Skipped)
        expect(PeriodicCounters.runs).to eq(0)
        expect(RubyReactor::Adapters::Sidekiq::Worker).not_to have_received(:perform_in)
      end

      it "does not re-check the gate on a genuine resume (a paused run must not skip itself)" do
        PeriodicReactor.run(org_id: 72) # marks the bucket
        PeriodicCounters.reset

        # Resume mid-flight: current_step set, as every pause/handoff path does.
        context = RubyReactor::Context.new({ org_id: 72 }, PeriodicReactor)
        context.current_step = :build_report
        persist(context, PeriodicReactor)
        worker.perform(context.context_id, "PeriodicReactor")

        expect(PeriodicCounters.runs).to eq(1)
      end
    end

    describe "rate limit" do
      it "consumes a slot on the first worker pass" do
        worker.perform(store_fresh_context(RateLimitedReactor, { account_id: 80 }), "RateLimitedReactor")

        expect(RateLimitCounters.runs).to eq(1)
      end

      it "snoozes a fresh worker pass when the window is full, using the retry_after hint" do
        allow(RubyReactor::Adapters::Sidekiq::Worker).to receive(:perform_in)
        3.times { RateLimitedReactor.run(account_id: 81) }
        RateLimitCounters.reset

        worker.perform(store_fresh_context(RateLimitedReactor, { account_id: 81 }), "RateLimitedReactor")

        expect(RateLimitCounters.runs).to eq(0)
        expect(RubyReactor::Adapters::Sidekiq::Worker).to have_received(:perform_in)
          .with(a_value >= 0.1, instance_of(String), "RateLimitedReactor", 1)
      end

      it "does not re-check the limit on a genuine resume (a paused run must not throttle itself)" do
        allow(RubyReactor::Adapters::Sidekiq::Worker).to receive(:perform_in)
        3.times { RateLimitedReactor.run(account_id: 82) } # window now full
        RateLimitCounters.reset

        context = RubyReactor::Context.new({ account_id: 82 }, RateLimitedReactor)
        context.current_step = :call_api
        persist(context, RateLimitedReactor)
        worker.perform(context.context_id, "RateLimitedReactor")

        expect(RateLimitCounters.runs).to eq(1)
        expect(RubyReactor::Adapters::Sidekiq::Worker).not_to have_received(:perform_in)
      end

      it "marks the context failed immediately on an unknown named limit (no snooze, no Sidekiq retry)" do
        allow(RubyReactor::Adapters::Sidekiq::Worker).to receive(:perform_in)
        RubyReactor.configuration.instance_variable_set(:@rate_limits, RubyReactor::RateLimitRegistry.new)

        context = RubyReactor::Context.new({}, NamedRateLimitedReactor)
        persist(context, NamedRateLimitedReactor)

        expect { worker.perform(context.context_id, "NamedRateLimitedReactor") }.not_to raise_error

        reloaded = NamedRateLimitedReactor.find(context.context_id)
        expect(reloaded.context.status.to_s).to eq("failed")
        expect(RubyReactor::Adapters::Sidekiq::Worker).not_to have_received(:perform_in)
      end
    end
  end

  describe "Semaphores" do
    it "succeeds when semaphore capacity is available" do
      result = SemaphoreReactor.run(limit_id: 1)
      expect(result).to be_success
    end

    it "fails when semaphore capacity is exhausted" do
      # Capacity is 2
      # Semaphore.new init pushes limit tokens during acquire if not exists.

      s = RubyReactor::Semaphore.new("api_limit", limit: 2)
      s.acquire # 1 left
      s.acquire # 0 left

      expect do
        SemaphoreReactor.run(limit_id: 1)
      end.to raise_error(RubyReactor::Semaphore::AcquisitionError)
    end

    it "returns the token to the pool on successful run" do
      3.times { expect(SemaphoreReactor.run(limit_id: 1)).to be_success }

      # Pool started with 2 tokens; after 3 sequential runs all tokens should
      # still be available, proving release happened each time.
      expect(redis.llen("semaphore:api_limit")).to eq(2)
      expect(redis.scard("semaphore:api_limit:held")).to eq(0)
    end

    it "ignores double release without inflating the pool" do
      s = RubyReactor::Semaphore.new("api_limit", limit: 2)
      s.acquire
      expect(s.release).to be true
      expect(s.release).to be false

      expect(redis.llen("semaphore:api_limit")).to eq(2)
      expect(redis.scard("semaphore:api_limit:held")).to eq(0)
    end

    it "never grows past limit even under repeated releases" do
      s = RubyReactor::Semaphore.new("api_limit", limit: 2)
      s.acquire
      token = s.token

      # Forge a release call attempting to re-add the same token after it was
      # already returned. The held-set gate must reject it.
      RubyReactor.configuration.storage_adapter.semaphore_release("semaphore:api_limit", token, 2)
      RubyReactor.configuration.storage_adapter.semaphore_release("semaphore:api_limit", token, 2)

      expect(redis.llen("semaphore:api_limit")).to eq(2)
    end
  end
end
