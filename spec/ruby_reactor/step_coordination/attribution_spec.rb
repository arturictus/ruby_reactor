# frozen_string_literal: true

require "spec_helper"

# US5 (005 quickstart R5, P5): `context.coordinating_step` is THE attribution
# for a coordination event — `nil` for a reactor-level hold, the step for a
# step-level one — on every run, including a redelivery after a park. A step
# class invoked directly names itself, not the step whose body called it.
RSpec.describe "coordination attribution", :step_coordination do
  let(:run_id) { step_coord_run_id }
  let(:account_id) { SecureRandom.random_number(10**9) }
  let(:events) { [] }

  around do |example|
    original = RubyReactor.configuration.middlewares
    recorded = events
    RubyReactor.configuration.middlewares = [
      Class.new do
        define_method(:on) do |event, *args|
          context = args.last
          recorded << [event, args.first, context.respond_to?(:coordinating_step) ? context.coordinating_step : nil]
        end
      end.new
    ]
    example.run
  ensure
    RubyReactor.configuration.middlewares = original
  end

  def hold(key)
    RubyReactor::Lock.new(key, owner: "external-holder", ttl: 30, auto_extend: false).tap(&:acquire)
  end

  def perform_once
    worker = RubyReactor::Adapters::Sidekiq::Worker
    job = worker.jobs.last
    worker.jobs.clear
    worker.new.perform(*job["args"])
  end

  # The reactor-level `:lock_released` reports the storage key ("lock:<key>"),
  # every other lock event the declared key — match either.
  def coordination_events(key)
    events.select { |event, arg, _| event.to_s.start_with?("lock_") && [key, "lock:#{key}"].include?(arg) }
  end

  it "names the step for step-level events and nothing for reactor-level ones, across a park (R5)" do
    holder = hold("attr:s:#{account_id}")
    AttrReactor.run(run_id: run_id, account_id: account_id)
    perform_once
    holder.release
    perform_once

    reactor_events = coordination_events("attr:r:#{run_id}")
    step_events = coordination_events("attr:s:#{account_id}")
    expect(reactor_events.map(&:first)).to include(:lock_acquired, :lock_released)
    expect(reactor_events.map(&:last)).to all(be_nil)
    expect(step_events.map(&:first)).to include(:lock_failed, :lock_acquired, :lock_released)
    expect(step_events.map { |*, step| step.to_s }).to all(eq("charge"))
  end

  it "names a directly invoked step class, not the step whose body called it (P5)" do
    holder = hold("attr:s:#{account_id}")

    result = AttrDirectOuterReactor.run(account_id: account_id)

    expect(result).to be_a(RubyReactor::Failure)
    expect(result.error.to_s).to include("step :AttrChargeStep could not acquire lock 'attr:s:#{account_id}'")
    failed = coordination_events("attr:s:#{account_id}").find { |event, *| event == :lock_failed }
    expect(failed.last.to_s).to eq("AttrChargeStep")
  ensure
    holder&.release
  end

  describe "a nested direct class-step call that contends inside a worker" do
    # The contention belongs to the nested call, not to :outer's own
    # acquisition: :outer's body already ran, so parking it would re-run that
    # side effect on redelivery, and treating it as "never started" would
    # skip its compensation.
    it "fails the outer step as an ordinary failure — compensated, never parked" do
      account_id = unique_account_id
      NestedMarkerReactor.side_effects.clear
      holder = RubyReactor::Semaphore.new("nested_marker_sem:#{account_id}", limit: 1)
      holder.acquire

      context = RubyReactor::Context.new({ account_id: account_id }, NestedMarkerReactor)
      context.inline_async_execution = true

      result = RubyReactor::Executor.new(NestedMarkerReactor, {}, context).execute

      expect(result).to be_a(RubyReactor::Failure)
      expect(result.exception_class).to eq("RubyReactor::Executor::StepCoordination::NestedCoordinationError")
      expect(NestedMarkerReactor.side_effects).to eq(%i[outer_ran outer_compensated])
      expect(context.private_data[:step_contention]).to be_nil
      adapter = RubyReactor.configuration.storage_adapter
      expect(adapter.lock_held?("nested_marker_outer:#{account_id}")).to be(false)
      expect(adapter.lock_held?("nested_marker_inner:#{account_id}")).to be(false)
    ensure
      holder&.release
    end
  end
end
