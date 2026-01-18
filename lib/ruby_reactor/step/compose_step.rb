# frozen_string_literal: true

module RubyReactor
  module Step
    class ComposeStep
      include RubyReactor::Step

      attr_reader :composed_reactor_class, :argument_mappings

      def initialize(composed_reactor_class, argument_mappings = {})
        @composed_reactor_class = composed_reactor_class
        @argument_mappings = argument_mappings
      end

      def self.run(arguments, context)
        step_name = context.current_step
        composed_data = context.composed_contexts[step_name]
        child_context = prepare_child_context(arguments, context, composed_data)

        # Store the child context in composed_contexts BEFORE execution
        store_child_context(context, step_name, child_context)

        # Execute the composed reactor
        result = execute_child_reactor(arguments[:composed_reactor_class], child_context, composed_data)

        # Update the stored context
        store_child_context(context, step_name, child_context)

        handle_execution_result(result)
      end

      def self.compensate(_reason, arguments, context)
        step_name = context.current_step
        composed_data = context.composed_contexts[step_name]
        return RubyReactor.Success() unless composed_data && composed_data[:context]

        child_context = composed_data[:context]
        executor = RubyReactor::Executor.new(arguments[:composed_reactor_class], {}, child_context)
        executor.undo_all
        executor.save_context

        RubyReactor.Success()
      end

      def self.undo(_result, arguments, context)
        step_name = context.current_step
        composed_data = context.composed_contexts[step_name]
        return RubyReactor.Success() unless composed_data && composed_data[:context]

        child_context = composed_data[:context]
        executor = RubyReactor::Executor.new(arguments[:composed_reactor_class], {}, child_context)
        executor.undo_all
        executor.save_context

        RubyReactor.Success()
      end

      class << self
        private

        def build_composed_inputs(mappings, context)
          inputs = {}

          mappings.each do |composed_input_name, source|
            value = source.resolve(context)
            inputs[composed_input_name] = value
          end

          inputs
        end

        def prepare_child_context(arguments, context, composed_data)
          child_context = composed_data ? composed_data[:context] : nil

          unless child_context
            composed_inputs = build_composed_inputs(arguments[:argument_mappings] || {}, context)
            child_context = RubyReactor::Context.new(composed_inputs, arguments[:composed_reactor_class])
          end

          link_contexts(child_context, context)
          child_context
        end

        def link_contexts(child_context, parent_context)
          child_context.parent_context = parent_context
          child_context.root_context = parent_context.root_context || parent_context
          child_context.inline_async_execution = parent_context.inline_async_execution
        end

        def store_child_context(context, step_name, child_context)
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
          return result if result.is_a?(RubyReactor::AsyncResult) || result.is_a?(RubyReactor::RetryQueuedResult)

          if result.success?
            RubyReactor.Success(result.value)
          else
            RubyReactor.Failure(result.error)
          end
        end
      end
    end
  end
end
