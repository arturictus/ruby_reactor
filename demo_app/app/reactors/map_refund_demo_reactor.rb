# frozen_string_literal: true

# Demonstrates map rollback: a map charges a list of orders, one element per
# order. Each element's :charge step declares `undo` (a refund), and that undo
# IS the element's rollback — the map declares nothing extra.
#
#   - an order's charge fails -> the orders already charged are refunded;
#   - every order is charged, then :notify fails -> every order is refunded.
#
# Log helpers live on the reactor: Zeitwerk only autoloads the constant
# matching this file's name.
class MapRefundChargeStep < RubyReactor::Step
  input :order_id, :string
  input :amount_cents, :integer
  input :fail_order_id, optional: true

  def run
    return Failure("card declined for #{inputs.order_id}") if inputs.order_id == inputs.fail_order_id

    MapRefundDemoReactor.charges << inputs.order_id
    Success(charge_id: "ch_#{inputs.order_id}", amount_cents: inputs.amount_cents)
  end

  # Idempotent in a real system (refund by charge id): an element undo can run
  # on the map's own failure, on a later failure, or on a manual undo.
  def undo
    MapRefundDemoReactor.refunds << inputs.order_id
    Success()
  end
end

class MapRefundElementReactor < RubyReactor::Reactor
  input :order_id, :string
  input :amount_cents, :integer
  input :fail_order_id, optional: true

  step :charge, MapRefundChargeStep do
    argument :order_id, input(:order_id)
    argument :amount_cents, input(:amount_cents)
    argument :fail_order_id, input(:fail_order_id)
  end

  returns :charge
end

class MapRefundNotifyStep < RubyReactor::Step
  input :fail, optional: true

  def run
    return Failure("notification service unavailable") if inputs.fail

    Success(:notified)
  end
end

class MapRefundDemoReactor < RubyReactor::Reactor
  class << self
    def charges
      @charges ||= []
    end

    def refunds
      @refunds ||= []
    end

    def reset!
      @charges = []
      @refunds = []
    end
  end

  input :orders
  input :fail_order_id, optional: true
  input :fail_after_map, optional: true

  map :charge_orders, MapRefundElementReactor do
    source input(:orders)
    argument :order_id, element(:charge_orders, :id)
    argument :amount_cents, element(:charge_orders, :amount_cents)
    argument :fail_order_id, input(:fail_order_id)
  end

  step :notify, MapRefundNotifyStep do
    argument :fail, input(:fail_after_map)
    wait_for :charge_orders
  end
end
