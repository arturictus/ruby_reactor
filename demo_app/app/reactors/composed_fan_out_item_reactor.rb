# frozen_string_literal: true

# One item of ComposedFanOutChildReactor's fan-out map: ship it, and unship it
# as its undo.
class ComposedFanOutShipStep < RubyReactor::Step
  input :sku, :string

  def run
    ComposedFanOutDemoReactor.record(:shipped, inputs.sku)
    Success(shipment: "sh_#{inputs.sku}")
  end

  def undo
    ComposedFanOutDemoReactor.record(:unshipped, inputs.sku)
    Success()
  end
end

class ComposedFanOutItemReactor < RubyReactor::Reactor
  input :sku, :string

  step :ship, ComposedFanOutShipStep do
    argument :sku, input(:sku)
  end

  returns :ship
end
