# frozen_string_literal: true

require "spec_helper"

# US4 (F-04): an async_step unit compensates itself once, in its own job,
# after its final attempt fails. An inline `undo` on async_step is rejected.
module AsyncStepCompensateSpec
  def self.events
    @events ||= []
  end

  # Middleware recording the rollback and lock events the unit's job fires.
  class Events
    def on(event, *args)
      return unless %i[start_compensation complete_compensation lock_acquired].include?(event)

      AsyncStepCompensateSpec.events << [event, args.first]
    end
  end

  class AlwaysFails < RollbackRecorder::Reactor
    middleware Events
    recording_step(:u, kind: :async_step, fail: true) { retries max_attempts: 3, base_delay: 0 }
  end

  class FailsOnce < RollbackRecorder::Reactor
    recording_step(:u, kind: :async_step, fail: 1) { retries max_attempts: 2, base_delay: 0 }
  end

  class WithReader < RollbackRecorder::Reactor
    background all: true
    recording_step :a
    recording_step :u, kind: :async_step, after: :a, fail: true
    recording_step(:r, after: :u) do
      argument :outcome, result(:u)
      run do |inputs, _ctx|
        RollbackRecorder.record("run:r")
        inputs.outcome.is_a?(RubyReactor::Failure) ? RubyReactor.Failure(inputs.outcome.error) : RubyReactor.Success()
      end
    end
  end

  class InvalidArguments < RollbackRecorder::Reactor
    recording_step(:u, kind: :async_step) do
      inputs { input :count, :integer }
      argument :count, value("not a number")
    end
  end

  class TransformRaises < RollbackRecorder::Reactor
    recording_step(:u, kind: :async_step) { argument :x, value(1), transform: ->(_v) { raise "bad transform" } }
  end

  class Halts < RollbackRecorder::Reactor
    recording_step(:u, kind: :async_step) { run { |_inputs, _ctx| RubyReactor.Halt(reason: "nothing to do") } }
  end

  class CompensateRaises < RollbackRecorder::Reactor
    recording_step :u, kind: :async_step, fail: true, compensate_raises: true
  end

  class LockedUnit < RubyReactor::Step
    with_lock { |_args| "async_step_compensate:unit" }

    def run
      RollbackRecorder.record("run:u")
      Failure("boom u")
    end

    def compensate
      RollbackRecorder.record("compensate:u")
      Success()
    end
  end

  class Locked < RollbackRecorder::Reactor
    middleware Events
    async_step :u, LockedUnit
  end

  class UnitWithUndo < RubyReactor::Step
    def run = Success()
    def undo = Success()
  end
end

RSpec.describe "async_step unit-local compensate" do
  let(:storage) { RubyReactor.configuration.storage_adapter }

  before { AsyncStepCompensateSpec.events.clear }

  def drain
    RubyReactor::RSpec::AsyncTestHelpers.drain_async_jobs
  end

  def record(reactor_class, id)
    storage.retrieve_step_result(id, :u, reactor_class.name)
  end

  def perform_jobs_ending_with(suffix)
    RubyReactor::RSpec::AsyncTestHelpers.pending_async_jobs.each do |job|
      klass = job.respond_to?(:worker_class) ? job.worker_class : job.job_class
      job.perform! if klass.name.end_with?(suffix)
    end
  end

  for_each_async_backend do
    it "compensates once, after the last attempt (S-async-07)" do
      id = AsyncStepCompensateSpec::AlwaysFails.run({}).execution_id
      drain

      expect(RollbackRecorder.log).to eq(%w[run:u run:u run:u compensate:u])
      expect(record(AsyncStepCompensateSpec::AlwaysFails, id)["compensation"]["status"]).to eq("completed")
    end

    it "never compensates an attempt that is retried into success" do
      id = AsyncStepCompensateSpec::FailsOnce.run({}).execution_id
      drain

      expect(RollbackRecorder.log).to eq(%w[run:u run:u])
      expect(record(AsyncStepCompensateSpec::FailsOnce, id)).not_to have_key("compensation")
    end

    it "compensates the unit once, then the reader, then undoes the parent (S-async-02)" do
      stub_const("RubyReactor::Template::Result::PARK_GRACE", 0.1)
      AsyncStepCompensateSpec::WithReader.run({})

      perform_jobs_ending_with("::Worker")     # runs :a, dispatches :u, parks on :r
      perform_jobs_ending_with("StepWorker")   # :u fails and compensates itself
      perform_jobs_ending_with("::Worker")     # :r reads the failure

      expect(RollbackRecorder.log).to eq(%w[run:a run:u compensate:u run:r compensate:r undo:a])
    end

    it "never compensates a unit whose arguments are invalid or fail to resolve" do
      AsyncStepCompensateSpec::InvalidArguments.run({})
      AsyncStepCompensateSpec::TransformRaises.run({})
      drain

      expect(RollbackRecorder.log).not_to include("compensate:u")
    end

    it "never compensates a unit that halts" do
      id = AsyncStepCompensateSpec::Halts.run({}).execution_id
      drain

      expect(RollbackRecorder.log).not_to include("compensate:u")
      expect(record(AsyncStepCompensateSpec::Halts, id)).not_to have_key("compensation")
    end

    it "records a compensation that raised, keeping the body's failure as the result" do
      id = AsyncStepCompensateSpec::CompensateRaises.run({}).execution_id
      drain

      unit = record(AsyncStepCompensateSpec::CompensateRaises, id)
      expect(unit["compensation"]["status"]).to eq("failed")
      expect(unit["compensation"]["rollback_failures"].size).to eq(1)
      expect(RubyReactor::Failure.new(RubyReactor::ContextSerializer.deserialize_value(unit["result"])).error)
        .to eq("boom u")
    end

    it "re-takes the unit's own lock around its compensate" do
      AsyncStepCompensateSpec::Locked.run({})
      drain

      events = AsyncStepCompensateSpec.events.map(&:first)
      start = events.index(:start_compensation)
      expect(events[start..]).to eq(%i[start_compensation lock_acquired complete_compensation])
    end

    it "never writes the parent's context" do
      id = AsyncStepCompensateSpec::AlwaysFails.run({}).execution_id
      parent = storage.retrieve_context(id, AsyncStepCompensateSpec::AlwaysFails.name)
      drain

      expect(RollbackRecorder.log).to include("compensate:u")
      expect(storage.retrieve_context(id, AsyncStepCompensateSpec::AlwaysFails.name)).to eq(parent)
    end

    it "fires the compensation middleware events for the unit" do
      AsyncStepCompensateSpec::AlwaysFails.run({})
      drain

      expect(AsyncStepCompensateSpec.events).to eq([%i[start_compensation u], %i[complete_compensation u]])
    end
  end

  describe "at definition time" do
    it "rejects an inline `undo`" do
      expect do
        Class.new(RubyReactor::Reactor) do
          async_step(:u) do
            run { RubyReactor.Success() }
            undo { RubyReactor.Success() }
          end
        end
      end.to raise_error(RubyReactor::Error::ValidationError, /async_step :u.*compensate/m)
    end

    it "warns, once, that a step class's `undo` will not run" do
      expect do
        Class.new(RubyReactor::Reactor) { async_step :u, AsyncStepCompensateSpec::UnitWithUndo }
      end.to output(/undo.*will not run/).to_stderr
    end
  end
end
