# frozen_string_literal: true

require "spec_helper"

# A reactor-run step is coordinated at ONE site (`StepCoordination.run_step`),
# over its EFFECTIVE declarations — inline and class alike — with ONE argument
# derivation (`StepConfig#coordination_arguments`) shared by forward execution,
# rollback, the async dispatch guard and the dashboard (research D2).

SITE_COUNTS = Hash.new(0)

# Lock on the class, semaphore inline: two declaration sites, one step.
class SiteClassLockStep < RubyReactor::Step
  input :account_id

  with_lock(wait: 0) { |args| "site_lock:#{args[:account_id]}" }

  def run
    Success(:charged)
  end
end

class SiteMixedReactor < RubyReactor::Reactor
  input :account_id

  step :charge, SiteClassLockStep do
    argument :account_id, input(:account_id)
    with_semaphore(limit: 1, wait: 0) { |args| "site_sem:#{args[:account_id]}" }
  end

  returns :charge
end

# The dedup window on the CLASS, the output contract on the REACTOR's step.
class SitePeriodStep < RubyReactor::Step
  input :account_id

  with_period(every: :hour) { |args| "site_period:#{args[:account_id]}" }

  def run
    SITE_COUNTS[:period_body] += 1
    Success("not an integer")
  end
end

class SitePeriodReactor < RubyReactor::Reactor
  input :account_id

  step :charge, SitePeriodStep do
    argument :account_id, input(:account_id)
    validate_output :integer
  end

  returns :charge
end

class SiteNestedInnerStep < RubyReactor::Step
  input :account_id

  with_lock(wait: 0) { |args| "site_nested_inner:#{args[:account_id]}" }

  def run
    Success(:inner)
  end
end

# An async_step whose body has a side effect and THEN calls a class step
# directly on a key someone else holds.
class SiteNestedAsyncReactor < RubyReactor::Reactor
  input :account_id

  async_step :outer do
    argument :account_id, input(:account_id)
    run do |args, ctx|
      SITE_COUNTS[:outer_body] += 1
      SiteNestedInnerStep.run({ account_id: args[:account_id] }, ctx)
    end
  end

  step :ack do
    run { RubyReactor.Success(:dispatched) }
  end

  returns :ack
end

# An inline async_step with NO argument wiring keys off the reactor's inputs —
# the same key the reactor itself holds.
class SiteGuardReactor < RubyReactor::Reactor
  with_lock(ttl: 60, wait: 0) { |inputs| "site_guard:#{inputs[:account_id]}" }

  input :account_id

  async_step :charge do
    with_lock(wait: 0) { |args| "site_guard:#{args[:account_id]}" }
    run { RubyReactor.Success(:charged) }
  end

  step :ack do
    run { RubyReactor.Success(:dispatched) }
  end

  returns :ack
end

# An unregistered named rate limit on an async_step that has retries: a
# configuration error, which must not be retried in the worker.
class SiteUnknownLimitAsyncReactor < RubyReactor::Reactor
  input :account_id

  async_step :charge do
    with_rate_limit(:site_never_registered)
    retries max_attempts: 3, backoff: :linear, base_delay: 0.01
    run do
      SITE_COUNTS[:unknown_limit_body] += 1
      RubyReactor.Success(:charged)
    end
  end

  step :ack do
    run { RubyReactor.Success(:dispatched) }
  end

  returns :ack
end

class SiteDashboardReactor < RubyReactor::Reactor
  input :account_id

  step :charge do
    with_lock(wait: 0) { |args| "site_dash:#{args[:account_id]}" }
    run { RubyReactor.Success(:charged) }
  end

  returns :charge
end

RSpec.describe "step coordination at a single site", :step_coordination do
  def unique_account_id
    SecureRandom.random_number(10**9)
  end

  before { SITE_COUNTS.clear }

  around do |example|
    original = RubyReactor.configuration.middlewares
    example.run
    RubyReactor.configuration.middlewares = original
  end

  describe "a step mixing a class declaration with an inline one" do
    # Split across two layers, the inline semaphore would wrap the class lock
    # (semaphore -> lock) while other steps take lock -> semaphore: two
    # executions could each hold one and wait on the other.
    it "takes both in the one documented order — lock before semaphore — each exactly once" do
      events = []
      RubyReactor.configuration.middlewares = [
        Class.new { define_method(:on) { |event, *args| events << [event, args[0]] } }.new
      ]
      account_id = unique_account_id

      expect(SiteMixedReactor.run(account_id: account_id)).to be_a(RubyReactor::Success)

      coordination = events.select { |event, _| event.to_s.start_with?("lock_", "semaphore_") }
      expect(coordination).to eq(
        [[:lock_acquired, "site_lock:#{account_id}"], [:semaphore_acquired, "site_sem:#{account_id}"],
         [:semaphore_released, "site_sem:#{account_id}"], [:lock_released, "site_lock:#{account_id}"]]
      )
    end
  end

  describe "a class step's declarations under the reactor's output contract" do
    it "leaves the class's period bucket unmarked when the reactor rejects the output" do
      account_id = unique_account_id

      2.times { expect(SitePeriodReactor.run(account_id: account_id)).to be_a(RubyReactor::Failure) }

      expect(SITE_COUNTS[:period_body]).to eq(2)
    end
  end

  describe "a nested direct class-step call that contends inside an async_step worker" do
    it "fails the unit instead of parking it to re-run the body's side effect" do
      account_id = unique_account_id
      holder = RubyReactor::Lock.new("site_nested_inner:#{account_id}", owner: "external", ttl: 30, wait: 0,
                                                                        auto_extend: false)
      holder.acquire

      dispatch = SiteNestedAsyncReactor.run(account_id: account_id)
      job = RubyReactor::Adapters::Sidekiq::StepWorker.jobs.last
      RubyReactor::Adapters::Sidekiq::StepWorker.jobs.clear
      RubyReactor::Adapters::Sidekiq::StepWorker.new.perform(*job["args"])

      expect(RubyReactor::Adapters::Sidekiq::StepWorker.jobs).to be_empty
      record = RubyReactor.configuration.storage_adapter.retrieve_step_result(
        dispatch.execution_id, :outer, "SiteNestedAsyncReactor"
      )
      expect(record["status"]).to eq("completed")
      expect(record["success"]).to be(false)
      expect(SITE_COUNTS[:outer_body]).to eq(1)
    ensure
      holder&.release
    end
  end

  describe "the async_step dispatch guard on an inline step with no argument wiring" do
    it "resolves the key from the reactor inputs, as the worker will, and refuses the self-deadlock" do
      account_id = unique_account_id

      result = SiteGuardReactor.run(account_id: account_id)

      expect(result).to be_a(RubyReactor::Failure)
      expect(result.error.to_s).to include("would deadlock", "site_guard:#{account_id}")
    end
  end

  describe "an unregistered named rate limit on an async_step with retries" do
    it "fails the unit once, non-retryably, as the in-process path does — the body never runs" do
      allow(RubyReactor.configuration.rate_limits).to receive(:fetch).and_call_original

      dispatch = SiteUnknownLimitAsyncReactor.run(account_id: unique_account_id)
      job = RubyReactor::Adapters::Sidekiq::StepWorker.jobs.last
      RubyReactor::Adapters::Sidekiq::StepWorker.jobs.clear
      RubyReactor::Adapters::Sidekiq::StepWorker.new.perform(*job["args"])

      record = RubyReactor.configuration.storage_adapter.retrieve_step_result(
        dispatch.execution_id, :charge, "SiteUnknownLimitAsyncReactor"
      )
      expect(record["success"]).to be(false)
      expect(RubyReactor.configuration.rate_limits).to have_received(:fetch).once
      expect(SITE_COUNTS[:unknown_limit_body]).to eq(0)
    end
  end

  describe "RubyReactor::Web::CoordinationSerializer" do
    def rows_for(reactor_class, context)
      RubyReactor::Web::CoordinationSerializer.build(
        reactor_class, inputs: context.inputs, context_id: context.context_id,
                       execution_trace: context.execution_trace, private_data: context.private_data
      )[:steps]
    end

    it "keys an inline step with no argument wiring off the reactor inputs, as execution did" do
      account_id = unique_account_id
      context = RubyReactor::Context.new({ account_id: account_id }, SiteDashboardReactor)
      expect(RubyReactor::Executor.new(SiteDashboardReactor, {}, context).execute).to be_a(RubyReactor::Success)

      row = rows_for(SiteDashboardReactor, context).find { |r| r[:step] == "charge" }
      expect(row[:key]).to eq("site_dash:#{account_id}")
    end

    it "reports a key built from redacted arguments as unavailable instead of probing the wrong key" do
      trace = [{ type: :run, step: :charge, arguments: { account_id: RubyReactor::Step::InputContract::REDACTED } }]

      rows = RubyReactor::Web::CoordinationSerializer.build(
        SiteDashboardReactor, inputs: {}, context_id: "irrelevant", execution_trace: trace, private_data: {}
      )[:steps]

      expect(rows).to eq([{ step: "charge", primitive: "lock", key: nil,
                            key_error: "key unavailable: the step's arguments are redacted" }])
    end
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
end
