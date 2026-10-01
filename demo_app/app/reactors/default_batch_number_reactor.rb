# frozen_string_literal: true

# One element of DefaultBatchFanOutDemoReactor's fan-out map: double a number.
class DefaultBatchNumberReactor < RubyReactor::Reactor
  class DoubleStep < RubyReactor::Step
    input :n, :integer

    def run
      Success(inputs.n * 2)
    end
  end

  input :n, :integer

  step :double, DoubleStep do
    argument :n, input(:n)
  end

  returns :double
end
