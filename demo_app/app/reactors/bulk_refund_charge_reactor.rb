# frozen_string_literal: true

# One payment of BulkRefundDemoReactor: charge it. Its `undo` would refund it
# alone, but the map declares `undo_all`, which refunds every charge in one
# call instead, so this undo never runs there (010 US7).
class BulkRefundChargeStep < RubyReactor::Step
  input :payment_id, :string
  input :amount_cents, :integer

  def run
    Success(id: "ch_#{inputs.payment_id}", amount_cents: inputs.amount_cents)
  end

  def undo
    BulkRefundDemoReactor.record(:single_refunds, inputs.payment_id)
    Success()
  end
end

class BulkRefundChargeReactor < RubyReactor::Reactor
  input :payment_id, :string
  input :amount_cents, :integer

  step :charge, BulkRefundChargeStep do
    argument :payment_id, input(:payment_id)
    argument :amount_cents, input(:amount_cents)
  end

  returns :charge
end
