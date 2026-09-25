# frozen_string_literal: true

require "spec_helper"

# US5: a class policy follows the step on every execution path, and attempts
# carry across requeues (FR-011, FR-012). Constant-named: a worker rehydrates
# reactors by class name.
module StepRetriesPathsLog
  class << self
    attr_accessor :attempts, :undone, :fail_times

    def reset!(fail_times: 99)
      self.attempts = 0
      self.undone = []
      self.fail_times = fail_times
    end
  end
end

class StepRetriesPathsChargeStep < RubyReactor::Step
  retries max_attempts: 3, backoff: :fixed, base_delay: 0

  def run
    StepRetriesPathsLog.attempts += 1
    StepRetriesPathsLog.attempts > StepRetriesPathsLog.fail_times ? Success(:charged) : Failure("declined")
  end
end

class StepRetriesPathsReserveStep < RubyReactor::Step
  def run = Success(:reserved)

  def undo
    StepRetriesPathsLog.undone << :reserve
    Success()
  end
end

class StepRetriesPathsAllReactor < RubyReactor::Reactor
  background all: true

  step :reserve, StepRetriesPathsReserveStep
  step(:charge, StepRetriesPathsChargeStep) { wait_for :reserve }

  returns :charge
end

class StepRetriesPathsAfterReactor < RubyReactor::Reactor
  step :reserve, StepRetriesPathsReserveStep
  step(:charge, StepRetriesPathsChargeStep) { wait_for :reserve }

  background after: :reserve
  returns :charge
end

class StepRetriesPathsAsyncStepReactor < RubyReactor::Reactor
  async_step :charge, StepRetriesPathsChargeStep
end

class StepRetriesPathsInterruptReactor < RubyReactor::Reactor
  step :reserve, StepRetriesPathsReserveStep

  interrupt :approve do
    wait_for :reserve
  end

  step(:charge, StepRetriesPathsChargeStep) { wait_for :approve }

  returns :charge
end

RSpec.describe "Step retries: the class policy on every execution path" do
  def drain
    RubyReactor::RSpec::AsyncTestHelpers.drain_async_jobs
  end

  def stored_context(reactor_class, result)
    reactor_class.find(result.execution_id).context
  end

  for_each_async_backend do
    it "exhausts the policy in a background worker, then rolls back (background all: true)" do
      StepRetriesPathsLog.reset!
      result = StepRetriesPathsAllReactor.run({})
      drain

      context = stored_context(StepRetriesPathsAllReactor, result)
      expect(context.status.to_s).to eq("failed")
      expect(StepRetriesPathsLog.attempts).to eq(3)
      expect(StepRetriesPathsLog.undone).to eq([:reserve])
    end

    it "keeps the attempt count across requeues until success (background all: true)" do
      StepRetriesPathsLog.reset!(fail_times: 2)
      result = StepRetriesPathsAllReactor.run({})
      drain

      context = stored_context(StepRetriesPathsAllReactor, result)
      expect(context.status.to_s).to eq("completed")
      expect(context.retry_context.attempts_for_step(:charge)).to eq(3)
      expect(StepRetriesPathsLog.attempts).to eq(3)
    end

    it "applies the same policy after a mid-workflow hand-off (background after:)" do
      StepRetriesPathsLog.reset!
      result = StepRetriesPathsAfterReactor.run({})
      drain

      expect(stored_context(StepRetriesPathsAfterReactor, result).status.to_s).to eq("failed")
      expect(StepRetriesPathsLog.attempts).to eq(3)
      expect(StepRetriesPathsLog.undone).to eq([:reserve])
    end

    it "honors the class policy inside the async_step worker" do
      StepRetriesPathsLog.reset!
      result = StepRetriesPathsAsyncStepReactor.run({})
      drain

      record = RubyReactor.configuration.storage_adapter.retrieve_step_result(
        result.execution_id, :charge, "StepRetriesPathsAsyncStepReactor"
      )
      expect(record["success"]).to be false
      expect(StepRetriesPathsLog.attempts).to eq(3)
    end
  end

  it "applies the class policy to a step reached after an interrupt resumes" do
    StepRetriesPathsLog.reset!
    paused = StepRetriesPathsInterruptReactor.run({})
    expect(paused).to be_a(RubyReactor::InterruptResult)
    expect(StepRetriesPathsLog.attempts).to eq(0)

    result = StepRetriesPathsInterruptReactor.continue(id: paused.execution_id, payload: {}, step_name: :approve)

    expect(result).to be_failure
    expect(StepRetriesPathsLog.attempts).to eq(3)
  end
end
