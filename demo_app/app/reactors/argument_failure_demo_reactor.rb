# frozen_string_literal: true

# Demonstrates that every exception after a completed step rolls back:
#
#   price "abc": :charge's argument `transform:` raises (ArgumentError), so its
#     body never starts: :reserve is undone, :charge is NOT compensated.
#   sku "legacy": :charge's body raises NotImplementedError, which is not a
#     StandardError: it is still :charge's failure, so :charge is compensated
#     and :reserve is undone.
#
# Either way the failure names :charge, with the original error's class.
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
  input :sku, :string
  input :amount_cents, :integer

  def run
    raise NotImplementedError, "legacy gateway" if inputs.sku == "legacy"

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
    argument :sku, input(:sku)
    argument :amount_cents, input(:price), transform: PRICE_TO_CENTS
    wait_for :reserve
  end
end
