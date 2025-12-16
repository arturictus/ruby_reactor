# frozen_string_literal: true

module RubyReactor
  class Reactor
    include RubyReactor::Dsl::Reactor

    attr_reader :context, :result, :undo_trace, :execution_trace

    def self.find(id)
      reactor_class_name = name
      serialized_context = configuration.storage_adapter.retrieve_context(id, reactor_class_name)
      raise Error::ValidationError, "Context '#{id}' not found" unless serialized_context

      context = Context.deserialize_from_retry(serialized_context)
      new(context)
    end

    def self.find_by_correlation_id(correlation_id)
      reactor_class_name = name
      context_id = configuration.storage_adapter.retrieve_context_id_by_correlation_id(
        correlation_id,
        reactor_class_name
      )
      raise Error::ValidationError, "Correlation ID '#{correlation_id}' not found" unless context_id

      find(context_id)
    end

    def self.continue(id:, payload:, step_name:, idempotency_key: nil)
      reactor = find(id)
      result = reactor.continue(payload: payload, step_name: step_name, idempotency_key: idempotency_key)

      if result.is_a?(RubyReactor::Failure) && result.invalid_payload?
        undo(id)
        cancel(id: id, reason: "Payload validation failed")

        # Raise exception to match expected behavior (strict mode for class method)
        raise Error::InputValidationError, result.error
      end

      result
    end

    def self.continue_by_correlation_id(correlation_id:, payload:, step_name:, idempotency_key: nil)
      reactor = find_by_correlation_id(correlation_id)
      # We delegate to the class-level continue method to ensure auto-compensation logic applies
      # by using the context ID found by find_by_correlation_id
      continue(id: reactor.context.context_id, payload: payload, step_name: step_name, idempotency_key: idempotency_key)
    end

    def self.cancel(id:, reason:)
      _ = reason
      reactor_class_name = name

      # Clean up storage
      configuration.storage_adapter.delete_context(id, reactor_class_name)

      # We might want to remove correlation IDs too, but we don't always know them here easily
      # unless we rehydrate the context. For now, we rely on TTL or separate cleanup.
    end

    def self.undo(id)
      reactor = find(id)
      reactor.undo
      cancel(id: id, reason: "Undo triggered")
    end

    def self.configuration
      RubyReactor::Configuration.instance
    end

    def initialize(context = {})
      @context = context
      @result = :unexecuted
      @undo_trace = []
      @execution_trace = []
    end

    def run(inputs = {})
      if self.class.async?
        # For async reactors, enqueue the job and return immediately
        context = Context.new(inputs, self.class)
        serialized_context = ContextSerializer.serialize(context)
        configuration.async_router.perform_async(serialized_context)
      else
        # For sync reactors (potentially with async steps), execute normally
        context = @context.is_a?(Context) ? @context : nil
        executor = Executor.new(self.class, inputs, context)
        @result = executor.execute

        @context = executor.context

        # Merge traces
        @undo_trace = executor.undo_trace
        @execution_trace = executor.execution_trace

        # If execution returned an AsyncResult (from step-level async), return it
        return @result if @result.is_a?(RubyReactor::AsyncResult)

        @result
      end
    end

    def continue(payload:, step_name:, idempotency_key: nil)
      _ = idempotency_key

      unless @context.current_step
        raise Error::ValidationError, "Cannot resume: context does not have a current step (was it interrupted?)"
      end

      validate_continue_step!(step_name)

      if (failure = validate_continue_payload(payload))
        return failure
      end

      target_step = step_name
      @context.set_result(target_step, payload)

      # Resume execution
      executor = Executor.new(self.class, {}, @context)
      @result = executor.resume_execution

      @context = executor.context
      @undo_trace = executor.undo_trace
      @execution_trace = executor.execution_trace

      @result
    rescue Error::InputValidationError => e
      # This might catch other validations, but here we specifically want payload validation.
      # The block above handles payload validation explicitly.
      failure = RubyReactor::Failure(e.message)
      def failure.invalid_payload? = true
      failure
    end

    def undo
      executor = Executor.new(self.class, {}, @context)
      executor.undo_all
    end

    def validate!
      # Validate reactor configuration
      validate_steps!
      validate_return_step!
      validate_dependencies!
    end

    private

    def configuration
      RubyReactor::Configuration.instance
    end

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

    def validate_continue_step!(step_name)
      return if step_name.to_s == @context.current_step.to_s

      # Build graph to check if step is ready
      graph_manager = Executor::GraphManager.new(self.class, DependencyGraph.new, @context)
      graph_manager.build_and_validate!
      graph_manager.mark_completed_steps_from_context
      ready_steps = graph_manager.dependency_graph.ready_steps.map(&:name).map(&:to_s)

      return if ready_steps.include?(step_name.to_s)

      raise Error::ValidationError,
            "Cannot resume: expected step '#{@context.current_step}' " \
            "or ready steps #{ready_steps} but got '#{step_name}'"
    end

    def validate_continue_payload(payload)
      step_config = self.class.steps[@context.current_step]
      return unless step_config&.validation_schema

      validation = step_config.validation_schema.call(payload)

      return unless validation.failure?

      failure = RubyReactor::Failure(validation.errors.to_h)
      # We need a way to mark this failure as a validation failure
      # For now, we rely on the error object inside Failure or just return Failure
      # The PRD requires `result.invalid_payload?` to be true.
      # Since we don't have that method on Failure yet, we might need to enhance Failure
      # OR wrap it. For now, let's assume Failure wraps the error and we can check it.
      # We'll use a specific error type to identify it.
      failure.instance_variable_set(:@type, :input_validation)
      def failure.invalid_payload? = true
      failure
    end
  end
end
