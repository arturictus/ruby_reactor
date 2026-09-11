# frozen_string_literal: true

class ReserveInventory < RubyReactor::Step
  def run
    order = inputs[:order]
    fail_at = inputs[:fail_at]

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
  def compensate
    # Add compensation logic here (e.g., release reserved inventory)
    Success("Inventory reservation released")
  end

  # Optional: Implement undo for backwalk scenarios
  def undo
    # Add undo logic here if needed
    Success("Inventory reservation undone")
  end
end
