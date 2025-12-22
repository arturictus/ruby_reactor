class ApiTestReactor < RubyReactor::Reactor
  step :step1 do
    run do |input, _context|
      RubyReactor.Success(input)
    end
  end

  step :step2 do
    run do |input, _context|
      raise "Something went wrong" if input[:should_fail]

      RubyReactor.Success(input)
    end
  end
end
