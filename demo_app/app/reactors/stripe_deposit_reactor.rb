# frozen_string_literal: true

# A payment-provider deposit on its own queue (011). Wherever it is composed,
# its steps run in a job on :demo_stripe — and are undone there — so the
# provider's worker capacity is isolated from the order pipeline that uses it.
class StripeDepositReactor < RubyReactor::Reactor
  class ChargeStep < RubyReactor::Step
    input :amount

    def run
      Success("ch_#{inputs.amount}")
    end

    # Refund the charge.
    def undo
      Success("refunded")
    end
  end

  class SettleStep < RubyReactor::Step
    input :charge

    def run
      Success("settled #{inputs.charge}")
    end

    # Reverse the settlement.
    def undo
      Success("reversed")
    end
  end

  queue :demo_stripe

  input :amount
  input :order, optional: true

  step :charge, ChargeStep do
    argument :amount, input(:amount)
  end

  step :settle, SettleStep do
    argument :charge, result(:charge)
  end

  returns :settle
end
