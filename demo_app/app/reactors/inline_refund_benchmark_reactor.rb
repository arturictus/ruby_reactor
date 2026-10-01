# frozen_string_literal: true

# The SC-002 baseline for `demo:map_rollback_benchmark`: DistributedRefundDemoReactor
# with an inline map, so its rollback is the serial, in-process one — every
# element undone one after another in the process that saw the failure.
class InlineRefundBenchmarkReactor < RubyReactor::Reactor
  input :count, optional: true
  input :fail_notify, optional: true

  step :load_orders, DistributedRefundDemoReactor::LoadOrdersStep do
    argument :count, input(:count)
  end

  map :charge_orders, DistributedRefundElementReactor do
    source result(:load_orders)
    argument :order_id, element(:charge_orders, :id)
    argument :amount_cents, element(:charge_orders, :amount_cents)
  end

  step :notify, DistributedRefundDemoReactor::NotifyStep do
    argument :fail, input(:fail_notify)
    wait_for :charge_orders
  end
end
