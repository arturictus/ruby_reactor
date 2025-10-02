# frozen_string_literal: true

module RubyReactor
  class Reactor
    include RubyReactor::Dsl::Reactor

    def initialize(context = {})
      @context = context
    end

    def run(inputs = {})
      executor = Executor.new(self.class, inputs)
      executor.execute
    end

    def validate!
      # Validate reactor configuration
      validate_steps!
      validate_return_step!
      validate_dependencies!
    end

    private

    def validate_steps!
      return unless self.class.steps.empty?

      raise Error::ValidationError, "Reactor must have at least one step"
    end

    def validate_return_step!
      return unless self.class.return_step

      return if self.class.steps.key?(self.class.return_step)

      raise Error::ValidationError, "Return step '#{self.class.return_step}' is not defined"
    end

    def validate_dependencies!
      graph = DependencyGraph.new
      self.class.steps.each_value { |config| graph.add_step(config) }

      return unless graph.has_cycles?

      raise Error::DependencyError, "Dependency graph contains cycles"
    end
  end
end
