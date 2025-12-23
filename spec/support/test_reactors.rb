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

class ApiInnerReactor < RubyReactor::Reactor
  step :inner_step do
    run { |args| Success(args[:val] + 1) }
  end
end

class ApiComposeTestReactor < RubyReactor::Reactor
  compose :sub_reactor, ApiInnerReactor do
    argument :val, value(10)
  end

  step :final_step do
    argument :res, result(:sub_reactor)
    run { |args| Success(args[:res] * 2) }
  end
end
