# frozen_string_literal: true

module RubyReactor
  class Executor
    class CompensationManager
      def initialize(context)
        @context = context
        @undo_stack = []
        @undo_trace = []
      end

      attr_reader :undo_stack, :undo_trace

      def add_to_undo_stack(step_info)
        @undo_stack << step_info
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
            context: @context,
            original_error: error
          )
        end
      end

      def rollback_completed_steps
        @undo_stack.reverse_each do |step_info|
          result = undo_step(step_info[:step], step_info[:result], step_info[:arguments])
          @undo_trace << { type: :undo, step: step_info[:step].name, result: result,
                          arguments: step_info[:arguments] }
        end
        @undo_stack.clear
      end

      private

      def compensate_step(step_config, error, arguments)
        if step_config.compensate_block
          @undo_trace << { type: :compensation, step: step_config.name, error: error, arguments: arguments }
          step_config.compensate_block.call(error, arguments, @context)
        elsif step_config.has_impl?
          @undo_trace << { type: :compensation, step: step_config.name, error: error, arguments: arguments }
          step_config.impl.compensate(error, arguments, @context)
        else
          RubyReactor.Success() # Default compensation
        end
      end

      def undo_step(step_config, result, arguments)
        if step_config.undo_block
          step_config.undo_block.call(result.value, arguments, @context)
        elsif step_config.has_impl?
          step_config.impl.undo(result.value, arguments, @context)
        end
      rescue StandardError => e
        # Log undo failure but don't halt the rollback process
        # In a real implementation, this would use a logger
        puts "Warning: Undo failed for step '#{step_config.name}': #{e.message}"
      end
    end
  end
end