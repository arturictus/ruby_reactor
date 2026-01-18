# frozen_string_literal: true

require_relative "rspec/helpers"
require_relative "rspec/matchers"
require_relative "rspec/test_subject"

module RubyReactor
  module RSpec
    def self.configure(config)
      require_relative "rspec/step_executor_patch"

      config.include RubyReactor::RSpec::Helpers
      config.include RubyReactor::RSpec::Matchers

      ::RubyReactor::Executor::StepExecutor.prepend(RubyReactor::RSpec::StepExecutorPatch)
    end
  end
end
