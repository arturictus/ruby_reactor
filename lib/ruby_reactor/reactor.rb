# frozen_string_literal: true

module RubyReactor
  # rubocop:disable Metrics/ClassLength
  class Reactor
    include RubyReactor::Dsl::Reactor
    include RubyReactor::Dsl::Lockable

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

      if result.is_a?(RubyReactor::Failure) && result.respond_to?(:invalid_payload?) && result.invalid_payload?
        # Raise exception to match expected behavior (strict mode for class method)
        # We do NOT cancel the reactor, allowing the user to retry with valid payload
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
      reactor = find(id)
      reactor.cancel(reason)
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

      if @context.is_a?(Context)
        @execution_trace = @context.execution_trace || []
        @undo_trace = @execution_trace.select { |e| e[:type] == :undo }
        @result = reconstruct_result
      else
        @undo_trace = []
        @execution_trace = []
      end
    end

    # rubocop:disable Metrics/MethodLength
    def run(inputs = {})
      # For all reactors, initialize context first to capture execution ID
      @context = @context.is_a?(Context) ? @context : Context.new(inputs, self.class)

      # Validate inputs
      validation_result = self.class.validate_inputs(inputs)
      if validation_result.failure?
        @result = validation_result
        @context.status = "failed"
        @context.failure_reason = {
          message: validation_result.error.message,
          validation_errors: validation_result.error.field_errors
        }
        save_context
        return validation_result
      end

      if self.class.async? && !@context.inline_async_execution
        # For async reactors, queue a job for the whole reactor
        @context.status = :running
        save_context

        serialized_context = ContextSerializer.serialize(@context)
        @result = configuration.async_router.perform_async(serialized_context, self.class.name,
                                                           intermediate_results: @context.intermediate_results)

        # Even if it's an AsyncResult, it might have finished inline (e.g. Sidekiq::Testing.inline!)
        # Check storage to see if it's already finished or paused (interrupted).
        begin
          reloaded = self.class.find(@context.context_id)
          if reloaded.finished? || reloaded.context.status.to_s == "paused"
            @context = reloaded.context
            @result = reloaded.result
            @execution_trace = reloaded.execution_trace
            @undo_trace = reloaded.undo_trace
            return @result
          end
        rescue StandardError
          # Ignore if not found or other errors during reload check
        end

      else
        # For sync reactors (potentially with async steps), execute normally
        context = @context.is_a?(Context) ? @context : nil
        executor = Executor.new(self.class, inputs, context)
        @result = executor.execute
        @context = executor.context
        @execution_trace = executor.execution_trace
        @undo_trace = executor.undo_trace
      end
      @result
    end
    # rubocop:enable Metrics/MethodLength, Metrics/AbcSize

    def continue(payload:, step_name:, idempotency_key: nil)
      _ = idempotency_key

      unless @context.current_step
        raise Error::ValidationError, "Cannot resume: context does not have a current step (was it interrupted?)"
      end

      if @context.cancelled
        raise Error::ValidationError,
              "Cannot resume: reactor has been cancelled (Reason: #{@context.cancellation_reason})"
      end

      validate_continue_step!(step_name)

      if (failure = validate_continue_payload(payload, step_name))
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
      RubyReactor::Failure(e.message, invalid_payload: true)
    end

    def undo
      executor = Executor.new(self.class, {}, @context)
      executor.undo_all
      executor.save_context
    end

    def cancel(reason)
      @context.cancelled = true
      @context.cancellation_reason = reason
      @context.status = "cancelled"
      save_context
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

    def reconstruct_result
      case @context.status.to_s
      when "completed" then reconstruct_success_result
      when "failed" then reconstruct_failure_result
      when "paused" then reconstruct_paused_result
      else :unexecuted
      end
    end

    def reconstruct_success_result
      rs = self.class.respond_to?(:returns) ? self.class.returns : nil
      val = if rs
              @context.intermediate_results[rs.to_sym] || @context.intermediate_results[rs.to_s]
            else
              find_last_step_result
            end
      Success.new(val)
    end

    def find_last_step_result
      last_run = @execution_trace.reverse.find { |e| e[:type] == :run || e["type"] == "run" }
      return unless last_run

      step_name = last_run[:step] || last_run["step"]
      @context.intermediate_results[step_name.to_sym] || @context.intermediate_results[step_name.to_s]
    end

    def reconstruct_failure_result
      reason = @context.failure_reason || {}
      return reason if reason.is_a?(RubyReactor::Failure)

      # Use string keys preferred, fallback to symbol
      r = ->(k) { reason[k.to_s] || reason[k.to_sym] }

      Failure.new(
        r[:message],
        step_name: r[:step_name],
        inputs: r[:inputs] || {},
        backtrace: r[:backtrace],
        reactor_name: r[:reactor_name],
        step_arguments: r[:step_arguments] || {},
        exception_class: r[:exception_class],
        file_path: r[:file_path],
        line_number: r[:line_number],
        code_snippet: r[:code_snippet],
        validation_errors: r[:validation_errors],
        retryable: r[:retryable],
        invalid_payload: r[:invalid_payload]
      )
    end

    def reconstruct_paused_result
      InterruptResult.new(
        execution_id: @context.context_id,
        intermediate_results: @context.intermediate_results
      )
    end

    def initialize_and_validate_run?(inputs)
      # For all reactors, initialize context first to capture execution ID
      @context = @context.is_a?(Context) ? @context : Context.new(inputs, self.class)

      validation_result = self.class.validate_inputs(inputs)
      if validation_result.failure?
        handle_validation_failure(validation_result)
        return false
      end
      true
    end

    def handle_validation_failure(result)
      @result = result
      @context.status = "failed"
      @context.failure_reason = {
        message: result.error.message,
        validation_errors: result.error.field_errors
      }
      save_context
    end

    def perform_async_run
      @context.status = :running
      save_context

      serialized_context = ContextSerializer.serialize(@context)
      @result = configuration.async_router.perform_async(serialized_context, self.class.name,
                                                         intermediate_results: @context.intermediate_results)

      check_for_inline_completion
    end

    def check_for_inline_completion
      # Even if it's an AsyncResult, it might have finished inline (e.g. Sidekiq::Testing.inline!)
      # Check storage to see if it's already finished or paused (interrupted).
      reloaded = self.class.find(@context.context_id)
      if reloaded.finished? || reloaded.context.status.to_s == "paused"
        update_state_from_reloaded(reloaded)
        @result
      end
    rescue StandardError
      # Ignore if not found or other errors during reload check
    end

    def update_state_from_reloaded(reloaded)
      @context = reloaded.context
      @result = reloaded.result
      @execution_trace = reloaded.execution_trace
      @undo_trace = reloaded.undo_trace
    end

    def perform_sync_run(inputs)
      context = @context.is_a?(Context) ? @context : nil
      executor = Executor.new(self.class, inputs, context)
      @result = executor.execute
      @context = executor.context
      @execution_trace = executor.execution_trace
      @undo_trace = executor.undo_trace
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

    def validate_continue_payload(payload, step_name)
      step_config = self.class.steps[step_name.to_sym]
      return unless step_config&.validation_schema

      validation = step_config.validation_schema.call(payload)

      return unless validation.failure?

      # Track attempts
      step_key = step_name.to_sym
      @context.private_data[:interrupt_attempts] ||= {}
      @context.private_data[:interrupt_attempts][step_key] ||= 0
      @context.private_data[:interrupt_attempts][step_key] += 1

      save_context # Persist the attempt count

      current_attempts = @context.private_data[:interrupt_attempts][step_key]
      max_attempts = step_config.max_attempts

      if max_attempts != :infinity && current_attempts >= max_attempts
        # Max attempts reached - Fail and Compensate
        undo

        # Instead of cancelling, we mark as failed so it shows up as failed in UI
        @context.status = "failed"
        @context.failure_reason = {
          message: "Validation failed after #{max_attempts} attempts",
          step_name: step_name,
          errors: validation.errors.to_h,
          payload: payload,
          step_arguments: payload,
          attempts: current_attempts,
          validation_errors: validation.errors.to_h
        }

        save_context

        return RubyReactor::Failure(
          "Validation failed after #{max_attempts} attempts",
          step_name: step_name,
          step_arguments: payload,
          validation_errors: validation.errors.to_h
        )
      end

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

    def save_context
      storage = configuration.storage_adapter
      reactor_class_name = self.class.name || "AnonymousReactor-#{self.class.object_id}"
      serialized_context = ContextSerializer.serialize(@context)
      storage.store_context(@context.context_id, serialized_context, reactor_class_name)
    end
  end
  # rubocop:enable Metrics/ClassLength
end
