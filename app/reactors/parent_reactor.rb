class ParentReactor < RubyReactor::Reactor
  input :a
  input :b

  step :math_operation do
    argument :x, input(:a)
    argument :y, input(:b)
    run do |args| 
      ChildReactor.run(x: args[:x], y: args[:y]) 
    end
  end

  step :format_result do
    argument :result, result(:math_operation)
    run { |args| Success("The sum is #{args[:result]}") }
  end

  returns :format_result
end
