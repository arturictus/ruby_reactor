# frozen_string_literal: true

require "spec_helper"

# A class-backed step whose coordination is declared INLINE, on the reactor's
# step block: `Step.run` can only see the step class's own config, so the
# executor/worker is the only place this declaration can be acquired.
class InlineOverrideImplStep < RubyReactor::Step
  input :account_id

  def run
    Success(:charged)
  end
end

class InlineOverrideReactor < RubyReactor::Reactor
  input :account_id

  step :charge, InlineOverrideImplStep do
    argument :account_id, input(:account_id)
    with_lock(wait: 0) { |args| "inline_override:#{args[:account_id]}" }
  end

  returns :charge
end

class InlineOverrideAsyncReactor < RubyReactor::Reactor
  input :account_id

  async_step :charge, InlineOverrideImplStep do
    argument :account_id, input(:account_id)
    with_lock(wait: 0) { |args| "inline_override_async:#{args[:account_id]}" }
  end

  step :ack do
    run { RubyReactor.Success(:dispatched) }
  end

  returns :ack
end

# Flipped between dispatch and delivery, so the worker is the one deciding
# the guard — the executor already decided it the other way.
ASYNC_GUARD_FLAG = { run: true } # rubocop:disable Style/MutableConstant

class GuardedAsyncStep < RubyReactor::Step
  input :account_id

  with_lock(wait: 0) { |args| "guarded_async:#{args[:account_id]}" }

  def run
    Success(:charged)
  end
end

class GuardedAsyncReactor < RubyReactor::Reactor
  input :account_id

  async_step :charge, GuardedAsyncStep do
    argument :account_id, input(:account_id)
    where { ASYNC_GUARD_FLAG[:run] }
  end

  step :ack do
    run { RubyReactor.Success(:dispatched) }
  end

  returns :ack
end

# Reactor-level lock PLUS a step-level lock that will contend: the park hands
# the reactor's hold to a redelivery, and the contention ceiling then cancels
# that redelivery.
class CeilingStep < RubyReactor::Step
  input :account_id

  with_lock(wait: 0) { |args| "ceiling_step:#{args[:account_id]}" }

  def run
    Success(:charged)
  end
end

class CeilingReactor < RubyReactor::Reactor
  with_lock(ttl: 60, wait: 0) { |inputs| "ceiling_reactor:#{inputs[:account_id]}" }

  input :account_id

  step :charge, CeilingStep do
    argument :account_id, input(:account_id)
  end

  returns :charge
end

# An `async_step` inside a COMPOSED child: its Step Result Record belongs to
# the child's namespace, which is what the reader looks under.
class ComposedAsyncChildStep < RubyReactor::Step
  input :account_id

  def run
    Success(:child_charged)
  end
end

class ComposedAsyncChildReactor < RubyReactor::Reactor
  input :account_id

  async_step :charge, ComposedAsyncChildStep do
    argument :account_id, input(:account_id)
  end

  step :ack do
    run { RubyReactor.Success(:dispatched) }
  end

  returns :ack
end

class ComposedAsyncParentReactor < RubyReactor::Reactor
  input :account_id

  compose :child, ComposedAsyncChildReactor do
    argument :account_id, input(:account_id)
  end

  returns :child
end

# A direct `InnerStep.run(args, context)` nested inside a coordinated outer
# step: both scopes share `context.current_step`, so their parked markers must
# still be told apart.
class NestedMarkerInnerStep < RubyReactor::Step
  input :account_id

  with_lock(wait: 0) { |args| "nested_marker_inner:#{args[:account_id]}" }
  with_semaphore(limit: 1, wait: 0) { |args| "nested_marker_sem:#{args[:account_id]}" }

  def run
    Success(:inner)
  end
end

class NestedMarkerReactor < RubyReactor::Reactor
  input :account_id

  step :outer do
    argument :account_id, input(:account_id)
    with_lock(wait: 0) { |args| "nested_marker_outer:#{args[:account_id]}" }
    run { |args, ctx| NestedMarkerInnerStep.run({ account_id: args[:account_id] }, ctx) }
  end

  returns :outer
end

RSpec.describe "step coordination review fixes (round 3)", :step_coordination do
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

  def perform_last_step_job
    job = RubyReactor::Adapters::Sidekiq::StepWorker.jobs.last
    RubyReactor::Adapters::Sidekiq::StepWorker.jobs.clear
    RubyReactor::Adapters::Sidekiq::StepWorker.new.perform(*job["args"])
  end

  describe "a coordination declaration made inline on a class-backed step" do
    it "is acquired by the executor, which is the only site that can see it" do
      mw, events = capture_step_events
      RubyReactor.configuration.middlewares = [mw]
      account_id = unique_account_id

      expect(InlineOverrideReactor.run(account_id: account_id)).to be_a(RubyReactor::Success)

      keys = events.select { |event, *| event == :lock_acquired }.map { |_e, key, _s| key }
      expect(keys).to eq(["inline_override:#{account_id}"])
    end

    it "is acquired by the async_step worker too" do
      mw, events = capture_step_events
      RubyReactor.configuration.middlewares = [mw]
      account_id = unique_account_id

      InlineOverrideAsyncReactor.run(account_id: account_id)
      events.clear
      perform_last_step_job

      keys = events.select { |event, *| event == :lock_acquired }.map { |_e, key, _s| key }
      expect(keys).to eq(["inline_override_async:#{account_id}"])
    end
  end

  describe "an async_step suppressed by its guard" do
    it "takes no coordination in the worker" do
      mw, events = capture_step_events
      RubyReactor.configuration.middlewares = [mw]
      account_id = unique_account_id

      ASYNC_GUARD_FLAG[:run] = true
      GuardedAsyncReactor.run(account_id: account_id)
      ASYNC_GUARD_FLAG[:run] = false
      events.clear
      perform_last_step_job

      expect(events.select { |event, *| event == :lock_acquired }).to be_empty
      # The key is free, so nothing is still holding it.
      probe = RubyReactor::Lock.new("guarded_async:#{account_id}", owner: "probe", ttl: 5, wait: 0,
                                                                   auto_extend: false)
      expect { probe.acquire }.not_to raise_error
      probe.release
    ensure
      ASYNC_GUARD_FLAG[:run] = true
    end
  end

  describe "a contention park escalated to a terminal failure by the ceiling" do
    it "hands back the reactor-level hold instead of leaving it parked until its TTL" do
      config = RubyReactor.configuration
      original_max = config.lock_snooze_max_attempts
      config.lock_snooze_max_attempts = 1
      account_id = unique_account_id
      holder = RubyReactor::Lock.new("ceiling_step:#{account_id}", owner: "external-holder", ttl: 60, wait: 0,
                                                                   auto_extend: true)
      holder.acquire

      context = RubyReactor::Context.new({ account_id: account_id }, CeilingReactor)
      context.inline_async_execution = true

      expect(RubyReactor::Executor.new(CeilingReactor, {}, context).execute)
        .to be_a(RubyReactor::RetryQueuedResult)
      expect(context.private_data[:parked_primitives]).to eq({ lock: true })

      # A fresh executor, as the redelivered job builds: it re-adopts the
      # parked hold, then the ceiling turns this park terminal.
      expect(RubyReactor::Executor.new(CeilingReactor, {}, context).resume_execution)
        .to be_a(RubyReactor::Failure)
      expect(context.private_data[:parked_primitives]).to be_nil
      # Nothing is coming back for it, so the reactor's own key must be free.
      probe = RubyReactor::Lock.new("ceiling_reactor:#{account_id}", owner: "probe", ttl: 5, wait: 0,
                                                                     auto_extend: false)
      expect { probe.acquire }.not_to raise_error
      probe.release
    ensure
      holder&.release
      config.lock_snooze_max_attempts = original_max
    end
  end

  describe "an async_step inside a composed child" do
    it "writes its Step Result Record under the child's namespace, where the reader looks" do
      account_id = unique_account_id

      ComposedAsyncParentReactor.run(account_id: account_id)
      job = RubyReactor::Adapters::Sidekiq::StepWorker.jobs.last
      step_context_id = job["args"].first["step_context_id"] || job["args"].first[:step_context_id]
      perform_last_step_job

      storage = RubyReactor.configuration.storage_adapter
      record = storage.retrieve_step_result(step_context_id, :charge, "ComposedAsyncChildReactor")
      expect(record["status"]).to eq("completed")
      expect(record["success"]).to be(true)
    end
  end

  describe "a nested direct class-step invocation parked with the outer step" do
    it "keeps its own parked marker instead of being overwritten by the outer scope's" do
      account_id = unique_account_id
      holder = RubyReactor::Semaphore.new("nested_marker_sem:#{account_id}", limit: 1)
      holder.acquire

      context = RubyReactor::Context.new({ account_id: account_id }, NestedMarkerReactor)
      context.inline_async_execution = true

      expect(RubyReactor::Executor.new(NestedMarkerReactor, {}, context).execute)
        .to be_a(RubyReactor::RetryQueuedResult)

      parked = context.private_data[:step_parked_locks]
      # Two holds are detached across the park; one marker means the inner
      # lock is re-acquired on redelivery and released only once.
      expect(parked.values.map { |info| info[:key] })
        .to contain_exactly("nested_marker_outer:#{account_id}", "nested_marker_inner:#{account_id}")
    ensure
      holder&.release
    end
  end
end
