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
      # work: roll back whatever the child reactor completed. Any child undo
      # that did not complete comes back on the Failure, which the parent's
      # `CompensationManager` flattens into its own `rollback_failures`.
      def compensate
        step_name = context.current_step
        composed_data = context.composed_contexts[step_name]
        return RubyReactor.Success() unless composed_data && composed_data[:context]

        child_context = composed_data[:context]
        executor = RubyReactor::Executor.new(inputs[:composed_reactor_class], {}, child_context)
        executor.undo_all
        executor.save_context

        failures = executor.compensation_manager.rollback_failures
        return RubyReactor.Success() if failures.empty?

        RubyReactor.Failure("composed :#{step_name} rollback incomplete", rollback_failures: failures)
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

        # Resume once the child has been admitted, not by its `current_step`:
        # a park two levels down unwinds the child's `with_step` and clears
        # it, and `execute` would then re-charge the child's rate limit and
        # fresh-acquire its lock instead of re-adopting the parked hold
        # (005 R-02). `current_step` stays as the fallback for a child saved
        # before `admitted` existed.
        if composed_data && (child_context.admitted? || child_context.current_step)
          executor.resume_execution
        else
          executor.execute
        end

        executor.result
      end

      def handle_execution_result(result)
        return result if result.is_a?(RubyReactor::DispatchResult) || result.is_a?(RubyReactor::RetryQueuedResult)

        # Hand the child's Failure through untouched: rebuilding it from
        # `error` alone drops validation_errors, retryability and the rest of
        # the metadata the direct and async paths do propagate.
        return result if result.is_a?(RubyReactor::Failure)

        result.success? ? RubyReactor.Success(result.value) : RubyReactor.Failure(result.error)
      end
    end
  end
end
