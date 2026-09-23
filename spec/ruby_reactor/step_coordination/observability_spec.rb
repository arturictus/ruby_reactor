# frozen_string_literal: true

require "spec_helper"

# US7: step holds and parks are visible in events, logs, the execution trace,
# and the dashboard, attributed to the step — never as a phantom failure.
RSpec.describe "step-scoped coordination observability", :step_coordination do
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

  # `context` is a mutable, shared object whose `current_step` reverts once
  # `with_step`'s `ensure` runs — snapshotting it at event time (not later,
  # after the run has finished) is the only way to observe what it was WHEN
  # the event fired. Each captured row is `[event, key, current_step]`.
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

  describe "lock and semaphore events (FR-028, US7-3)" do
    it "attributes :lock_acquired / :lock_released to the current step" do
      mw, events = capture_step_events
      RubyReactor.configuration.middlewares = [mw]

      result = LockedChargeReactor.run(run_id: step_coord_run_id, account_id: unique_id)
      expect(result).to be_a(RubyReactor::Success)

      lock_events = events.select { |event, *| %i[lock_acquired lock_released].include?(event) }
      expect(lock_events).not_to be_empty
      lock_events.each { |_event, _key, current_step| expect(current_step.to_s).to eq("charge") }
    end

    it "attributes :lock_failed to the current step" do
      mw, events = capture_step_events
      RubyReactor.configuration.middlewares = [mw]

      account_id = unique_id
      key = "acct:#{account_id}"
      holder = RubyReactor::Lock.new(key, owner: "external-holder", ttl: 5, wait: 0, auto_extend: true)
      holder.acquire

      result = WaitZeroLockedChargeReactor.run(run_id: step_coord_run_id, account_id: account_id)
      expect(result).to be_a(RubyReactor::Failure)

      failed_events = events.select { |event, *| event == :lock_failed }
      expect(failed_events.size).to eq(1)
      _event, key_arg, current_step = failed_events.first
      expect(key_arg).to eq(key)
      expect(current_step.to_s).to eq("charge")
    ensure
      holder&.release
    end

    it "attributes :semaphore_acquired / :semaphore_released to the current step" do
      mw, events = capture_step_events
      RubyReactor.configuration.middlewares = [mw]

      result = StepSemaphoreReactor.run(run_id: step_coord_run_id, resource_id: unique_id, sleep_for: 0.05)
      expect(result).to be_a(RubyReactor::Success)

      sem_events = events.select { |event, *| %i[semaphore_acquired semaphore_released].include?(event) }
      expect(sem_events).not_to be_empty
      sem_events.each { |_event, _key, current_step| expect(current_step.to_s).to eq("charge") }
    end

    it "attributes :semaphore_failed to the current step" do
      mw, events = capture_step_events
      RubyReactor.configuration.middlewares = [mw]

      resource_id = unique_id
      key = "sem:#{resource_id}"
      holders = Array.new(2) { RubyReactor::Semaphore.new(key, limit: 2, wait: 0) }
      holders.each(&:acquire)

      result = StepSemaphoreReactor.run(run_id: step_coord_run_id, resource_id: resource_id, sleep_for: 0.05)
      expect(result).to be_a(RubyReactor::Failure)

      failed_events = events.select { |event, *| event == :semaphore_failed }
      expect(failed_events.size).to eq(1)
      _event, key_arg, current_step = failed_events.first
      expect(key_arg).to eq(key)
      expect(current_step.to_s).to eq("charge")
    ensure
      holders&.each(&:release)
    end
  end

  describe "a contention park (US7-4)" do
    # Drives the worker-side park path in-process (no live Sidekiq needed):
    # `inline_async_execution` is the only thing that distinguishes it from a
    # sync run, and `Sidekiq::Testing.fake!` (the spec default) enqueues the
    # requeue without executing it.
    def run_parked(reactor_class, inputs)
      context = RubyReactor::Context.new(inputs, reactor_class)
      context.inline_async_execution = true
      executor = RubyReactor::Executor.new(reactor_class, {}, context)
      [executor.execute, context]
    end

    it "logs a structured parked line, marks the context waiting (not failed), and never emits " \
       ":failed_step (constitution IV, US7-4)" do
      account_id = unique_id
      key = "acct:#{account_id}"
      holder = RubyReactor::Lock.new(key, owner: "external-holder", ttl: 5, wait: 0, auto_extend: true)
      holder.acquire

      mw, events = capture_middleware
      RubyReactor.configuration.middlewares = [mw]

      io = StringIO.new
      original_logger = RubyReactor.configuration.logger
      RubyReactor.configuration.logger = Logger.new(io)

      result, context = run_parked(WaitZeroLockedChargeReactor, run_id: step_coord_run_id, account_id: account_id)

      RubyReactor.configuration.logger = original_logger
      holder.release

      expect(result).to be_a(RubyReactor::RetryQueuedResult)

      line = io.string.lines.find { |l| l.include?("step_coordination.parked") }
      expect(line).not_to be_nil
      expect(line).to include('event="ruby_reactor.step_coordination.parked"')
      expect(line).to include("reactor=")
      expect(line).to include("step=:charge")
      expect(line).to include(%(key="#{key}"))
      expect(line).to include("primitive=:lock")
      expect(line).to include("attempt=1")
      expect(line).to include("execution_id=")

      expect(context.status.to_s).not_to eq("failed")
      waiting = context.private_data[:step_contention]
      expect(waiting).to include(step: :charge, primitive: :lock, key: key)

      expect(events.map(&:first)).not_to include(:failed_step)
    end
  end

  describe "RubyReactor::Web::CoordinationSerializer (US7-1, US7-2, SC-010)" do
    it "includes a step row with primitive/key/state once the step has run" do
      account_id = unique_id
      context = RubyReactor::Context.new({ run_id: step_coord_run_id, account_id: account_id }, LockedChargeReactor)
      executor = RubyReactor::Executor.new(LockedChargeReactor, {}, context)
      result = executor.execute
      expect(result).to be_a(RubyReactor::Success)

      coordination = RubyReactor::Web::CoordinationSerializer.build(
        LockedChargeReactor, inputs: {}, context_id: context.context_id,
                             execution_trace: context.execution_trace,
                             private_data: context.private_data
      )

      row = coordination[:steps]&.find { |s| s[:step] == "charge" }
      expect(row).not_to be_nil
      expect(row[:primitive]).to eq("lock")
      expect(row[:key]).to eq("acct:#{account_id}")
      expect(row[:state]).to be_a(Hash)
    end

    it "reports a not-yet-reached step as pending" do
      coordination = RubyReactor::Web::CoordinationSerializer.build(
        LockedChargeReactor, inputs: {}, context_id: "irrelevant", execution_trace: [], private_data: {}
      )

      # One pending row PER declared primitive, matching the reached shape —
      # a step with several gates has several rows to wait on.
      row = coordination[:steps]&.find { |s| s[:step] == "charge" }
      expect(row).to eq(step: "charge", primitive: "lock", state: "pending")
    end

    it "includes waiting: for a parked context, naming step/key/primitive" do
      private_data = {
        step_contention: { step: :charge, primitive: :lock, key: "acct:1", attempts: 2, next_attempt_at: nil }
      }

      coordination = RubyReactor::Web::CoordinationSerializer.build(
        LockedChargeReactor, inputs: {}, context_id: "irrelevant", execution_trace: [],
                             private_data: private_data
      )

      expect(coordination[:waiting]).to eq(
        step: "charge", key: "acct:1", primitive: "lock", attempts: 2, next_attempt_at: nil
      )
    end
  end

  describe "the sync contention Failure (US7-2)" do
    it "carries the reactor, step, and key in step_name/reactor_name/message" do
      account_id = unique_id
      key = "acct:#{account_id}"
      holder = RubyReactor::Lock.new(key, owner: "external-holder", ttl: 5, wait: 0, auto_extend: true)
      holder.acquire

      result = WaitZeroLockedChargeReactor.run(run_id: step_coord_run_id, account_id: account_id)

      expect(result).to be_a(RubyReactor::Failure)
      expect(result.step_name.to_s).to eq("charge")
      expect(result.reactor_name).to eq("WaitZeroLockedChargeReactor")
      expect(result.message).to include("charge").and include(key)
    ensure
      holder&.release
    end
  end
end
