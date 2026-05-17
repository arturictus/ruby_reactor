# frozen_string_literal: true

class ReserveInventory
  include RubyReactor::Step

  def self.run(arguments, _context)
    order = arguments[:order]
    fail_at = arguments[:fail_at]

    if fail_at == :reserve_inventory
      Failure({
                error: "Failure triggered for reserve_inventory",
                order_id: order[:id],
                errors: ["blabla"]
              })
    else
      # Simulate inventory reservation
      Success({
                id: order[:id],
                status: "pending",
                inventory_count: 5,
                reserved: true
              })
    end
  end

  # Optional: Implement compensate for rollback on failure
  def self.compensate(_reason, _arguments, _context)
    # Add compensation logic here (e.g., release reserved inventory)
    Success("Inventory reservation released")
  end

  # Optional: Implement undo for backwalk scenarios
  def self.undo(_result, _arguments, _context)
    # Add undo logic here if needed
    Success("Inventory reservation undone")
  end
end
