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
      # First check for required inputs
      reactor_class.inputs.each do |input_name, input_config|
        next if input_config[:optional] || context.inputs.key?(input_name) || context.inputs.key?(input_name.to_s)

        raise Error::ValidationError.new(
          "Required input '#{input_name}' is missing",
          context: context
        )
      end

      # Then run validation schemas if they exist
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

        # For now, execute steps sequentially (Phase 1)
        ready_steps.each do |step_config|
          execute_step(step_config)
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
  end
end
