# frozen_string_literal: true

module Support
  class PaymentWorkflow < RubyReactor::Reactor
    input :order_id do
      required(:order_id).filled(:string)
    end

    input :fail_at, optional: true do
      optional(:fail_at).maybe(:symbol)
    end

    step :get_order do
      argument :order_id, input(:order_id)
      argument :fail_at, input(:fail_at)
      run do |args, _context|
        if args[:fail_at] == :get_order
          # Handle compensation logic
          Failure("Failure triggered for get_order")
        else
          Success({ id: args[:order_id], amount: 100.0, currency: "USD" })
        end
      end

      undo do |error, context|
        puts "Undo get_order due to error: #{error}"
        # Simulate compensation logic
        Success("Compensated for order #{context[:order_id]}")
      end
    end

    step :reserve_inventory do
      argument :order, result(:get_order)
      argument :fail_at, input(:fail_at)
      run do |args, _context|
        if args[:fail_at] == :reserve_inventory
          Failure({ error: "Failure triggered for reserve_inventory", order_id: args[:order][:id],
                    errors: ["blabla"] })
        else
          # Simulate inventory reservation
          Success({ id: args[:order][:id], status: "pending", inventory_count: 5, reserved: true })
        end
      end
    end

    step :authorize_payment do
      argument :order, result(:get_order)
      argument :inventory, result(:reserve_inventory)
      argument :fail_at, input(:fail_at)
      run do |args, _context|
        if args[:fail_at] == :authorize_payment
          Failure("Failure triggered for authorize_payment")
        else
          # Simulate payment authorization
          Success({ id: args[:order][:id], status: "authorized", amount: args[:order][:amount] })
        end
      end

      # Undo will only trigger on the backwalk if one of the next steps failed
      undo do |error, context|
        puts "Undo authorize_payment due to error: #{error}"
        # Simulate compensation logic
        Success("Undo payment authorization for order #{context[:order][:id]}")
      end

      compensate do |reason, args, _context|
        puts "Compensation for authorize_payment due to reason: #{reason}, args: #{args.inspect}"
        Success("Compensation failed for authorize_payment")
      end
    end

    step :capture_payment do
      argument :payment, result(:authorize_payment)
      argument :fail_at, input(:fail_at)
      run do |args, _context|
        raise "Simulated failure in capture_payment" if args[:fail_at] == :capture_payment

        # Simulate payment capture
        Success({ id: args[:payment][:id], status: "captured", amount: args[:payment][:amount] })
      end

      compensate do |error, args, _context|
        puts "Compensation for capture_payment due to error: #{error}, args: #{args.inspect}"
        Success("Compensation succeeded for capture_payment for error: #{error}")
      end
    end

    step :fulfill_order do
      argument :payment, result(:authorize_payment)
      argument :fail_at, input(:fail_at)
      run do |args, _context|
        if args[:fail_at] == :fulfill_order
          Failure("Failed to fulfill_order")
        else
          Success({ id: "fulfill_order", status: "done" })
        end
      end

      compensate do |error, args, _context|
        puts "Compensation for fulfill_order due to error: #{error}, args: #{args.inspect}"
        Success("Compensation succeeded for fulfill_order for error: #{error}")
      end
    end
  end
end
