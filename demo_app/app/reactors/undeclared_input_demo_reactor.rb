# frozen_string_literal: true

# Demonstrates reading step inputs by method (`inputs.order_guid`). A typo'd
# name raises `RubyReactor::Error::UndeclaredInputError` on the line that reads
# it, instead of returning nil and failing somewhere else. `mode` picks where
# the typo is: "ok" (none), "typo_in_run" or "typo_in_compensate".
class UndeclaredInputDemoLog
  class << self
    attr_accessor :validate_attempts, :released

    def reset!
      @validate_attempts = 0
      @released = false
    end
  end

  reset!
end

class HoldSeatStep < RubyReactor::Step
  def run = Success(held: true)

  def undo
    UndeclaredInputDemoLog.released = true
    Success()
  end
end

class ValidateOrderGuidStep < RubyReactor::Step
  input :order_guid, :integer
  input :mode, :string

  # A typo fails the same way on every attempt, so this policy never kicks in.
  retries max_attempts: 3, backoff: :fixed, base_delay: 0.05

  def run
    UndeclaredInputDemoLog.validate_attempts += 1
    # `order_id` was never declared: it raises here rather than returning nil.
    guid = inputs.mode == "typo_in_run" ? inputs.order_id : inputs.order_guid
    Success(order_guid: guid)
  end
end

class ChargeOrderStep < RubyReactor::Step
  input :order_guid, :integer
  input :mode, :string

  def run
    return Failure("card declined") if inputs.mode == "typo_in_compensate"

    Success(charged: inputs.order_guid)
  end

  # Rollback skips input validation, so this typo used to be a silent nil.
  def compensate = Success(voided: inputs.order_id)
end

class UndeclaredInputDemoReactor < RubyReactor::Reactor
  input :order_guid, :integer
  input :mode, :string

  step :hold_seat, HoldSeatStep

  step :validate_order, ValidateOrderGuidStep do
    wait_for :hold_seat
  end

  step :charge, ChargeOrderStep do
    wait_for :validate_order
  end

  returns :charge
end
