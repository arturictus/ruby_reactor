# frozen_string_literal: true

require "roda"

module RubyReactor
  module Web
    # rubocop:disable Metrics/BlockLength
    class API < Roda
      plugin :json
      plugin :all_verbs

      route do |r|
        r.on "reactors" do
          r.is do
            # GET /api/reactors
            r.get do
              RubyReactor::Configuration.instance.storage_adapter.scan_reactors
            rescue StandardError => e
              response.status = 500
              { error: e.message, backtrace: e.backtrace.first(5) }
            end
          end

          r.on String do |reactor_id|
            # GET /api/reactors/:id
            r.get do
              raw_data = RubyReactor::Configuration.instance.storage_adapter.find_context_by_id(reactor_id)
              return { error: "Reactor not found" } unless raw_data

              # Clean data for API usage
              data = ContextSerializer.deserialize_value(raw_data)

              reactor_class = data[:reactor_class] ? Object.const_get(data[:reactor_class].to_s) : nil
              structure = {}

              structure = self.class.build_structure(reactor_class) if reactor_class.respond_to?(:steps)

              response_data = {
                id: data[:context_id],
                class: data[:reactor_class].to_s,
                status: if %w[failed paused completed running].include?(data[:status].to_s)
                          data[:status].to_s
                        elsif data[:cancelled]
                          "cancelled"
                        else
                          (data[:current_step] ? "running" : "completed")
                        end,
                current_step: data[:current_step].to_s,
                retry_count: data[:retry_count] || 0,
                undo_stack: data[:undo_stack] || [],
                step_attempts: data.dig(:retry_context, :step_attempts) || {},
                created_at: data[:started_at],
                inputs: data[:inputs],
                intermediate_results: data[:intermediate_results],
                structure: structure,
                steps: data[:execution_trace] || [],
                composed_contexts: self.class.hydrate_composed_contexts(
                  data[:composed_contexts] || {},
                  data[:reactor_class]&.to_s
                ),
                error: data[:failure_reason]
              }

              ContextSerializer.simplify_for_api(response_data)
            end

            # POST /api/reactors/:id/retry
            r.post "retry" do
              { success: true, message: "Retry scheduled" }
            end

            # POST /api/reactors/:id/cancel
            r.post "cancel" do
              { success: true, message: "Cancelled" }
            end

            # POST /api/reactors/:id/continue
            r.post "continue" do
              data = RubyReactor::Configuration.instance.storage_adapter.find_context_by_id(reactor_id)
              return { error: "Reactor not found" } unless data

              reactor_class = Object.const_get(data["reactor_class"])

              params = JSON.parse(r.body.read)
              payload = params["payload"]
              step_name = params["step_name"]

              begin
                result = reactor_class.continue(
                  id: reactor_id,
                  payload: payload,
                  step_name: step_name
                )

                if result.is_a?(RubyReactor::Failure)
                  response.status = 422
                  { error: result.error }
                else
                  { success: true, message: "Reactor resumed" }
                end
              rescue StandardError => e
                response.status = 422
                { error: e.message }
              end
            end
          end
        end
      end

      def self.build_structure(reactor_class)
        return {} unless reactor_class.respond_to?(:steps)

        steps_config = reactor_class.steps
        return {} unless steps_config.is_a?(Hash)

        # Use DependencyGraph to calculate dependencies effectively
        graph = RubyReactor::DependencyGraph.new
        steps_config.each_value { |config| graph.add_step(config) }

        steps_config.to_h do |name, config|
          type = determine_step_type(config)

          step_data = {
            name: name,
            type: type,
            depends_on: graph.dependencies[name],
            async: config.async?
          }

          if type == "compose"
            inner_class = extract_inner_class(config, :composed_reactor_class)
            step_data[:nested_structure] = build_structure(inner_class) if inner_class
          elsif type == "map"
            inner_class = extract_inner_class(config, :mapped_reactor_class)
            step_data[:nested_structure] = build_structure(inner_class) if inner_class
          end

          [name, step_data]
        end
      end

      def self.determine_step_type(config)
        if config.respond_to?(:interrupt?) && config.interrupt?
          "interrupt"
        elsif config.arguments&.key?(:composed_reactor_class)
          "compose"
        elsif config.arguments&.key?(:mapped_reactor_class)
          "map"
        elsif config.async?
          "async"
        else
          "step"
        end
      end

      def self.extract_inner_class(config, param_name)
        val = config.arguments.dig(param_name, :source)
        val.is_a?(RubyReactor::Template::Value) ? val.value : nil
      rescue StandardError
        nil
      end

      def self.hydrate_composed_contexts(composed_contexts, reactor_class_name)
        return {} unless composed_contexts.is_a?(Hash)

        composed_contexts.transform_values do |value|
          type = value[:type] || value["type"]
          if ["map_ref", :map_ref].include?(type)
            hydrate_map_ref(value, reactor_class_name)
          else
            value
          end
        end
      end

      def self.hydrate_map_ref(ref_data, reactor_class_name)
        storage = RubyReactor.configuration.storage_adapter
        map_id = ref_data[:map_id] || ref_data["map_id"]

        # Use the specific element reactor class if available, otherwise fallback to parent
        target_reactor_class = ref_data[:element_reactor_class] || ref_data["element_reactor_class"] || reactor_class_name

        # 1. Check for specific failure (O(1))
        # Stored by ResultHandler when a map element fails
        failed_context_id = storage.retrieve_map_failed_context_id(map_id, reactor_class_name)

        target_context_id = if failed_context_id
                              failed_context_id
                            else
                              # 2. Fallback to representative sample (last element) (O(1))
                              # If no failure, the last element gives a good idea of progress/completion
                              target_id = storage.retrieve_map_element_context_id(map_id, reactor_class_name, index: -1)
                              target_id
                            end

        return ref_data unless target_context_id

        # Retrieve the actual context data for the target ID
        representative_data = storage.retrieve_context(target_context_id, target_reactor_class)

        return ref_data unless representative_data

        {
          "name" => ref_data["name"],
          "type" => "map_element",
          "context" => representative_data
        }
      end
    end
    # rubocop:enable Metrics/BlockLength
  end
end
