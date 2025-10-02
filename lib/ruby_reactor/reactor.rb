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
      if self.class.steps.empty?
        raise Error::ValidationError.new("Reactor must have at least one step")
      end
    end

    def validate_return_step!
      return unless self.class.return_step
      
      unless self.class.steps.key?(self.class.return_step)
        raise Error::ValidationError.new(
          "Return step '#{self.class.return_step}' is not defined"
        )
      end
    end

    def validate_dependencies!
      graph = DependencyGraph.new
      self.class.steps.each { |name, config| graph.add_step(config) }
      
      if graph.has_cycles?
        raise Error::DependencyError.new("Dependency graph contains cycles")
      end
    end
  end
end