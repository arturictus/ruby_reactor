# frozen_string_literal: true

# `fan_out` without `batch_size` (009 US3): 120 elements, enqueued at most 50
# per throw (`RubyReactor::Map::DEFAULT_BATCH_SIZE`), each throw firing when
# the previous throw's last element finishes.
class DefaultBatchFanOutDemoReactor < RubyReactor::Reactor
  class NumbersStep < RubyReactor::Step
    def run
      Success((1..120).to_a)
    end
  end

  step :numbers, NumbersStep

  map :doubled, DefaultBatchNumberReactor do
    source result(:numbers)
    argument :n, element(:doubled)
    fan_out
    collect { |results| results.count(&:success?) }
  end

  returns :doubled
end
