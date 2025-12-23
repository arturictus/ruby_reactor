class ParentReactor < RubyReactor::Reactor
  input :a do
    required(:a).filled(:integer)
  end
  input :b do
    required(:b).filled(:integer)
  end

  compose :child_reactor, ChildReactor do
    argument :x, input(:a)
    argument :y, input(:b)
  end

  
  compose :math_operation do
    argument :a, input(:a)
    argument :b, input(:b)
    step :multiply do
      argument :a, input(:a)
      argument :b, input(:b)
      
      run do |args| 
        Success(args[:a] * args[:b])
      end 
    end

    step :do_something do
      argument :mul, result(:multiply)
      run do |args|
        Success(args[:mul] * 7)
      end
    end

    step :do_other_thing do
      argument :mul, result(:multiply)
      run do |args|
        Success(args[:mul] * 8)
      end
    end

    step :wait_for do
      argument :mul, result(:multiply)
      argument :other, result(:do_other_thing)

      run do |args|
        Success(args[:mul] + args[:other])
      end
    end
  end

  step :format_result do
    argument :mul, result(:math_operation)
    argument :sum, result(:child_reactor)
    run { |args| Success("The sum is #{args[:sum]}\n the Mul is #{args[:mul][:multiply]}") }
  end

  returns :format_result
end
