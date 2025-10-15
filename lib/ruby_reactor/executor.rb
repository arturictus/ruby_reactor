# frozen_string_literal: true

module RubyReactor
  class Executor
    attr_reader :reactor_class, :context, :dependency_graph, :undo_stack

    def initialize(reactor_class, inputs = {})
      @reactor_class = reactor_class
      @context = Context.new(inputs)
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
        RubyReactor::Worker.perform_async(serialized_context)
        RubyReactor::AsyncResult.new(job_id: nil) # TODO: Get job ID
      elsif async_execution?
        execute_step_with_retry(step_config)
      else
        execute_step_sync(step_config)
      end
    end

    def execute_step_with_retry(step_config)
      context.retry_context.current_step = step_config.name
      context.retry_context.increment_attempt_for_step(step_config.name)

      begin
        result = execute_step_sync(step_config)

        if result.is_a?(RubyReactor::Success)
          # Step succeeded, clear retry state
          context.retry_context.current_step = nil
          context.retry_context.failure_reason = nil
          context.retry_context.next_retry_at = nil
          result
        else
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
            result
          end
        end
      rescue StandardError => e
        # Handle unexpected errors the same way
        if can_retry_step?(step_config)
          requeue_job_for_step_retry(step_config, e)
          RetryQueuedResult.new(
            step_config.name,
            context.retry_context.attempts_for_step(step_config.name),
            context.retry_context.next_retry_at
          )
        else
          context.retry_context.current_step = nil
          RubyReactor::Failure(e)
        end
      end
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

        # Execute the step
        result = run_step_implementation(step_config, resolved_arguments)

        case result
        when RubyReactor::Success
          @step_results[step_config.name] = result
          @undo_stack << { step: step_config, arguments: resolved_arguments, result: result }
          context.set_result(step_config.name, result.value)
          dependency_graph.complete_step(step_config.name)
        when RubyReactor::Failure
          failure_result = handle_step_failure(step_config, result.error, resolved_arguments)
          raise Error::StepFailureError.new(failure_result.error, step: step_config.name, context: context)
        else
          # Treat non-Success/Failure results as success with that value
          success_result = RubyReactor.Success(result)
          @step_results[step_config.name] = success_result
          @undo_stack << { step: step_config, arguments: resolved_arguments, result: success_result }
          context.set_result(step_config.name, result)
          dependency_graph.complete_step(step_config.name)
        end
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

    private

    def async_execution?
      reactor_class.async?
    end

    def can_retry_step?(step_config)
      step_config.retryable? && context.retry_context.can_retry_step?(step_config.name, step_config.retry_config[:max_attempts])
    end

    def resume_execution
      # Resume execution from the current state
      # This is called when a job is requeued after a step retry
      
      # If there's a current_step, it means we need to retry that step
      if context.current_step
        step_config = reactor_class.steps[context.current_step]
        if step_config
          result = execute_step_with_retry(step_config)
          case result
          when RetryQueuedResult
            # Step was requeued again, return the result
            return result
          when RubyReactor::Success, RubyReactor::Failure
            # Step completed (success or final failure), continue with remaining steps
            execute_remaining_steps
          end
        else
          # Step not found, this is an error
          return RubyReactor::Failure("Step '#{context.current_step}' not found in reactor")
        end
      else
        # No current step, execute remaining steps
        execute_remaining_steps
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
          if result.is_a?(RetryQueuedResult)
            return result
          end
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

    private

    def async_execution?
      reactor_class.async?
    end

    def can_retry_step?(step_config)
      step_config.retryable? && context.retry_context.can_retry_step?(step_config.name, step_config.retry_config[:max_attempts])
    end

    def requeue_job_for_step_retry(step_config, error)
      context.retry_context.failure_reason = error
      attempt_number = context.retry_context.attempts_for_step(step_config.name)
      backoff_strategy = step_config.retry_config[:backoff] || reactor_class.get_retry_defaults[:backoff]
      base_delay = step_config.retry_config[:base_delay] || reactor_class.get_retry_defaults[:base_delay]
      
      delay = RetryContext.calculate_backoff_delay(attempt_number, backoff_strategy, base_delay)
      context.retry_context.next_retry_at = Time.now + delay

      # Serialize context and requeue the job
      serialized_context = ContextSerializer.serialize(context)
      RubyReactor::Worker.perform_in(delay, serialized_context)
      
      Sidekiq.logger.info("Requeued job for step '#{step_config.name}' with delay #{delay} seconds (attempt #{attempt_number})")
    end
  end
end
