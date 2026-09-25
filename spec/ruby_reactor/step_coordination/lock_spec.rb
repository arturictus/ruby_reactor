# frozen_string_literal: true

require "spec_helper"

# US1 (a step class's `with_lock` serializes just that step) and part of US2
# (the hold is scoped to the step, not the whole reactor — scope_spec.rb
# covers the "surrounding steps keep overlapping" half). Real Redis, real
# threads: this is a genuine concurrency claim (Constitution III).
#
# Account ids are randomized per example (never small fixed integers): the
# test Redis is shared across worktrees/sessions (see spec/spec_helper.rb),
# so a fixed key like "acct:1" can collide with another session's concurrent
# run of this same spec.
RSpec.describe "step-scoped `with_lock`", :step_coordination do
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

  it "never lets two executions on the same key overlap, across 20 iterations (SC-001)" do
    run_id = step_coord_run_id
    account_id = unique_account_id

    # Two persistent racer threads, each running 10 iterations internally —
    # 20 total executions racing on one key, without spawning 40 OS threads.
    threads = Array.new(2) do
      Thread.new do
        10.times do |i|
          sleep_for = 0.01 + ((i % 3) * 0.005)
          LockedChargeReactor.run(run_id: run_id, account_id: account_id, sleep_for: sleep_for)
        end
      end
    end
    threads.each(&:join)

    expect(overlap_recorder.max_concurrency(:charge)).to eq(1)
  end

  it "lets two executions on different keys overlap" do
    run_id = step_coord_run_id
    t1 = Thread.new { LockedChargeReactor.run(run_id: run_id, account_id: unique_account_id, sleep_for: 0.3) }
    t2 = Thread.new { LockedChargeReactor.run(run_id: run_id, account_id: unique_account_id, sleep_for: 0.3) }
    [t1, t2].each(&:join)

    expect(overlap_recorder.overlapped?(:charge, :charge)).to be(true)
  end

  it "leaves the key free once a locked step succeeds (SC-003)" do
    account_id = unique_account_id
    result = LockedChargeReactor.run(account_id: account_id)

    expect(result).to be_a(RubyReactor::Success)
    expect("acct:#{account_id}").not_to be_locked
  end

  it "leaves the key free when the step body returns a Failure" do
    account_id = unique_account_id
    result = LockedChargeReactor.run(account_id: account_id, fail_after: true)

    expect(result).to be_a(RubyReactor::Failure)
    expect("acct:#{account_id}").not_to be_locked
  end

  it "leaves the key free when the step body raises" do
    account_id = unique_account_id
    result = LockedChargeReactor.run(account_id: account_id, raise_after: true)

    expect(result).to be_a(RubyReactor::Failure)
    expect("acct:#{account_id}").not_to be_locked
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

  it "keys on the resolved argument, after the reactor's own `argument` transform runs" do
    run_id = step_coord_run_id
    account_id = unique_account_id
    thread = Thread.new { TransformLockedChargeReactor.run(run_id: run_id, account_id: account_id, sleep_for: 1.0) }
    wait_until_locked("acct:#{account_id + 100}")

    expect("acct:#{account_id + 100}").to be_locked
    expect("acct:#{account_id}").not_to be_locked
    thread.join
    expect("acct:#{account_id + 100}").not_to be_locked
  end

  it "sees the same `inputs` the instance sees, including a contract default" do
    result = RegionLockedReactor.run(run_id: step_coord_run_id)

    expect(result).to be_a(RubyReactor::Success)
    expect(overlap_recorder.entries(:region)).not_to be_empty
  end

  describe "a failed input contract" do
    it "takes no lock and emits no :lock_acquired (Finding 8)" do
      mw, events = capture_middleware
      RubyReactor.configuration.middlewares = [mw]

      result = AmountContractReactor.run(run_id: step_coord_run_id, amount: "not-an-integer")

      expect(result).to be_a(RubyReactor::Failure)
      expect(events.map(&:first)).not_to include(:lock_acquired)
      expect(overlap_recorder.entries(:amount)).to be_empty
    end
  end

  describe "a misbehaving key proc (SC-011, FR-007)" do
    it "fails the step naming the step and the cause when the key proc raises" do
      result = BadKeyReactor.run(run_id: step_coord_run_id, mode: "raise")

      expect(result).to be_a(RubyReactor::Failure)
      expect(result.message).to include("bad_key")
      expect(result.message).to include("key proc exploded")
      expect(overlap_recorder.entries(:bad_key_body)).to be_empty
    end

    it "fails the step when the key proc returns nil" do
      result = BadKeyReactor.run(run_id: step_coord_run_id, mode: "nil")

      expect(result).to be_a(RubyReactor::Failure)
      expect(overlap_recorder.entries(:bad_key_body)).to be_empty
    end

    it "fails the step when the key proc returns an empty string" do
      result = BadKeyReactor.run(run_id: step_coord_run_id, mode: "empty")

      expect(result).to be_a(RubyReactor::Failure)
      expect(overlap_recorder.entries(:bad_key_body)).to be_empty
    end
  end

  describe "a step suppressed by `where` (FR-012)" do
    it "leaves no lock and emits no :lock_acquired" do
      mw, events = capture_middleware
      RubyReactor.configuration.middlewares = [mw]
      account_id = unique_account_id

      result = GuardedLockedChargeReactor.run(run_id: step_coord_run_id, account_id: account_id)

      expect(result).to be_a(RubyReactor::Success)
      expect(events.map(&:first)).not_to include(:lock_acquired)
      expect("acct:#{account_id}").not_to be_locked
    end
  end

  describe "auto_extend keeps a short ttl from expiring under the held lock (FR-013)" do
    it "keeps a contending wait:0 caller in contention for the whole body" do
      run_id = step_coord_run_id
      account_id = unique_account_id
      holder = Thread.new { SleepyLockReactor.run(run_id: run_id, account_id: account_id, sleep_for: 2.2) }
      wait_until_locked("acct:#{account_id}")

      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 1.7
      contended_checks = 0
      while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
        result = SleepyLockReactor.run(run_id: run_id, account_id: account_id, sleep_for: 0)
        expect(result).to be_a(RubyReactor::Failure)
        contended_checks += 1
        sleep 0.3
      end
      expect(contended_checks).to be >= 3

      holder.join
    end
  end

  describe "a process that dies while holding the lock (SC-008)" do
    it "recovers once the ttl expires" do
      account_id = unique_account_id
      key = "acct:#{account_id}"
      script = <<~RUBY
        require "redis"
        require "ruby_reactor"
        RubyReactor.configure do |c|
          c.storage.adapter = :redis
          c.storage.redis_url = #{REDIS_TEST_URL.inspect}
        end
        RubyReactor::Lock.new(#{key.inspect}, owner: "external-holder", ttl: 1, wait: 0, auto_extend: false).acquire
        sleep 30
      RUBY
      pid = Process.spawn({ "BUNDLE_GEMFILE" => ENV.fetch("BUNDLE_GEMFILE", nil) },
                          "bundle", "exec", "ruby", "-e", script)

      # Wait until the external process actually holds the key (locks are
      # Redis hashes, not strings — poll through the adapter, not GET).
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
      until RubyReactor.configuration.storage_adapter.lock_info("lock:#{key}")
        raise "external holder never acquired the lock" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

        sleep 0.1
      end
      expect(key).to be_locked

      Process.kill("KILL", pid)
      Process.wait(pid)

      sleep 1.3 # > ttl, no auto-extend from a dead process

      result = SleepyLockReactor.run(run_id: step_coord_run_id, account_id: account_id)
      expect(result).to be_a(RubyReactor::Success)
    end
  end

  describe "the coordination backend is unreachable" do
    it "fails the step with the connection error, and the body never runs" do
      original_url = RubyReactor.configuration.storage.redis_url
      RubyReactor.configuration.storage.redis_url = "redis://127.0.0.1:1"
      RubyReactor.configuration.instance_variable_set(:@storage_adapter, nil)

      # Direct class-step invocation (no reactor, no context) isolates the
      # step's OWN coordination failure from the reactor's own context-save
      # calls, which also touch Redis and would otherwise be what actually
      # raises first.
      expect do
        LockedChargeStep.run({ run_id: step_coord_run_id, account_id: unique_account_id }, nil)
      end.to raise_error(StandardError)
    ensure
      RubyReactor.configuration.storage.redis_url = original_url
      RubyReactor.configuration.instance_variable_set(:@storage_adapter, nil)
      # Checked after restoring the URL: `OverlapRecorder` itself reads
      # `RubyReactor.configuration.storage.redis_url` (so the live worker
      # can use it too), which was still pointed at the unreachable host
      # inside the `expect` block above.
      expect(overlap_recorder.entries(:charge)).to be_empty
    end
  end
end
