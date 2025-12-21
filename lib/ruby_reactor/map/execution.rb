# frozen_string_literal: true

module RubyReactor
  module Map
    class Execution
      extend Helpers

      def self.perform(arguments)
        arguments = arguments.transform_keys(&:to_sym)
        storage = RubyReactor.configuration.storage_adapter

        parent_context = load_parent_context_from_storage(
          arguments[:parent_context_id], arguments[:parent_reactor_class_name], storage
        )
        reactor_class = resolve_reactor_class(arguments[:reactor_class_info])
        inputs = ContextSerializer.deserialize_value(arguments[:serialized_inputs])

        results = execute_all_elements(
          source: inputs[:source], mappings: inputs[:mappings],
          reactor_class: reactor_class, parent_context: parent_context,
          storage_options: {
            map_id: arguments[:map_id], storage: storage,
            parent_reactor_class_name: arguments[:parent_reactor_class_name],
            strict_ordering: arguments[:strict_ordering]
          }
        )

        finalize_execution(results, parent_context, arguments[:step_name], arguments[:parent_reactor_class_name],
                           storage)
      end

      def self.execute_all_elements(source:, mappings:, reactor_class:, parent_context:, storage_options:)
        source.map.with_index do |element, index|
          element_inputs = build_element_inputs(mappings, parent_context, element)

          # Manually create and link context to ensure parent_context_id is set
          child_context = RubyReactor::Context.new(element_inputs, reactor_class)
          link_contexts(child_context, parent_context)

          executor = RubyReactor::Executor.new(reactor_class, {}, child_context)
          executor.execute
          result = executor.result

          store_result(result, index, storage_options)

          result
        end
      end

      def self.link_contexts(child_context, parent_context)
        child_context.parent_context = parent_context
        child_context.root_context = parent_context.root_context || parent_context
        child_context.test_mode = parent_context.test_mode
        child_context.inline_async_execution = parent_context.inline_async_execution
      end

      def self.store_result(result, index, options)
        value = result.success? ? result.value : { _error: result.error }
        options[:storage].store_map_result(
          options[:map_id], index, value, options[:parent_reactor_class_name],
          strict_ordering: options[:strict_ordering]
        )
      end

      def self.finalize_execution(results, parent_context, step_name, parent_reactor_class_name, storage)
        step_config = Object.const_get(parent_reactor_class_name).steps[step_name.to_sym]
        final_result = apply_collect_block(results, step_config)
        resume_parent_execution(parent_context, step_name, final_result, storage)
      end

      private_class_method :execute_all_elements, :store_result, :finalize_execution
    end
  end
end
