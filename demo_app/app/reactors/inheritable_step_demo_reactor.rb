# frozen_string_literal: true

# A brownfield service with no RubyReactor dependency at all — the thing a
# step class wraps rather than rewrites (spec User Story 3).
class LegacyChargeService
  Result = Struct.new(:success?, :id, :error)

  def initialize(user_id)
    @user_id = user_id
  end

  def call
    Result.new(true, 42, nil)
  end
end

# The adapter: SC-004 requires this body to be <= 10 lines.
class ChargeStep < RubyReactor::Step
  input :user_id, :integer, gt?: 0

  def self.refunds
    @refunds ||= []
  end

  def run
    outcome = LegacyChargeService.new(inputs[:user_id]).call
    outcome.success? ? Success(charge_id: outcome.id) : Failure(outcome.error)
  end

  def undo
    self.class.refunds << result[:charge_id]
    Success("refunded charge #{result[:charge_id]}")
  end
end

# Forces a rollback on demand, to prove ChargeStep#undo runs.
class ForceFailStep < RubyReactor::Step
  def run
    fail!("forced failure to demonstrate rollback") if inputs[:fail]

    Success(:ok)
  end
end

class InheritableStepDemoReactor < RubyReactor::Reactor
  input :user_id
  input :fail, optional: true

  step :charge, ChargeStep do
    argument :user_id, input(:user_id)
  end

  step :maybe_fail, ForceFailStep do
    argument :fail, input(:fail)
    wait_for :charge
  end

  returns :charge
end
