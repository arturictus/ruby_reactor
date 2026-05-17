# frozen_string_literal: true

# Test reactor classes for map-related specs
# These are centralized here to avoid class definition conflicts across specs

module MapTestReactors
  # Simple reactor that doubles a number
  class DoubleReactor < RubyReactor::Reactor
    input :number

    step :double do
      argument :number, input(:number)
      run { |args, _| 
        puts "RUNNING -----------"
        RubyReactor::Success(args[:number] * 2) 
      }
    end

    returns :double
  end

  # Reactor for testing single worker map execution
  class SingleWorkerMapReactor < RubyReactor::Reactor
    input :numbers

    map :doubled_numbers, DoubleReactor do
      source input(:numbers)
      argument :number, element(:doubled_numbers)
      async true # Default single worker strategy
    end
  end

  # Reactor for testing batch size functionality
  class BatchMapReactor < RubyReactor::Reactor
    input :numbers

    map :doubled_numbers, DoubleReactor do
      source input(:numbers)
      argument :number, element(:doubled_numbers)
      async true, batch_size: 2
    end
  end

  # Reactor for testing async map execution with batch_size: 1
  class AsyncMapReactor < RubyReactor::Reactor
    input :numbers

    map :doubled_numbers, DoubleReactor do
      source input(:numbers)
      argument :number, element(:doubled_numbers)
      async true, batch_size: 1
    end
  end
end
