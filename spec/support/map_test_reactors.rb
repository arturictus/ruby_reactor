# frozen_string_literal: true

# Test reactor classes for map-related specs
# These are centralized here to avoid class definition conflicts across specs

module MapTestReactors
  # Simple reactor that doubles a number
  class DoubleReactor < RubyReactor::Reactor
    input :number

    step :double do
      argument :number, input(:number)
      run { |args, _| RubyReactor::Success(args.number * 2) }
    end

    returns :double
  end

  # Reactor for testing single worker map execution
  class SingleWorkerMapReactor < RubyReactor::Reactor
    input :numbers

    map :doubled_numbers, DoubleReactor do
      source input(:numbers)
      argument :number, element(:doubled_numbers)
      fan_out # No batch_size: one MapElementWorker per source element
    end
  end

  # Reactor for testing batch size functionality
  class BatchMapReactor < RubyReactor::Reactor
    input :numbers

    map :doubled_numbers, DoubleReactor do
      source input(:numbers)
      argument :number, element(:doubled_numbers)
      fan_out batch_size: 2
    end
  end

  # Reactor for testing async map execution with batch_size: 1
  class AsyncMapReactor < RubyReactor::Reactor
    input :numbers

    map :doubled_numbers, DoubleReactor do
      source input(:numbers)
      argument :number, element(:doubled_numbers)
      fan_out batch_size: 1
    end
  end

  # A fan-out map inside a reactor that already runs in a worker must still fan
  # out — not silently run its elements one by one in that worker.
  class BackgroundFanOutReactor < RubyReactor::Reactor
    background all: true
    input :numbers

    map :doubled_numbers, DoubleReactor do
      source input(:numbers)
      argument :number, element(:doubled_numbers)
      fan_out batch_size: 1
    end

    step :total do
      argument :doubled, result(:doubled_numbers)
      run { |args, _| RubyReactor::Success(args.doubled.map(&:value).sum) }
    end

    returns :total
  end
end
