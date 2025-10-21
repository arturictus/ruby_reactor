# frozen_string_literal: true

module RubyReactor
  class Reactor
    include RubyReactor::Dsl::Reactor

    attr_reader :context, :result

    def initialize(context = {})
      @context = context
      @result = :unexecuted
    end

    def run(inputs = {})
      if self.class.async?
        # For async reactors, enqueue the job and return immediately
        context = Context.new(inputs, self.class)
        serialized_context = ContextSerializer.serialize(context)
        RubyReactor::Worker.perform_async(serialized_context)

        # Return a result indicating the job was queued
        RubyReactor::AsyncResult.new(job_id: nil) # TODO: Get job ID from Sidekiq
      else
        # For sync reactors (potentially with async steps), execute normally
        executor = Executor.new(self.class, inputs)
        @result = executor.execute
        @context = executor.context

        # If execution returned an AsyncResult (from step-level async), return it
        return @result if @result.is_a?(RubyReactor::AsyncResult)

        @result
      end
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
