# frozen_string_literal: true

module Support
  class RetryRegressionReactor < RubyReactor::Reactor
    # Use class-level state to avoid globals but allow access across async boundaries
    def self.step_counts
      @step_counts ||= Hash.new(0)
    end

    def self.reset_counts
      @step_counts = Hash.new(0)
    end

    step :step1 do
      run do |_args, _context|
        Support::RetryRegressionReactor.step_counts[:step1] += 1
        RubyReactor.Success("step1_done")
      end
    end

    step :step2 do
      async true
      run do |_args, _context|
        Support::RetryRegressionReactor.step_counts[:step2] += 1
        RubyReactor.Success("step2_done")
      end
    end

    step :step3 do
      retries max_attempts: 3, backoff: :fixed, base_delay: 0.01
      run do |_args, _context|
        Support::RetryRegressionReactor.step_counts[:step3] += 1
        if Support::RetryRegressionReactor.step_counts[:step3] < 3
          RubyReactor.Failure("retry_me")
        else
          RubyReactor.Success("step3_done")
        end
      end
    end
  end
end
