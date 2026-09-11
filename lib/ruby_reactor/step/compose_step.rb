# frozen_string_literal: true

module RubyReactor
  class Step
    class ComposeStep < RubyReactor::Step
      def run
        step_name = context.current_step
        composed_data = context.composed_contexts[step_name]
        child_context = prepare_child_context(composed_data)

        # Store the child context in composed_contexts BEFORE execution
        store_child_context(step_name, child_context)

        # Execute the composed reactor
        result = execute_child_reactor(inputs[:composed_reactor_class], child_context, composed_data)

        # Update the stored context
        store_child_context(step_name, child_context)

        handle_execution_result(result)
      end

      # Compensating a failed compose and undoing a completed one are the same
      # work: roll back whatever the child reactor completed.
      def compensate
        step_name = context.current_step
        composed_data = context.composed_contexts[step_name]
        return RubyReactor.Success() unless composed_data && composed_data[:context]

        child_context = composed_data[:context]
        executor = RubyReactor::Executor.new(inputs[:composed_reactor_class], {}, child_context)
        executor.undo_all
        executor.save_context

        RubyReactor.Success()
      end

      alias undo compensate

      private

      def build_composed_inputs(mappings)
        built = {}

        mappings.each do |composed_input_name, source|
          value = source.resolve(context)
          built[composed_input_name] = value
        end

        built
      end

      def prepare_child_context(composed_data)
        child_context = composed_data ? composed_data[:context] : nil

        unless child_context
          composed_inputs = build_composed_inputs(inputs[:argument_mappings] || {})
          child_context = RubyReactor::Context.new(composed_inputs, inputs[:composed_reactor_class])
        end

        link_contexts(child_context, context)
        child_context
      end

      def link_contexts(child_context, parent_context)
        child_context.parent_context = parent_context
        child_context.root_context = parent_context.root_context || parent_context
        child_context.inline_async_execution = parent_context.inline_async_execution
      end

      def store_child_context(step_name, child_context)
        context.composed_contexts[step_name] = {
          name: step_name,
          type: :composed,
          context: child_context
        }
      end

      def execute_child_reactor(composed_reactor, child_context, composed_data)
        executor = RubyReactor::Executor.new(composed_reactor, {}, child_context)

        if composed_data && child_context.current_step
          executor.resume_execution
        else
          executor.execute
        end

        executor.result
      end

      def handle_execution_result(result)
        return result if result.is_a?(RubyReactor::DispatchResult) || result.is_a?(RubyReactor::RetryQueuedResult)

        if result.success?
          RubyReactor.Success(result.value)
        else
          RubyReactor.Failure(result.error)
        end
      end
    end
  end
end
