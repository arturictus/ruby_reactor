# frozen_string_literal: true

module Support
  class OrderProcessingReactor < RubyReactor::Reactor
    input :order_id do
      required(:order_id).filled(:string)
    end

    input :fail_at, optional: true do
      optional(:fail_at).maybe(:symbol)
    end

    input :success_at_retry, optional: true do
      optional(:success_at_retry).maybe(:integer, gt?: 0)
    end

    input :product_id do
      required(:product_id).filled(:string)
    end

    input :quantity do
      required(:quantity).filled(:integer, gt?: 0)
    end

    input :amount do
      required(:amount).filled(:integer, gt?: 0.0)
    end
    retry_defaults max_attempts: 5, backoff: :fixed, base_delay: 2

    step :validate_order do
      argument :order_id, input(:order_id)
      argument :fail_at, input(:fail_at)
      run do |args, _context|
        if args[:fail_at] == :validate_order
          Failure("Failure triggered for validate_order")
        else
          Success({ id: args[:order_id], amount: 100.0, currency: "USD" })
        end
      end

      compensate do |_reason, _args, _context|
        Success("Compensation failed for validate_order")
      end

      undo do |_error, context|
        # Simulate compensation logic
        Success("Compensated for order #{context[:order_id]}")
      end
    end

    step :check_inventory do
      argument :product_id, input(:product_id)
      argument :quantity, input(:quantity)
      argument :fail_at, input(:fail_at)
      argument :success_at_retry, input(:success_at_retry)
      run do |args, context|
        if args[:fail_at] == :check_inventory &&
           (args[:success_at_retry].nil? || context.retry_context.attempts_for_step(:check_inventory) < args[:success_at_retry])
          Failure("Failure triggered for check_inventory")
        else
          # Simulate inventory check
          Success({ product_id: args[:product_id], available: true, requested_quantity: args[:quantity] })
        end
      end

      undo do |_error, context|
        # Simulate compensation logic
        Success("Compensated inventory check for product #{context[:product_id]}")
      end

      compensate do |_reason, _args, _context|
        Success("Compensation failed for check_inventory")
      end
    end

    step :reserve_inventory do
      argument :inventory, result(:check_inventory)
      argument :fail_at, input(:fail_at)
      argument :success_at_retry, input(:success_at_retry)
      run do |args, context|
        if args[:fail_at] == :reserve_inventory && (args[:success_at_retry].nil? || context.retry_context.attempts_for_step(:reserve_inventory) < args[:success_at_retry])
          Failure("Failure triggered for reserve_inventory")
        else
          # Simulate inventory reservation
          Success({ product_id: args[:inventory][:product_id], status: "reserved",
                    quantity: args[:inventory][:requested_quantity] })
        end
      end

      undo do |_error, context|
        # Simulate compensation logic
        Success("Released reserved inventory for product #{context[:inventory][:product_id]}")
      end

      compensate do |_reason, _args, _context|
        Success("Compensation failed for reserve_inventory")
      end
    end

    step :process_payment do
      argument :order, result(:validate_order)
      argument :amount, input(:amount)
      argument :fail_at, input(:fail_at)
      argument :inventory, result(:reserve_inventory)

      run do |args, _context|
        if args[:fail_at] == :process_payment
          Failure("Failure triggered for process_payment")
        else
          # Simulate payment processing
          Success({ order_id: args[:order][:id], status: "paid", amount: args[:amount] })
        end
      end

      undo do |_error, context|
        # Simulate compensation logic
        Success("Refunded payment for order #{context[:order][:id]}")
      end
    end
  end
end
