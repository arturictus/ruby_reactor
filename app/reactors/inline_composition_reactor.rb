class InlineCompositionReactor < RubyReactor::Reactor
  input :numbers

  compose :process_numbers do
    input :numbers
    argument :numbers, input(:numbers)

    step :sum do
      argument :nums, input(:numbers)
      run { |args| Success(args[:nums].sum) }
    end

    step :average do
      argument :sum, result(:sum)
      argument :nums, input(:numbers)
      run { |args| Success(args[:sum].to_f / args[:nums].size) }
    end
    
  end

  step :final_output do
    argument :avg, result(:process_numbers)
    run { |args| Success("Average is #{args[:avg]}") }
  end

  returns :final_output
end
