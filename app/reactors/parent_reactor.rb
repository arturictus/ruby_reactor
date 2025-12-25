class ParentReactor < RubyReactor::Reactor
  input :a do
    required(:a).filled(:integer)
  end
  input :b do
    required(:b).filled(:integer)
  end
  input :fail_at_reactor, optional: true
  input :fail_at_step, optional: true

  compose :child_reactor, ChildReactor do
    argument :x, input(:a)
    argument :y, input(:b)
    argument :fail_at_reactor, input(:fail_at_reactor)
    argument :fail_at_step, input(:fail_at_step)
  end

  
  compose :math_operation do
    argument :a, input(:a)
    argument :b, input(:b)
    argument :fail_at_reactor, input(:fail_at_reactor)
    argument :fail_at_step, input(:fail_at_step)
    step :multiply do
      argument :a, input(:a)
      argument :b, input(:b)
      argument :fail_at_reactor, input(:fail_at_reactor)
      argument :fail_at_step, input(:fail_at_step)
      
      run do |args| 
        puts "[EXECUTION] RUN math_operation.multiply - a: #{args[:a]}, b: #{args[:b]}"
        if args[:fail_at_reactor]&.to_sym == :math_operation && args[:fail_at_step]&.to_sym == :multiply
          Failure("Simulated failure at math_operation.multiply")
        else
          Success(args[:a] * args[:b])
        end
      end 

      undo do |_error, context|
        puts "[EXECUTION] UNDO math_operation.multiply - a: #{context[:a]}, b: #{context[:b]}"
        Success("Compensated math_operation.multiply")
      end

      compensate do |_reason, args, _context|
        puts "[EXECUTION] COMPENSATE math_operation.multiply - a: #{args[:a]}, b: #{args[:b]}"
        Success("Compensated math_operation.multiply")
      end
    end

    step :do_something do
      argument :mul, result(:multiply)
      argument :fail_at_reactor, input(:fail_at_reactor)
      argument :fail_at_step, input(:fail_at_step)
      run do |args|
        puts "[EXECUTION] RUN math_operation.do_something - mul: #{args[:mul]}"
        if args[:fail_at_reactor]&.to_sym == :math_operation && args[:fail_at_step]&.to_sym == :do_something
          Failure("Simulated failure at math_operation.do_something")
        else
          Success(args[:mul] * 7)
        end
      end

      undo do |_error, context|
        puts "[EXECUTION] UNDO math_operation.do_something - mul: #{context[:mul]}"
        Success("Compensated math_operation.do_something")
      end

      compensate do |_reason, args, _context|
        puts "[EXECUTION] COMPENSATE math_operation.do_something - mul: #{args[:mul]}"
        Success("Compensated math_operation.do_something")
      end
    end

    step :do_other_thing do
      argument :mul, result(:multiply)
      argument :fail_at_reactor, input(:fail_at_reactor)
      argument :fail_at_step, input(:fail_at_step)
      run do |args|
        puts "[EXECUTION] RUN math_operation.do_other_thing - mul: #{args[:mul]}"
        if args[:fail_at_reactor]&.to_sym == :math_operation && args[:fail_at_step]&.to_sym == :do_other_thing
          Failure("Simulated failure at math_operation.do_other_thing")
        else
          Success(args[:mul] * 8)
        end
      end

      undo do |_error, context|
        puts "[EXECUTION] UNDO math_operation.do_other_thing - mul: #{context[:mul]}"
        Success("Compensated math_operation.do_other_thing")
      end

      compensate do |_reason, args, _context|
        puts "[EXECUTION] COMPENSATE math_operation.do_other_thing - mul: #{args[:mul]}"
        Success("Compensated math_operation.do_other_thing")
      end
    end

    step :wait_for do
      argument :mul, result(:multiply)
      argument :other, result(:do_other_thing)
      argument :fail_at_reactor, input(:fail_at_reactor)
      argument :fail_at_step, input(:fail_at_step)

      run do |args|
        puts "[EXECUTION] RUN math_operation.wait_for - mul: #{args[:mul]}, other: #{args[:other]}"
        if args[:fail_at_reactor]&.to_sym == :math_operation && args[:fail_at_step]&.to_sym == :wait_for
          Failure("Simulated failure at math_operation.wait_for")
        else
          Success(args[:mul] + args[:other])
        end
      end

      undo do |_error, context|
        puts "[EXECUTION] UNDO math_operation.wait_for - mul: #{context[:mul]}"
        Success("Compensated math_operation.wait_for")
      end

      compensate do |_reason, args, _context|
        puts "[EXECUTION] COMPENSATE math_operation.wait_for - mul: #{args[:mul]}"
        Success("Compensated math_operation.wait_for")
      end
    end
  end

  step :format_result do
    argument :mul, result(:math_operation)
    argument :sum, result(:child_reactor)
    argument :fail_at_reactor, input(:fail_at_reactor)
    argument :fail_at_step, input(:fail_at_step)
    run do |args| 
      puts "[EXECUTION] RUN parent_reactor.format_result - sum: #{args[:sum]}, math: #{args[:mul].inspect}"
      if args[:fail_at_reactor]&.to_sym == :parent_reactor && args[:fail_at_step]&.to_sym == :format_result
        Failure("Simulated failure at parent_reactor.format_result")
      else
        Success("The sum is #{args[:sum]}\n the Mul is #{args[:mul][:multiply]}")
      end
    end

    undo do |_error, context|
      puts "[EXECUTION] UNDO parent_reactor.format_result - sum: #{context[:sum]}"
      Success("Compensated parent_reactor.format_result")
    end

    compensate do |_reason, args, _context|
      puts "[EXECUTION] COMPENSATE parent_reactor.format_result - sum: #{args[:sum]}"
      Success("Compensated parent_reactor.format_result")
    end
  end

  returns :format_result
end
