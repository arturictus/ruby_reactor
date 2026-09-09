# frozen_string_literal: true

module RubyReactor
  class Executor
    class CompensationManager
      def initialize(context)
        @context = context
        @undo_trace = []
      end

      def undo_stack
        @context.undo_stack
      end

      attr_reader :undo_trace

      def add_to_undo_stack(step_info)
        @context.undo_stack << step_info
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
        undo_stack.reverse_each do |step_info|
          result = @context.with_step(step_info[:step].name) do
            undo_step(step_info[:step], step_info[:result], step_info[:arguments])
          end
          @undo_trace << { type: :undo, step: step_info[:step].name, result: result,
                           arguments: step_info[:arguments] }
        end
        undo_stack.clear
      end

      private

      def middlewares
        @context.middlewares || RubyReactor::MiddlewareRunner.new([])
      end

      # Ensure we have a value to log (if it's a Success/Failure object, get the value or error)
      def loggable_value(result)
        if result.respond_to?(:value)
          result.value
        elsif result.respond_to?(:error)
          result.error
        else
          result
        end
      end

      def skipped_result?(result)
        result.respond_to?(:skipped?) && result.skipped?
      end

      def compensate_step(step_config, error, arguments)
        middlewares.on(:start_compensation, step_config.name, error, arguments, @context)
        begin
          compensate_result = catch(StepSignals::TAG) do
            if step_config.compensate_block
              step_config.compensate_block.call(error, arguments, @context)
            elsif step_config.has_impl?
              step_config.impl.compensate(error, arguments, @context)
            else
              RubyReactor.Skipped() # Default: nothing defined, rollback continues
            end
          end

          @context.execution_trace << {
            type: :compensate,
            step: step_config.name,
            timestamp: Time.now,
            result: loggable_value(compensate_result),
            arguments: arguments,
            skipped: skipped_result?(compensate_result)
          }
          @undo_trace << { type: :compensation, step: step_config.name, error: error, arguments: arguments }

          if compensate_result.is_a?(RubyReactor::Failure)
            middlewares.on(:failed_compensation, step_config.name, compensate_result, @context)
          else
            middlewares.on(:complete_compensation, step_config.name, compensate_result, @context)
          end

          compensate_result
        rescue StandardError => e
          middlewares.on(:failed_compensation, step_config.name, e, @context)
          raise e
        end
      end

      def undo_step(step_config, result, arguments)
        middlewares.on(:start_undo, step_config.name, result, arguments, @context)
        begin
          undo_result = catch(StepSignals::TAG) do
            if step_config.undo_block
              step_config.undo_block.call(result.value, arguments, @context)
            elsif step_config.has_impl?
              step_config.impl.undo(result.value, arguments, @context)
            else
              RubyReactor.Skipped() # Default: nothing defined, rollback continues
            end
          end

          @context.execution_trace << {
            type: :undo,
            step: step_config.name,
            timestamp: Time.now,
            result: loggable_value(undo_result),
            arguments: arguments,
            skipped: skipped_result?(undo_result)
          }

          if undo_result.is_a?(RubyReactor::Failure)
            middlewares.on(:failed_undo, step_config.name, undo_result, @context)
          else
            middlewares.on(:complete_undo, step_config.name, undo_result, @context)
          end

          undo_result
        rescue StandardError => e
          middlewares.on(:failed_undo, step_config.name, e, @context)
          # Log undo failure but don't halt the rollback process
          @context.execution_trace << { type: :undo_failure, step: step_config.name, timestamp: Time.now,
                                        error: e.message }
          RubyReactor.Failure(e)
        end
      end
    end
  end
end
