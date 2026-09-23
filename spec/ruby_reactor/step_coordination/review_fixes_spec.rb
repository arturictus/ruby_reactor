# frozen_string_literal: true

require "spec_helper"

# A step whose key reads an input the CONTRACT supplies: every site that
# computes the key (forward, rollback, the async dispatch guard, the
# dashboard) has to apply the defaults first or it computes a different key
# than the one actually held.
class DefaultedKeyStep < RubyReactor::Step
  input :account_id
  input :region, :string, optional: true, default: "eu"

  with_lock(wait: 0) { |args| "acct:#{args[:account_id]}:#{args[:region]}" }

  def run
    Success(region: inputs[:region])
  end
end

class DefaultedKeyReactor < RubyReactor::Reactor
  input :account_id

  step :charge, DefaultedKeyStep do
    argument :account_id, input(:account_id)
  end

  returns :charge
end

# Ordered lock plus a lock that will contend, run SYNCHRONOUSLY: there is no
# queue to park into, so the position must be handed back rather than left in
# flight for the poison_pill_timeout.
class SyncOrderedContendedStep < RubyReactor::Step
  input :run_id
  input :account_id

  with_ordered_lock { |args| "sync_seq:#{args[:run_id]}" }
  with_lock(wait: 0) { |args| "sync_seq_lock:#{args[:account_id]}" }

  def run
    Success(:charged)
  end
end

class SyncOrderedContendedReactor < RubyReactor::Reactor
  input :run_id
  input :account_id

  step :charge, SyncOrderedContendedStep do
    argument :run_id, input(:run_id)
    argument :account_id, input(:account_id)
  end

  returns :charge
end

# An `async_step` that parks on a semaphore held elsewhere — the shape
# StepSweeper must not mistake for a lost unit.
class SweepParkStep < RubyReactor::Step
  input :account_id

  with_semaphore(limit: 1, wait: 0) { |args| "sweep_park_sem:#{args[:account_id]}" }

  def run
    Success(:charged)
  end
end

class SweepParkReactor < RubyReactor::Reactor
  input :account_id

  async_step :charge, SweepParkStep do
    argument :account_id, input(:account_id)
  end

  step :ack do
    run { RubyReactor.Success(:dispatched) }
  end

  returns :ack
end

# Two primitives on ONE step: the dashboard has to show both gates, not just
# whichever `coordination_declarations` happens to yield first.
class TwoPrimitiveStep < RubyReactor::Step
  input :account_id

  with_lock(wait: 0) { |args| "two_prim_lock:#{args[:account_id]}" }
  with_semaphore(limit: 2, wait: 0) { |args| "two_prim_sem:#{args[:account_id]}" }

  def run
    Success(:charged)
  end
end

class TwoPrimitiveReactor < RubyReactor::Reactor
  input :account_id

  step :charge, TwoPrimitiveStep do
    argument :account_id, input(:account_id)
  end

  returns :charge
end

# An INLINE step with no `argument` wiring: its body (and its lock key) read
# the reactor's inputs, and so must its rollback — the undo stack only stores
# the empty resolved-arguments hash.
class InlineNoArgsRollbackReactor < RubyReactor::Reactor
  input :account_id

  step :charge do
    with_lock(wait: 0) { |args| "inline_rollback:#{args[:account_id]}" }
    run { RubyReactor.Success(:charged) }
    undo { RubyReactor.Success(:undone) }
  end

  step :boom do
    run { RubyReactor.Failure("boom") }
  end

  returns :boom
end

# A step-level `with_ordered_lock` whose body runs a nested `Reactor.run`
# ordered on the SAME key: a second nonce could never come up.
class NestedOrderedInnerStep < RubyReactor::Step
  input :run_id

  with_ordered_lock(poison_pill_timeout: 2) { |args| "nested_step_seq:#{args[:run_id]}" }

  def run
    Success(:inner)
  end
end

class NestedOrderedInnerReactor < RubyReactor::Reactor
  input :run_id

  step :inner, NestedOrderedInnerStep do
    argument :run_id, input(:run_id)
  end

  returns :inner
end

class NestedOrderedOuterReactor < RubyReactor::Reactor
  input :run_id

  step :outer do
    with_ordered_lock(poison_pill_timeout: 2) { |args| "nested_step_seq:#{args[:run_id]}" }
    run { |args| NestedOrderedInnerReactor.run(run_id: args[:run_id]) }
  end

  returns :outer
end

# The dispatch-time deadlock guard fires on :charge — an earlier step has
# already run its side effect, so the reactor must unwind it.
class DeadlockGuardChildStep < RubyReactor::Step
  input :account_id

  with_lock(wait: 0) { |args| "guard_acct:#{args[:account_id]}" }

  def run
    Success(:never)
  end
end

DEADLOCK_GUARD_UNDONE = [] # rubocop:disable Style/MutableConstant

class DeadlockGuardRollbackReactor < RubyReactor::Reactor
  with_lock(wait: 0) { |inputs| "guard_acct:#{inputs[:account_id]}" }

  input :account_id

  step :side_effect do
    run { RubyReactor.Success(:done) }
    undo do |_value, _args, _ctx|
      DEADLOCK_GUARD_UNDONE << :side_effect
      RubyReactor.Success(:undone)
    end
  end

  async_step :charge, DeadlockGuardChildStep do
    argument :account_id, input(:account_id)
    wait_for :side_effect
  end
end

# A locked class step dispatched to the worker: the hooks it fires there must
# be the configured middlewares, attributed to the step.
class WorkerHookStep < RubyReactor::Step
  input :account_id

  with_lock(wait: 0) { |args| "worker_hook:#{args[:account_id]}" }

  def run
    Success(:charged)
  end
end

class WorkerHookReactor < RubyReactor::Reactor
  input :account_id

  async_step :charge, WorkerHookStep do
    argument :account_id, input(:account_id)
  end

  step :ack do
    run { RubyReactor.Success(:dispatched) }
  end

  returns :ack
end

RSpec.describe "step coordination review fixes", :step_coordination do
  def capture_step_events
    events = []
    mw = Class.new do
      define_method(:on) do |event, *args|
        context = args.last
        current_step = context.respond_to?(:current_step) ? context.current_step : nil
        events << [event, args[0], current_step]
      end
    end.new
    [mw, events]
  end

  around do |example|
    original = RubyReactor.configuration.middlewares
    example.run
    RubyReactor.configuration.middlewares = original
  end

  def unique_account_id
    SecureRandom.random_number(10**9)
  end

  describe "the direct-invocation contract" do
    it "runs a coordinated step stand-alone, with no context argument" do
      result = DefaultedKeyStep.run(account_id: unique_account_id)

      expect(result).to be_a(RubyReactor::Success)
      expect(result.value).to eq(region: "eu")
    end

    it "releases the hold, so a second stand-alone call on the same key succeeds" do
      account_id = unique_account_id

      expect(DefaultedKeyStep.run(account_id: account_id)).to be_a(RubyReactor::Success)
      expect(DefaultedKeyStep.run(account_id: account_id)).to be_a(RubyReactor::Success)
    end
  end

  describe "RubyReactor::Web::CoordinationSerializer" do
    it "resolves the step's key from the contract-applied inputs, not the raw trace arguments" do
      account_id = unique_account_id
      context = RubyReactor::Context.new({ account_id: account_id }, DefaultedKeyReactor)
      expect(RubyReactor::Executor.new(DefaultedKeyReactor, {}, context).execute).to be_a(RubyReactor::Success)

      coordination = RubyReactor::Web::CoordinationSerializer.build(
        DefaultedKeyReactor, inputs: {}, context_id: context.context_id,
                             execution_trace: context.execution_trace, private_data: context.private_data
      )

      row = coordination[:steps].find { |s| s[:step] == "charge" }
      expect(row[:key]).to eq("acct:#{account_id}:eu")
    end

    it "renders a named step rate limit as its registered windows, keyed by the name" do
      RubyReactor.configuration.rate_limits.register(:step_coordination_named_limit, limit: 1, period: :minute)
      account_id = unique_account_id
      context = RubyReactor::Context.new({ account_id: account_id }, StepNamedRateLimitedReactor)
      expect(RubyReactor::Executor.new(StepNamedRateLimitedReactor, {}, context).execute)
        .to be_a(RubyReactor::Success)

      coordination = RubyReactor::Web::CoordinationSerializer.build(
        StepNamedRateLimitedReactor, inputs: {}, context_id: context.context_id,
                                     execution_trace: context.execution_trace, private_data: context.private_data
      )

      row = coordination[:steps].find { |s| s[:step] == "charge" }
      expect(row[:key]).to eq("step_coordination_named_limit")
      expect(row[:key_error]).to be_nil
      expect(row[:state].map { |w| w[:name].to_s }).to eq(["minute"])
    end
  end

  describe "synchronous contention" do
    it "records no park markers — there is no queue to park into, the step just fails" do
      account_id = unique_account_id
      key = "acct:#{account_id}"
      holder = RubyReactor::Lock.new(key, owner: "external-holder", ttl: 5, wait: 0, auto_extend: true)
      holder.acquire

      context = RubyReactor::Context.new(
        { run_id: step_coord_run_id, account_id: account_id }, WaitZeroLockedChargeReactor
      )
      result = RubyReactor::Executor.new(WaitZeroLockedChargeReactor, {}, context).execute

      expect(result).to be_a(RubyReactor::Failure)
      expect(context.execution_trace.map { |e| e[:type].to_s }).not_to include("contention_park")
      expect(context.private_data[:step_contention]).to be_nil
    ensure
      holder&.release
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

  describe "an async_step parked on contention" do
    it "is not re-dispatched by StepSweeper while its redelivery is still due" do
      account_id = unique_account_id
      holder = RubyReactor::Semaphore.new("sweep_park_sem:#{account_id}", limit: 1)
      holder.acquire

      dispatch = SweepParkReactor.run(account_id: account_id)
      # Perform the unit exactly once: it parks and reschedules itself, which
      # releases the liveness lock and leaves the record at "dispatched".
      job = RubyReactor::Adapters::Sidekiq::StepWorker.jobs.last
      RubyReactor::Adapters::Sidekiq::StepWorker.jobs.clear
      RubyReactor::Adapters::Sidekiq::StepWorker.new.perform(*job["args"])

      # A re-dispatch here would run the body a second time when the parked
      # redelivery fires — the two are sequential, so the liveness lock never
      # sees them collide.
      expect(RubyReactor::StepSweeper.run_once).to eq(0)

      record = RubyReactor.configuration.storage_adapter.retrieve_step_result(
        dispatch.execution_id, :charge, "SweepParkReactor"
      )
      expect(record["status"]).to eq("dispatched")
      expect(Time.iso8601(record["parked_until"])).to be > Time.now
    ensure
      holder&.release
    end
  end

  describe "RubyReactor::Web::CoordinationSerializer with several primitives on one step" do
    it "renders a row per declaration, so neither gate is invisible" do
      account_id = unique_account_id
      context = RubyReactor::Context.new({ account_id: account_id }, TwoPrimitiveReactor)
      expect(RubyReactor::Executor.new(TwoPrimitiveReactor, {}, context).execute).to be_a(RubyReactor::Success)

      coordination = RubyReactor::Web::CoordinationSerializer.build(
        TwoPrimitiveReactor, inputs: {}, context_id: context.context_id,
                             execution_trace: context.execution_trace, private_data: context.private_data
      )

      rows = coordination[:steps].select { |s| s[:step] == "charge" }
      expect(rows.map { |r| r[:primitive] }).to contain_exactly("lock", "semaphore")
      expect(rows.map { |r| r[:key] })
        .to contain_exactly("two_prim_lock:#{account_id}", "two_prim_sem:#{account_id}")
    end
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

  describe "the async_step dispatch deadlock guard" do
    it "unwinds the steps that already ran instead of failing without compensation" do
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

  describe "StepWorker running a coordinated class step" do
    it "fires the configured coordination hooks, attributed to the step" do
      mw, events = capture_step_events
      RubyReactor.configuration.middlewares = [mw]
      account_id = unique_account_id

      WorkerHookReactor.run(account_id: account_id)
      job = RubyReactor::Adapters::Sidekiq::StepWorker.jobs.last
      RubyReactor::Adapters::Sidekiq::StepWorker.jobs.clear
      events.clear
      RubyReactor::Adapters::Sidekiq::StepWorker.new.perform(*job["args"])

      lock_events = events.select { |event, *| %i[lock_acquired lock_released].include?(event) }
      # The worker's context is rehydrated and carries no middlewares, so an
      # empty-runner fallback would leave this silent.
      expect(lock_events.map { |event, *| event }).to contain_exactly(:lock_acquired, :lock_released)
      lock_events.each do |_event, key, current_step|
        expect(key).to eq("worker_hook:#{account_id}")
        expect(current_step.to_s).to eq("charge")
      end
    end
  end
end
