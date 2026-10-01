# frozen_string_literal: true

module RubyReactor
  module Map
    # Shared helper methods for Map executors
    module Helpers
      # Job payloads enqueued before 009 carry `fail_fast` where they now carry
      # `atomic` (R-11, FR-023): the one place the old key is read. Removed at
      # the next MAJOR.
      def self.normalize_arguments(arguments)
        normalized = arguments.to_h.transform_keys(&:to_sym)
        normalized[:atomic] = normalized[:fail_fast] if !normalized.key?(:atomic) && normalized.key?(:fail_fast)
        normalized.delete(:fail_fast)
        normalized
      end

      # Resolves the reactor class from reactor_class_info
      def resolve_reactor_class(info)
        if info["type"] == "class"
          begin
            Object.const_get(info["name"])
          rescue NameError
            RubyReactor::Registry.find(info["name"])
          end
        elsif info["type"] == "inline"
          parent_class = Object.const_get(info["parent"])
          step_config = parent_class.steps[info["step"].to_sym]
          step_config.arguments[:mapped_reactor_class][:source].value
        else
          raise "Unknown reactor class info: #{info}"
        end
      end
      module_function :resolve_reactor_class

      # Loads parent context from storage
      def load_parent_context_from_storage(parent_context_id, reactor_class_name, storage)
        parent_context_data = storage.retrieve_context(parent_context_id, reactor_class_name)
        RubyReactor::Context.deserialize_from_retry(parent_context_data)
      end

      # Builds mapped inputs for a single element
      def build_element_inputs(mappings, parent_context, element)
        RubyReactor::Step::MapStep.build_mapped_inputs(mappings, parent_context, element)
      end
    end
  end
end
