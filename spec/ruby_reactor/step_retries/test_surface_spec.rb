# frozen_string_literal: true

require "spec_helper"

# US7 / FR-015: the shipped test surface exercises class policies — a mock
# keeps the step's class, so its policy still applies.
class StepRetriesSurfaceChargeStep < RubyReactor::Step
  retries max_attempts: 3, backoff: :fixed, base_delay: 0

  def run = Success(:charged)
end

class StepRetriesSurfaceReactor < RubyReactor::Reactor
  step :charge, StepRetriesSurfaceChargeStep
  returns :charge
end

RSpec.describe "Step retries: the RSpec test surface", type: :reactor do
  it "retries a class step forced to fail by failing_at under the class policy" do
    subject = test_reactor(StepRetriesSurfaceReactor, {}).failing_at(:charge)

    expect(subject).to be_failure
    expect(subject).to have_retried_step(:charge).times(2)
  end

  it "retries a mocked class step under the class policy" do
    subject = test_reactor(StepRetriesSurfaceReactor, {}).mock_step(:charge) do |_args, ctx|
      ctx.retry_context.attempts_for_step(:charge) < 2 ? RubyReactor.Failure("x") : RubyReactor.Success(1)
    end

    expect(subject).to be_success
    expect(subject).to have_retried_step(:charge).times(1)
  end
end
