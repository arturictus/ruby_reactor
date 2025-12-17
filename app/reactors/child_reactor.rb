class ChildReactor < RubyReactor::Reactor
  input :x
  input :y
  
  step :add do
    argument :x, input(:x)
    argument :y, input(:y)
    run { |args| Success(args[:x] + args[:y]) }
  end
  
  returns :add
end
