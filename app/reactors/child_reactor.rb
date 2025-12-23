class ChildReactor < RubyReactor::Reactor
  input :x
  input :y
  
  step :add do
    argument :x, input(:x)
    argument :y, input(:y)
    run { |args|
     Success(args[:x] + args[:y]) 
    }
  end

  step :do_something do
    argument :mul, result(:add)
    run do |args|
      Success(args[:mul] * 7)
    end
  end

  step :do_other_thing do
    argument :mul, result(:add)
    run do |args|
      Success(args[:mul] * 8)
    end
  end

  step :wait_for do
    argument :mul, result(:add)
    argument :other, result(:do_other_thing)

    run do |args|
      Success(args[:mul] + args[:other])
    end
  end
  
  returns :add
end
