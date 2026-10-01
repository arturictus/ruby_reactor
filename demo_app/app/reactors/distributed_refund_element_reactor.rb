# frozen_string_literal: true

# One order of DistributedRefundDemoReactor: charge it, and refund it as its
# undo. The fan-out map runs each element in its own job, and rolls each one
# back in its own job too (009 US1).
class DistributedRefundChargeStep < RubyReactor::Step
  input :order_id, :string
  input :amount_cents, :integer

  def run
    DistributedRefundDemoReactor.record(:charges, inputs.order_id)
    Success(charge_id: "ch_#{inputs.order_id}", amount_cents: inputs.amount_cents)
  end

  # Idempotent in a real system (refund by charge id): a worker killed in the
  # middle of this undo makes it run again on redelivery (009 FR-006).
  def undo
    DistributedRefundDemoReactor.record(:refunds, inputs.order_id)
    Success()
  end
end

class DistributedRefundElementReactor < RubyReactor::Reactor
  input :order_id, :string
  input :amount_cents, :integer

  step :charge, DistributedRefundChargeStep do
    argument :order_id, input(:order_id)
    argument :amount_cents, input(:amount_cents)
  end

  returns :charge
end
