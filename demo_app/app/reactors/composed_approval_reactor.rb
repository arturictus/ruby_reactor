# frozen_string_literal: true

# An interrupt inside a composed child (010): :approval composes
# ManagerApprovalReactor, whose :wait_for_manager pauses this whole run.
#
# - Resume it by the step path from here, [:approval, :wait_for_manager], by
#   id or by the child interrupt's correlation id, on this class.
# - A rejection fails :confirm_reservation inside the child: the stock is
#   released, then the card refunded.
# - Undoing the run while it waits does the same, and cancels it.
class ComposedApprovalReactor < RubyReactor::Reactor
  APPROVAL = %i[approval wait_for_manager].freeze

  class << self
    def record(event)
      log << event
    end

    def log
      @log ||= []
    end

    def reset!
      log.clear
    end
  end

  class ChargeCardStep < RubyReactor::Step
    input :order_id

    def run
      Success("charge-#{inputs.order_id}")
    end

    def undo
      ComposedApprovalReactor.record(:refunded)
      Success()
    end
  end

  class ShipStep < RubyReactor::Step
    def run
      Success(:shipped)
    end
  end

  input :order_id

  step :charge_card, ChargeCardStep do
    argument :order_id, input(:order_id)
  end

  compose :approval, ManagerApprovalReactor do
    argument :order_id, input(:order_id)
    argument :charge_id, result(:charge_card)
  end

  step :ship, ShipStep do
    wait_for :approval
  end
end
