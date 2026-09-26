# frozen_string_literal: true

# Demonstrates rollback on a failure outside any step body: :reserve succeeds,
# then :charge's argument `transform:` raises on a price it cannot parse.
#
#   - :reserve is undone (the seat is released);
#   - :charge is NOT compensated: its body never started;
#   - the failure names :charge, with the original error's class.
#
# Log helpers live on the reactor: Zeitwerk only autoloads the constant
# matching this file's name.
class ArgumentFailureReserveStep < RubyReactor::Step
  input :sku, :string

  def run
    ArgumentFailureDemoReactor.log << "reserve #{inputs.sku}"
    Success(reservation_id: "res_#{inputs.sku}")
  end

  def undo
    ArgumentFailureDemoReactor.log << "release #{inputs.sku}"
    Success()
  end
end

class ArgumentFailureChargeStep < RubyReactor::Step
  input :amount_cents, :integer

  def run
    ArgumentFailureDemoReactor.log << "charge #{inputs.amount_cents}"
    Success(charged_cents: inputs.amount_cents)
  end

  def compensate
    ArgumentFailureDemoReactor.log << "compensate charge"
    Success()
  end
end

class ArgumentFailureDemoReactor < RubyReactor::Reactor
  # `Float("abc")` raises ArgumentError.
  PRICE_TO_CENTS = ->(price) { (Float(price) * 100).round }

  def self.log
    @log ||= []
  end

  def self.reset!
    @log = []
  end

  input :sku, :string
  input :price, :string

  step :reserve, ArgumentFailureReserveStep do
    argument :sku, input(:sku)
  end

  step :charge, ArgumentFailureChargeStep do
    argument :amount_cents, input(:price), transform: PRICE_TO_CENTS
    wait_for :reserve
  end
end
