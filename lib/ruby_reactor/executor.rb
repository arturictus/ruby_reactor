# frozen_string_literal: true

module RubyReactor
  # rubocop:disable Metrics/ClassLength
  class Executor
    attr_reader :reactor_class, :context, :dependency_graph, :undo_stack

    def initialize(reactor_class, inputs = {}, context = nil)
      @reactor_class = reactor_class
      @context = context || Context.new(inputs, reactor_class)
      @dependency_graph = DependencyGraph.new
      @undo_stack = []
      @step_results = {}
    end

    def execute
      validate_inputs!
      build_dependency_graph
      validate_graph!

      execute_steps
    rescue StandardError => e
      handle_execution_error(e)
    end

    def resume_execution
      # Resume execution from the current state
      # This is called when a job is requeued after a step retry

      # Build dependency graph and mark completed steps
      build_dependency_graph
      mark_completed_steps_from_context

      # If there's a current_step, it means we need to retry that step
      if context.current_step
        step_config = reactor_class.steps[context.current_step]
        return RubyReactor::Failure("Step '#{context.current_step}' not found in reactor") unless step_config

        result = execute_step_with_retry(step_config)
        case result
        when RetryQueuedResult, RubyReactor::Failure
          # Step was requeued again, return the result
          result
        when RubyReactor::Success
          # Step succeeded, continue with remaining steps
          execute_remaining_steps
        end

      # Step not found, this is an error

      else
        # No current step, execute remaining steps
        execute_remaining_steps
      end
    end

    private

    def validate_inputs!
      check_required_inputs
      validate_input_schemas
    end

    def check_required_inputs
      reactor_class.inputs.each do |input_name, input_config|
        next if input_config[:optional] || context.inputs.key?(input_name) || context.inputs.key?(input_name.to_s)

        raise Error::ValidationError.new(
          "Required input '#{input_name}' is missing",
          context: context
        )
      end
    end

    def validate_input_schemas
      return unless reactor_class.respond_to?(:input_validations) && reactor_class.input_validations.any?

      validation_result = reactor_class.validate_inputs(context.inputs)
      return unless validation_result.failure?

      raise validation_result.error
    end

    def build_dependency_graph
      reactor_class.steps.each_value do |step_config|
        dependency_graph.add_step(step_config)
      end
    end

    def validate_graph!
      return unless dependency_graph.has_cycles?

      raise Error::DependencyError.new(
        "Dependency graph contains cycles",
        context: context
      )
    end

    def execute_steps
      until dependency_graph.all_completed?
        ready_steps = dependency_graph.ready_steps

        if ready_steps.empty?
          raise Error::DependencyError.new(
            "No ready steps available but execution not complete",
            context: context
          )
        end

        # Execute steps sequentially
        ready_steps.each do |step_config|
          result = execute_step(step_config)

          # If step execution was handed off to async, return the async result
          return result if result.is_a?(RubyReactor::AsyncResult)

          # If a step returns RetryQueuedResult, we need to stop and return it
          return result if result.is_a?(RetryQueuedResult)
        end
      end

      # Return the final result
      if reactor_class.return_step
        result_value = context.get_result(reactor_class.return_step)
        RubyReactor.Success(result_value)
      else
        RubyReactor.Success(context.intermediate_results)
      end
    end

    def execute_step(step_config)
      if step_config.async?
        # Step-level async: hand off execution to worker
        context.current_step = step_config.name
        serialized_context = ContextSerializer.serialize(context)
        RubyReactor::Worker.perform_async(serialized_context, reactor_class.name)
        RubyReactor::AsyncResult.new(job_id: nil) # TODO: Get job ID
      elsif async_execution?
        execute_step_with_retry(step_config)
      else
        execute_step_sync(step_config)
      end
    end

    # rubocop:disable Metrics/MethodLength
    # TODO: refactor this method to make it shorter
    def execute_step_with_retry(step_config)
      context.retry_context.current_step = step_config.name
      context.retry_context.increment_attempt_for_step(step_config.name)
      context.retry_context.attempts_for_step(step_config.name)

      result = safe_execute_step_sync(step_config)

      if result.is_a?(RubyReactor::Success)
        # Step succeeded, clear retry state
        context.retry_context.current_step = nil
        context.retry_context.failure_reason = nil
        context.retry_context.next_retry_at = nil
        dependency_graph.complete_step(step_config.name)
        result
      elsif result.is_a?(RubyReactor::Failure)
        # Step failed, check if we can retry
        if can_retry_step?(step_config)
          requeue_job_for_step_retry(step_config, result.error)
          RetryQueuedResult.new(
            step_config.name,
            context.retry_context.attempts_for_step(step_config.name),
            context.retry_context.next_retry_at
          )
        else
          # Cannot retry, fail
          context.retry_context.current_step = nil
          dependency_graph.complete_step(step_config.name)
          result
        end
      else
        # Unexpected result type
        context.retry_context.current_step = nil
        dependency_graph.complete_step(step_config.name)
        RubyReactor::Failure("Step '#{step_config.name}' returned unexpected result: #{result.inspect}")
      end
    end
    # rubocop:enable Metrics/MethodLength

    def safe_execute_step_sync(step_config)
      execute_step_sync(step_config)
    rescue StandardError => e
      RubyReactor::Failure(e)
    end

    def execute_step_sync(step_config)
      context.with_step(step_config.name) do
        # Check conditions and guards
        unless step_config.should_run?(context)
          dependency_graph.complete_step(step_config.name)
          return
        end

        # Resolve arguments
        resolved_arguments = resolve_arguments(step_config)

        # Validate arguments if validator is defined
        validate_step_arguments(step_config, resolved_arguments)

        # Execute the step
        result = run_step_implementation(step_config, resolved_arguments)

        # Handle the result
        handle_step_result(step_config, result, resolved_arguments)
      end
    end

    def validate_step_arguments(step_config, resolved_arguments)
      return unless step_config.args_validator

      validation_result = step_config.args_validator.call(resolved_arguments)
      return if validation_result.success?

      raise Error::StepFailureError.new(
        "Step '#{step_config.name}' argument validation failed: #{validation_result.error.message}",
        step: step_config.name,
        context: context
      )
    end

    def validate_step_output(step_config, value)
      return unless step_config.output_validator

      output_validation_result = step_config.output_validator.call(value)
      return if output_validation_result.success?

      raise Error::StepFailureError.new(
        "Step '#{step_config.name}' output validation failed: #{output_validation_result.error.message}",
        step: step_config.name,
        context: context
      )
    end

    def handle_step_result(step_config, result, resolved_arguments)
      case result
      when RubyReactor::Success
        validate_step_output(step_config, result.value)
        @step_results[step_config.name] = result
        @undo_stack << { step: step_config, arguments: resolved_arguments, result: result }
        context.set_result(step_config.name, result.value)
        dependency_graph.complete_step(step_config.name)
      when RubyReactor::Failure
        failure_result = handle_step_failure(step_config, result.error, resolved_arguments)
        raise Error::StepFailureError.new(failure_result.error, step: step_config.name, context: context)
      else
        # Treat non-Success/Failure results as success with that value
        validate_step_output(step_config, result)
        success_result = RubyReactor.Success(result)
        @step_results[step_config.name] = success_result
        @undo_stack << { step: step_config, arguments: resolved_arguments, result: success_result }
        context.set_result(step_config.name, result)
        dependency_graph.complete_step(step_config.name)
      end
    end

    def resolve_arguments(step_config)
      resolved = {}

      step_config.arguments.each do |arg_name, arg_config|
        source = arg_config[:source]
        transform = arg_config[:transform]

        value = source.resolve(context)
        value = transform.call(value) if transform

        resolved[arg_name] = value
      end

      resolved
    end

    def run_step_implementation(step_config, arguments)
      if step_config.has_run_block?
        # Execute inline block
        step_config.run_block.call(arguments, context)
      elsif step_config.has_impl?
        # Execute step class
        step_config.impl.run(arguments, context)
      else
        raise Error::ValidationError.new(
          "Step '#{step_config.name}' has no implementation",
          step: step_config.name,
          context: context
        )
      end
    end

    def handle_step_failure(step_config, error, arguments)
      # Try compensation
      compensation_result = compensate_step(step_config, error, arguments)

      case compensation_result
      when RubyReactor::Success
        # Compensation succeeded, continue with rollback
        rollback_completed_steps
        RubyReactor.Failure("Step '#{step_config.name}' failed: #{error}")
      when RubyReactor::Failure
        # Compensation failed, this is more serious
        rollback_completed_steps
        raise Error::CompensationError.new(
          "Compensation for step '#{step_config.name}' failed: #{compensation_result.error}",
          step: step_config.name,
          context: context,
          original_error: error
        )
      end
    end

    def compensate_step(step_config, error, arguments)
      if step_config.compensate_block
        step_config.compensate_block.call(error, arguments, context)
      elsif step_config.has_impl?
        step_config.impl.compensate(error, arguments, context)
      else
        RubyReactor.Success() # Default compensation
      end
    end

    def rollback_completed_steps
      @undo_stack.reverse_each do |step_info|
        undo_step(step_info[:step], step_info[:result], step_info[:arguments])
      end
      @undo_stack.clear
    end

    def undo_step(step_config, result, arguments)
      if step_config.undo_block
        step_config.undo_block.call(result.value, arguments, context)
      elsif step_config.has_impl?
        step_config.impl.undo(result.value, arguments, context)
      end
    rescue StandardError => e
      # Log undo failure but don't halt the rollback process
      # In a real implementation, this would use a logger
      puts "Warning: Undo failed for step '#{step_config.name}': #{e.message}"
    end

    def handle_execution_error(error)
      case error
      when Error::StepFailureError
        # Step failure has already been handled (compensation and rollback)
        RubyReactor.Failure(error.message)
      when Error::InputValidationError
        # Preserve validation errors as-is for proper error handling
        RubyReactor.Failure(error)
      when Error::Base
        # Other errors need rollback
        rollback_completed_steps
        RubyReactor.Failure(error.message)
      else
        # Unknown errors need rollback
        rollback_completed_steps
        RubyReactor.Failure("Execution failed: #{error.message}")
      end
    end

    def execute_remaining_steps
      until dependency_graph.all_completed?
        ready_steps = dependency_graph.ready_steps

        if ready_steps.empty?
          raise Error::DependencyError.new(
            "No ready steps available but execution not complete",
            context: context
          )
        end

        # Execute steps sequentially
        ready_steps.each do |step_config|
          result = execute_step(step_config)

          # If step execution was handed off to async, return the async result
          return result if result.is_a?(RubyReactor::AsyncResult)

          # If a step returns RetryQueuedResult, we need to stop and return it
          return result if result.is_a?(RetryQueuedResult)
        end
      end

      # Return the final result
      if reactor_class.return_step
        result_value = context.get_result(reactor_class.return_step)
        RubyReactor.Success(result_value)
      else
        RubyReactor.Success(context.intermediate_results)
      end
    end

    def async_execution?
      reactor_class.async?
    end

    def can_retry_step?(step_config)
      step_config.retryable? && context.retry_context.can_retry_step?(step_config.name,
                                                                      step_config.retry_config[:max_attempts])
    end

    def requeue_job_for_step_retry(step_config, error)
      context.retry_context.failure_reason = error
      attempt_number = context.retry_context.attempts_for_step(step_config.name)
      backoff_strategy = step_config.retry_config[:backoff] || reactor_class.retry_defaults[:backoff]
      base_delay = step_config.retry_config[:base_delay] || reactor_class.retry_defaults[:base_delay]

      delay = RetryContext.calculate_backoff_delay(attempt_number, backoff_strategy, base_delay)
      context.retry_context.next_retry_at = Time.now + delay

      # Serialize context and requeue the job
      serialized_context = ContextSerializer.serialize(context)
      RubyReactor::Worker.perform_in(delay, serialized_context, reactor_class.name)
    end

    def mark_completed_steps_from_context
      context.intermediate_results.each_key do |step_name|
        dependency_graph.complete_step(step_name)
      end
    end
  end
  # rubocop:enable Metrics/ClassLength
end
