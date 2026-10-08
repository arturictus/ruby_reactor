# frozen_string_literal: true

# The child ComposedApprovalReactor composes: reserve stock, wait for a
# manager's decision, then confirm. Its interrupt pauses the whole root run,
# which is resumed by the path [:approval, :wait_for_manager] (010). It is
# never resumed as a run of its own.
class ManagerApprovalReactor < RubyReactor::Reactor
  class ReserveStockStep < RubyReactor::Step
    input :order_id
    input :charge_id

    def run
      Success("stock-#{inputs.order_id}-for-#{inputs.charge_id}")
    end

    def undo
      ComposedApprovalReactor.record(:released)
      Success()
    end
  end

  class ConfirmReservationStep < RubyReactor::Step
    input :decision

    def run
      return Failure("manager rejected the order") unless inputs.decision[:approved]

      Success(:confirmed)
    end
  end

  input :order_id
  input :charge_id

  step :reserve_stock, ReserveStockStep do
    argument :order_id, input(:order_id)
    argument :charge_id, input(:charge_id)
  end

  interrupt :wait_for_manager do
    wait_for :reserve_stock
    correlation_id { |context| "approval-#{context.inputs[:order_id]}" }
    validate_payload do
      required(:approved).filled(:bool)
    end
  end

  step :confirm_reservation, ConfirmReservationStep do
    argument :decision, result(:wait_for_manager)
  end
end
