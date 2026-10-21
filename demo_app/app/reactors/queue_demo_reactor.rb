# frozen_string_literal: true

# Per-reactor and per-step queues (011). The order pipeline runs on
# :demo_orders; the deposit it composes runs on :demo_stripe; the receipt
# email is an async_step on :demo_emails.
#
#   caller:            :reserve ─ hand-off ─▶ :demo_orders   :price
#                      ─ hop ─▶ :demo_stripe   deposit (:charge, :settle)
#                      ─ hop ─▶ :demo_orders   :confirm, dispatches :email ─▶ :demo_emails
#
# With `fail_at_confirm: true`, :confirm is compensated on :demo_orders, the
# deposit is undone on :demo_stripe, and :price and :reserve on :demo_orders —
# the rollback hops back through the same queues. A manual
# `QueueDemoReactor.undo(id)` is handed to a worker and hops the same way.
class QueueDemoReactor < RubyReactor::Reactor
  class ReserveOrderStep < RubyReactor::Step
    input :amount

    def run
      Success("order-#{inputs.amount}")
    end

    # Release the reservation.
    def undo
      Success("released")
    end
  end

  class PriceOrderStep < RubyReactor::Step
    input :order

    def run
      Success(amount_cents: 4200, order: inputs.order)
    end

    def undo
      Success("price voided")
    end
  end

  class ConfirmOrderStep < RubyReactor::Step
    input :deposit
    input :fail, optional: true

    def run
      inputs.fail ? Failure("confirmation rejected") : Success(:confirmed)
    end

    def compensate
      Success("confirmation withdrawn")
    end

    def undo
      Success("confirmation cancelled")
    end
  end

  class QueueEmailStep < RubyReactor::Step
    queue :demo_emails
    input :order

    def run
      Success("receipt sent for #{inputs.order}")
    end
  end

  queue :demo_orders

  input :amount
  input :fail_at_confirm, optional: true

  step :reserve, ReserveOrderStep do
    argument :amount, input(:amount)
  end

  step :price, PriceOrderStep do
    argument :order, result(:reserve)
  end

  compose :deposit, StripeDepositReactor do
    argument :amount, input(:amount)
    argument :order, result(:price)
  end

  step :confirm, ConfirmOrderStep do
    argument :deposit, result(:deposit)
    argument :fail, input(:fail_at_confirm)
  end

  async_step :email, QueueEmailStep do
    argument :order, result(:reserve)
    wait_for :confirm
  end

  background after: :reserve
  returns :confirm
end
