# frozen_string_literal: true

# The child ComposedFanOutDemoReactor composes: reserve, ship every item in
# its own job (fan-out, 2 per throw), then confirm. When the map completes,
# the top-level run resumes, not this child as a run of its own (009 US2).
class ComposedFanOutChildReactor < RubyReactor::Reactor
  class ReserveStep < RubyReactor::Step
    input :skus

    def run
      Success(inputs.skus)
    end

    def undo
      ComposedFanOutDemoReactor.record(:released, "reservation")
      Success()
    end
  end

  class ConfirmStep < RubyReactor::Step
    def run
      Success(:confirmed)
    end
  end

  input :skus

  step :reserve, ReserveStep do
    argument :skus, input(:skus)
  end

  map :ship_items, ComposedFanOutItemReactor do
    source result(:reserve)
    argument :sku, element(:ship_items)
    fan_out batch_size: 2
  end

  step :confirm, ConfirmStep do
    wait_for :ship_items
  end
end
