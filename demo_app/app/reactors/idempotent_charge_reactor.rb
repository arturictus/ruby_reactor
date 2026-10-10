# frozen_string_literal: true

# Run-level idempotency keys (specs/011 US6): charging an order with
# `idempotency_key: "charge-order-<id>"` runs once; a retried request (a double
# click, a redelivered webhook) gets the original result back and charges
# nothing. A declined card fails :charge, :reserve is undone, and a retry with
# the same key replays that failure instead of trying again.
class IdempotentChargeReactor < RubyReactor::Reactor
  # What actually happened, so the demo can show nothing ran twice.
  module Ledger
    @entries = []
    @lock = Mutex.new

    def self.record(entry) = @lock.synchronize { @entries << entry }
    def self.entries = @lock.synchronize { @entries.dup }
    def self.reset! = @lock.synchronize { @entries.clear }
  end

  class ReserveStep < RubyReactor::Step
    input :order_id
    input :amount

    def run
      Ledger.record([:reserved, inputs.order_id, inputs.amount])
      Success(reserved: inputs.amount)
    end

    # Rolls the reservation back when a later step (:charge) fails.
    def undo
      Ledger.record([:released, inputs.order_id, inputs.amount])
      Success()
    end
  end

  class ChargeStep < RubyReactor::Step
    input :order_id
    input :amount
    input :decline, optional: true

    def run
      return Failure("card declined for order #{inputs.order_id}") if inputs.decline

      Ledger.record([:charged, inputs.order_id, inputs.amount])
      Success(charged: inputs.amount, order_id: inputs.order_id)
    end

    # Cleans up after :charge itself fails.
    def compensate
      Ledger.record([:charge_voided, inputs.order_id, inputs.amount])
      Success()
    end
  end

  input :order_id
  input :amount
  input :decline, optional: true

  step :reserve, ReserveStep do
    argument :order_id, input(:order_id)
    argument :amount, input(:amount)
  end

  step :charge, ChargeStep do
    argument :order_id, input(:order_id)
    argument :amount, input(:amount)
    argument :decline, input(:decline)
    wait_for :reserve
  end

  returns :charge
end
