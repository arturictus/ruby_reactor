class ChildReactor < RubyReactor::Reactor
  input :x
  input :y
  input :fail_at_reactor, optional: true
  input :fail_at_step, optional: true
  
  step :add do
    argument :x, input(:x)
    argument :y, input(:y)
    argument :fail_at_reactor, input(:fail_at_reactor)
    argument :fail_at_step, input(:fail_at_step)
    run { |args|
      puts "[EXECUTION] RUN child_reactor.add - x: #{args[:x]}, y: #{args[:y]}"
      if args[:fail_at_reactor]&.to_sym == :child_reactor && args[:fail_at_step]&.to_sym == :add
        Failure("Simulated failure at child_reactor.add")
      else
        Success(args[:x] + args[:y])
      end
    }

    undo do |_error, context|
      puts "[EXECUTION] UNDO child_reactor.add - x: #{context[:x]}, y: #{context[:y]}"
      Success("Compensated child_reactor.add")
    end

    compensate do |_reason, args, _context|
      puts "[EXECUTION] COMPENSATE child_reactor.add - x: #{args[:x]}, y: #{args[:y]}"
      Success("Compensated child_reactor.add")
    end
  end

  step :do_something do
    argument :mul, result(:add)
    argument :fail_at_reactor, input(:fail_at_reactor)
    argument :fail_at_step, input(:fail_at_step)
    run do |args|
      puts "[EXECUTION] RUN child_reactor.do_something - mul: #{args[:mul]}"
      if args[:fail_at_reactor]&.to_sym == :child_reactor && args[:fail_at_step]&.to_sym == :do_something
        Failure("Simulated failure at child_reactor.do_something")
      else
        Success(args[:mul] * 7)
      end
    end

    undo do |_error, context|
      puts "[EXECUTION] UNDO child_reactor.do_something - mul: #{context[:mul]}"
      Success("Compensated child_reactor.do_something")
    end

    compensate do |_reason, args, _context|
      puts "[EXECUTION] COMPENSATE child_reactor.do_something - mul: #{args[:mul]}"
      Success("Compensated child_reactor.do_something")
    end
  end

  step :do_other_thing do
    argument :mul, result(:add)
    argument :fail_at_reactor, input(:fail_at_reactor)
    argument :fail_at_step, input(:fail_at_step)
    run do |args|
      puts "[EXECUTION] RUN child_reactor.do_other_thing - mul: #{args[:mul]}"
      if args[:fail_at_reactor]&.to_sym == :child_reactor && args[:fail_at_step]&.to_sym == :do_other_thing
        Failure("Simulated failure at child_reactor.do_other_thing")
      else
        Success(args[:mul] * 8)
      end
    end

    undo do |_error, context|
      puts "[EXECUTION] UNDO child_reactor.do_other_thing - mul: #{context[:mul]}"
      Success("Compensated child_reactor.do_other_thing")
    end

    compensate do |_reason, args, _context|
      puts "[EXECUTION] COMPENSATE child_reactor.do_other_thing - mul: #{args[:mul]}"
      Success("Compensated child_reactor.do_other_thing")
    end
  end

  step :wait_for do
    argument :mul, result(:add)
    argument :other, result(:do_other_thing)
    argument :fail_at_reactor, input(:fail_at_reactor)
    argument :fail_at_step, input(:fail_at_step)

    run do |args|
      puts "[EXECUTION] RUN child_reactor.wait_for - mul: #{args[:mul]}, other: #{args[:other]}"
      if args[:fail_at_reactor]&.to_sym == :child_reactor && args[:fail_at_step]&.to_sym == :wait_for
        Failure("Simulated failure at child_reactor.wait_for")
      else
        Success(args[:mul] + args[:other])
      end
    end

    undo do |_error, context|
      puts "[EXECUTION] UNDO child_reactor.wait_for - mul: #{context[:mul]}"
      Success("Compensated child_reactor.wait_for")
    end

    compensate do |_reason, args, _context|
      puts "[EXECUTION] COMPENSATE child_reactor.wait_for - mul: #{args[:mul]}"
      Success("Compensated child_reactor.wait_for")
    end
  end
  
  returns :add
end
