# frozen_string_literal: true

module RubyReactor
  class Reactor
    include RubyReactor::Dsl::Reactor

    attr_reader :context, :result, :undo_trace, :execution_trace

    def self.continue(id:, payload:, idempotency_key: nil)
      reactor_class_name = name
      serialized_context = configuration.storage_adapter.retrieve_context(id, reactor_class_name)
      raise Error::ValidationError, "Context '#{id}' not found" unless serialized_context

      context = Context.deserialize_from_retry(serialized_context)

      # TODO: Implement idempotency check using idempotency_key
      _ = idempotency_key

      resume_with_payload(context, payload)
    end

    def self.continue_by_correlation_id(correlation_id:, payload:, idempotency_key: nil)
      reactor_class_name = name
      context_id = configuration.storage_adapter.retrieve_context_id_by_correlation_id(correlation_id,
                                                                                       reactor_class_name)
      raise Error::ValidationError, "Correlation ID '#{correlation_id}' not found" unless context_id

      continue(id: context_id, payload: payload, idempotency_key: idempotency_key)
    end

    def self.cancel(id:, reason:)
      # Placeholder for cancellation logic
      # 1. Retrieve context
      # 2. Mark as cancelled
      # 3. Trigger compensations if needed
      # 4. Clean up storage

      _ = reason
      reactor_class_name = name
      # For now, just remove from storage
      configuration.storage_adapter.expire(
        "reactor:#{reactor_class_name}:context:#{id}",
        0
      )
    end

    def self.resume_with_payload(context, payload)
      # Store payload as the result of the current step (the interrupt step)
      # The step name is stored in context.current_step

      unless context.current_step
        raise Error::ValidationError, "Cannot resume: context does not have a current step (was it interrupted?)"
      end

      # Validate payload if the step has validation
      step_config = steps[context.current_step]
      if step_config && step_config.validation_schema
        validation = step_config.validation_schema.call(payload)
        raise Error::InputValidationError, validation.errors.to_h if validation.failure?
      end

      context.set_result(context.current_step, payload)

      # Resume execution
      executor = Executor.new(self, {}, context)
      executor.resume_execution

      # Clean up correlation ID from storage if it exists?
      # Maybe better to do this in Executor or keep it until TTL?
      # For now, let's leave it to expire.
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
        executor = Executor.new(self.class, inputs)
        @result = executor.execute

        @context = executor.context

        @undo_trace = executor.undo_trace
        @execution_trace = executor.execution_trace

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
  end
end
