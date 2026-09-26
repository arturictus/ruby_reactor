# frozen_string_literal: true

require "spec_helper"

# A contention park hands back everything the contended step took (its work
# has not started, so there is nothing to protect across the gap) and keeps
# only its ordered-lock position, so the redelivery does not lose its place in
# line. These specs cover the park itself and what happens when it does NOT
# end in a redelivery: escalated past `lock_snooze_max_attempts`, or turned
# into a plain retry by `retries`.

# Lock and semaphore on the same step: hold the semaphore externally and the
# step takes the lock, then parks on the semaphore — the shape every
# "what happens to the hold" question below is about.
class ParkedHoldStep < RubyReactor::Step
  input :account_id

  with_lock(wait: 0, ttl: 60) { |args| "park_lock:#{args[:account_id]}" }
  with_semaphore(limit: 1, wait: 0) { |args| "park_sem:#{args[:account_id]}" }

  def run
    Success(:charged)
  end
end

class ParkedHoldReactor < RubyReactor::Reactor
  background all: true

  input :account_id

  step :charge, ParkedHoldStep do
    argument :account_id, input(:account_id)
  end

  returns :charge
end

class AsyncParkedHoldReactor < RubyReactor::Reactor
  input :account_id

  async_step :charge, ParkedHoldStep do
    argument :account_id, input(:account_id)
  end

  # `returns` may not name an async_step, and reading its result here would
  # make the reactor wait on the very park under test.
  step :ack do
    run { RubyReactor.Success(:dispatched) }
  end

  returns :ack
end

# Rate limit and a lock that will contend: the rate limit is charged LAST
# (contract §3 order), so the lock parks the execution before any slot is
# spent — however many times it parks.
class QuotaParkStep < RubyReactor::Step
  input :account_id

  with_rate_limit(limit: 5, period: :minute) { |args| "park_rl:#{args[:account_id]}" }
  with_lock(wait: 0) { |args| "park_rl_lock:#{args[:account_id]}" }

  def run
    Success(:charged)
  end
end

class QuotaParkReactor < RubyReactor::Reactor
  background all: true

  input :account_id

  step :charge, QuotaParkStep do
    argument :account_id, input(:account_id)
  end

  returns :charge
end

# Ordered lock plus a lock that will contend: the position is taken, then the
# execution parks holding it.
class OrderedParkStep < RubyReactor::Step
  input :run_id
  input :account_id

  with_ordered_lock { |args| "park_seq:#{args[:run_id]}" }
  with_lock(wait: 0) { |args| "park_seq_lock:#{args[:account_id]}" }

  def run
    Success(:charged)
  end
end

class OrderedParkReactor < RubyReactor::Reactor
  background all: true

  input :run_id
  input :account_id

  step :charge, OrderedParkStep do
    argument :run_id, input(:run_id)
    argument :account_id, input(:account_id)
  end

  returns :charge
end

# An ordered step that fails its FIRST attempt and succeeds on the retry: the
# retry must keep the position it already holds.
class OrderedRetryStep < RubyReactor::Step
  ATTEMPTS = Hash.new(0)

  input :run_id

  with_ordered_lock { |args| "park_retry:#{args[:run_id]}" }

  def run
    ATTEMPTS[inputs.run_id] += 1
    return Failure("first attempt always fails") if ATTEMPTS[inputs.run_id] == 1

    Success(:charged)
  end
end

class OrderedRetryReactor < RubyReactor::Reactor
  input :run_id

  step :charge, OrderedRetryStep do
    argument :run_id, input(:run_id)
    retries max_attempts: 2, backoff: :linear, base_delay: 0.01
  end

  returns :charge
end

# Reactor-side `argument` rules on a coordinated async_step: the worker must
# reject these arguments BEFORE it records the run and takes the step's lock.
class ValidatedAsyncReactor < RubyReactor::Reactor
  input :amount

  async_step :charge do
    argument :amount, input(:amount), :integer, gt?: 0
    with_lock(wait: 0) { |args| "park_validated:#{args[:amount]}" }
    run { |args| RubyReactor.Success(args.amount) }
  end

  step :ack do
    run { RubyReactor.Success(:dispatched) }
  end

  returns :ack
end

RSpec.describe "escalating a step-level contention park", :step_coordination do
  def unique_account_id
    SecureRandom.random_number(10**9)
  end

  # `lock_snooze_max_attempts` has to be a low, precise value, which the
  # live-worker process cannot see when set from here — so these drive
  # `Worker#perform` in-process, the established pattern in contention_spec.
  def with_ceiling(value)
    original = RubyReactor.configuration.lock_snooze_max_attempts
    RubyReactor.configuration.lock_snooze_max_attempts = value
    yield
  ensure
    RubyReactor.configuration.lock_snooze_max_attempts = original
  end

  def redeliver_until_terminal(reactor_class, dispatch, limit: 8)
    job = RubyReactor::Adapters::Sidekiq::Worker.jobs.last
    limit.times do
      RubyReactor::Adapters::Sidekiq::Worker.jobs.clear
      RubyReactor::Adapters::Sidekiq::Worker.new.perform(*job["args"].first(2))
      found = reactor_class.find(dispatch.execution_id)
      return found if found.context.finished?
    end
    reactor_class.find(dispatch.execution_id)
  end

  describe "the park itself" do
    it "releases the step's own lock instead of carrying it across the gap" do
      account_id = unique_account_id
      holder = RubyReactor::Semaphore.new("park_sem:#{account_id}", limit: 1)
      holder.acquire

      RubyReactor::Adapters::Sidekiq::Worker.jobs.clear
      dispatch = ParkedHoldReactor.run(account_id: account_id)
      job = RubyReactor::Adapters::Sidekiq::Worker.jobs.last
      RubyReactor::Adapters::Sidekiq::Worker.jobs.clear
      RubyReactor::Adapters::Sidekiq::Worker.new.perform(*job["args"].first(2))

      found = ParkedHoldReactor.find(dispatch.execution_id)
      expect(found.context.private_data[:step_contention]).to include(primitive: :semaphore)
      expect("park_lock:#{account_id}").not_to be_locked
    ensure
      holder&.release
    end
  end

  describe "past the contention ceiling" do
    it "leaves the step's lock free" do
      account_id = unique_account_id
      holder = RubyReactor::Semaphore.new("park_sem:#{account_id}", limit: 1)
      holder.acquire

      found = with_ceiling(1) do
        RubyReactor::Adapters::Sidekiq::Worker.jobs.clear
        dispatch = ParkedHoldReactor.run(account_id: account_id)
        redeliver_until_terminal(ParkedHoldReactor, dispatch)
      end

      expect(found.context.status.to_s).to eq("failed")
      # Without the release the key would stay held for the full 60s TTL,
      # blocking every other execution on this account.
      expect("park_lock:#{account_id}").not_to be_locked
    ensure
      holder&.release
    end

    it "advances the ordered-lock position the park left in flight" do
      run_id = SecureRandom.uuid
      account_id = unique_account_id
      key = "park_seq:#{run_id}"
      holder = RubyReactor::Lock.new("park_seq_lock:#{account_id}", owner: "external-holder", ttl: 60, wait: 0,
                                                                    auto_extend: true)
      holder.acquire

      found = with_ceiling(1) do
        RubyReactor::Adapters::Sidekiq::Worker.jobs.clear
        dispatch = OrderedParkReactor.run(run_id: run_id, account_id: account_id)
        redeliver_until_terminal(OrderedParkReactor, dispatch)
      end

      expect(found.context.status.to_s).to eq("failed")
      # Left in flight, every later position would stall for the full
      # poison_pill_timeout instead of being chain-skipped. Advanced, the only
      # position drains and the counters are GC'd.
      expect(key).to be_ordered_lock_drained
    ensure
      holder&.release
    end

    it "leaves an async_step's lock free too" do
      account_id = unique_account_id
      holder = RubyReactor::Semaphore.new("park_sem:#{account_id}", limit: 1)
      holder.acquire

      result = with_ceiling(1) do
        dispatch = AsyncParkedHoldReactor.run(account_id: account_id)
        RubyReactor::RSpec::AsyncTestHelpers.drain_async_jobs
        dispatch
      end

      record = RubyReactor.configuration.storage_adapter.retrieve_step_result(
        result.execution_id, :charge, "AsyncParkedHoldReactor"
      )
      expect(record["success"]).to be(false)
      expect(record["result"].inspect).to include("contention")
      expect("park_lock:#{account_id}").not_to be_locked
      context = AsyncParkedHoldReactor.find(result.execution_id).context
      expect(context.private_data[:step_contention]).to be_nil
    ensure
      holder&.release
    end
  end

  describe "the rate-limit gate across a park" do
    it "charges the quota once, however many times the step parks below it" do
      account_id = unique_account_id
      holder = RubyReactor::Lock.new("park_rl_lock:#{account_id}", owner: "external-holder", ttl: 60, wait: 0,
                                                                   auto_extend: true)
      holder.acquire

      RubyReactor::Adapters::Sidekiq::Worker.jobs.clear
      dispatch = QuotaParkReactor.run(account_id: account_id)
      job = RubyReactor::Adapters::Sidekiq::Worker.jobs.last

      # Two parks spend nothing: the lock contends before the charge.
      2.times do
        RubyReactor::Adapters::Sidekiq::Worker.jobs.clear
        RubyReactor::Adapters::Sidekiq::Worker.new.perform(*job["args"].first(2))
      end
      holder.release
      RubyReactor::Adapters::Sidekiq::Worker.new.perform(*job["args"].first(2))

      expect(QuotaParkReactor.find(dispatch.execution_id).context.status.to_s).to eq("completed")
      expect("park_rl:#{account_id}").to have_rate_limit_count(1).for(:minute)
    ensure
      holder&.release
    end
  end

  describe "a retryable failure under an ordered lock" do
    it "keeps its place in line instead of taking a fresh nonce for the retry" do
      run_id = SecureRandom.uuid
      OrderedRetryStep::ATTEMPTS.delete(run_id)
      allow(RubyReactor::OrderedLock).to receive(:assign).and_call_original

      result = OrderedRetryReactor.run(run_id: run_id)

      expect(result).to be_a(RubyReactor::Success)
      expect(OrderedRetryStep::ATTEMPTS[run_id]).to eq(2)
      # A second `assign` would mean the first attempt advanced and dropped the
      # stash, sending the retry to the back of the queue behind executions
      # that arrived while it was failing.
      expect(RubyReactor::OrderedLock).to have_received(:assign).once
      expect("park_retry:#{run_id}").to have_ordered_lock_in_flight
    end
  end

  describe "an async_step's reactor-side argument validation" do
    it "rejects the arguments before the run is recorded and the lock is taken" do
      result = ValidatedAsyncReactor.run(amount: -5)
      RubyReactor::RSpec::AsyncTestHelpers.drain_async_jobs

      record = RubyReactor.configuration.storage_adapter.retrieve_step_result(
        result.execution_id, :charge, "ValidatedAsyncReactor"
      )
      expect(record["success"]).to be(false)
      expect(record["result"]["validation_errors"].keys.map(&:to_s)).to include("amount")

      # No `:run` entry means the rejection happened before the trace and
      # coordination boundary — the step never got as far as its lock.
      trace = ValidatedAsyncReactor.find(result.execution_id).context.execution_trace
      expect(trace.select { |e| e[:type].to_s == "run" && e[:step].to_s == "charge" }).to be_empty
      expect("park_validated:-5").not_to be_locked
    end
  end
end
