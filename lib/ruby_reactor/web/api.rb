# frozen_string_literal: true

require "roda"
require_relative "coordination_serializer"

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

              api_status = self.class.reactor_status(data)

              response_data = {
                id: data[:context_id],
                class: data[:reactor_class].to_s,
                status: api_status,
                current_step: data[:current_step].to_s,
                retry_count: data[:retry_count] || 0,
                undo_stack: data[:undo_stack] || [],
                step_attempts: data.dig(:retry_context, :step_attempts) || {},
                created_at: data[:started_at],
                inputs: data[:inputs],
                intermediate_results: data[:intermediate_results],
                structure: structure,
                # Once per reactor, never per step: the old per-step `async`
                # field is gone because there is now exactly one hand-off point.
                background_handoff: self.class.background_handoff_for(reactor_class),
                steps: data[:execution_trace] || [],
                composed_contexts: self.class.hydrate_composed_contexts(
                  data[:composed_contexts] || {},
                  data[:reactor_class]&.to_s
                ),
                coordination: CoordinationSerializer.build(
                  reactor_class,
                  inputs: data[:inputs],
                  context_id: data[:context_id]
                ),
                error: data[:failure_reason]
              }

              ContextSerializer.simplify_for_api(response_data)
            end

            # POST /api/reactors/:id/retry
            r.post "retry" do
              data = RubyReactor::Configuration.instance.storage_adapter.find_context_by_id(reactor_id)
              unless data
                response.status = 404
                next { error: "Reactor not found" }
              end

              deserialized = ContextSerializer.deserialize_value(data)
              unless self.class.reactor_status(deserialized) == "failed"
                response.status = 422
                next { error: "Reactor can only be retried when failed" }
              end

              reactor_class_name = deserialized[:reactor_class].to_s
              reactor_class = Context.resolve_reactor_class(reactor_class_name)
              unless reactor_class
                response.status = 422
                next { error: "Reactor class '#{reactor_class_name}' not found" }
              end

              begin
                inputs = self.class.extract_retry_inputs(deserialized)
                result = reactor_class.run(inputs)
                new_id = result.execution_id

                new_reactor = reactor_class.find(new_id)
                new_reactor.context.retried_from_id = reactor_id
                new_reactor.context.retry_count = (deserialized[:retry_count] || 0) + 1
                new_reactor.send(:save_context)

                { success: true, id: new_id }
              rescue RubyReactor::Error::ValidationError => e
                response.status = 422
                { error: e.message }
              rescue StandardError => e
                response.status = 500
                { error: e.message }
              end
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

      def self.reactor_status(data)
        status = data[:status].to_s
        return status if %w[failed paused completed running skipped pending].include?(status)
        return "cancelled" if data[:cancelled]
        return "running" if data[:current_step]
        return "completed" if execution_evidence?(data)

        "pending"
      end

      def self.execution_evidence?(data)
        (data[:execution_trace] || []).any? ||
          (data[:intermediate_results] || {}).any?
      end

      def self.extract_retry_inputs(data)
        inputs = data[:inputs] || {}
        return {} unless inputs.is_a?(Hash)

        inputs.transform_keys(&:to_sym)
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
            depends_on: graph.dependencies[name]
          }

          if type == "compose"
            inner_class = extract_inner_class(config, :composed_reactor_class)
            step_data[:nested_structure] = build_structure(inner_class) if inner_class
          elsif type == "map"
            inner_class = extract_inner_class(config, :mapped_reactor_class)
            step_data[:nested_structure] = build_structure(inner_class) if inner_class
          elsif type == "async_reactor"
            # The child is a full reactor, so the dashboard can drill into its
            # own step graph exactly as it does for compose/map.
            inner_class = extract_inner_class(config, :async_reactor_class)
            step_data[:nested_structure] = build_structure(inner_class) if inner_class
          end

          [name, step_data]
        end
      end

      # The reactor's normalized `{ mode: :after|:before, step: }` hand-off pair,
      # or nil. Kept out of `build_structure` deliberately — that hash is keyed
      # by step name and the dashboard iterates it, so a non-step key there
      # would render as a phantom node.
      def self.background_handoff_for(reactor_class)
        return nil unless reactor_class.respond_to?(:background_handoff)

        reactor_class.background_handoff
      end

      def self.determine_step_type(config)
        if config.respond_to?(:interrupt?) && config.interrupt?
          "interrupt"
        elsif config.arguments&.key?(:composed_reactor_class)
          "compose"
        elsif config.arguments&.key?(:mapped_reactor_class)
          "map"
        elsif config.respond_to?(:async_dispatch)
          async_step_type(config)
        else
          "step"
        end
      end

      def self.async_step_type(config)
        case config.async_dispatch
        when :step then "async_step"
        when :reactor then "async_reactor"
        else "step"
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
          case (value[:type] || value["type"]).to_s
          when "map_ref" then hydrate_map_ref(value, reactor_class_name)
          when "async_step_ref" then hydrate_async_step_ref(value, reactor_class_name)
          when "async_reactor_ref" then hydrate_async_reactor_ref(value)
          else value
          end
        end
      end

      # The reference lives on the parent's context; the outcome lives in the
      # Step Result Record. Resolve it so the dashboard can show whether the
      # unit is still dispatched or has landed, mirroring hydrate_map_ref.
      def self.hydrate_async_step_ref(ref_data, reactor_class_name)
        context_id = ref_data[:context_id] || ref_data["context_id"]
        name = ref_data[:name] || ref_data["name"]
        return ref_data unless context_id && name

        record = RubyReactor.configuration.storage_adapter.retrieve_step_result(
          context_id, name, reactor_class_name
        )
        return ref_data unless record

        ref_data.merge("record" => record)
      end

      # An async_reactor child is an ordinary addressable execution, so its
      # state is just its own context row — the same lookup any reactor uses.
      def self.hydrate_async_reactor_ref(ref_data)
        execution_id = ref_data[:execution_id] || ref_data["execution_id"]
        child_class = ref_data[:reactor_class_name] || ref_data["reactor_class_name"]
        return ref_data unless execution_id && child_class

        child = RubyReactor.configuration.storage_adapter.retrieve_context(execution_id, child_class)
        return ref_data unless child

        ref_data.merge("context" => child)
      end

      def self.hydrate_map_ref(ref_data, reactor_class_name)
        storage = RubyReactor.configuration.storage_adapter
        map_id = ref_data[:map_id] || ref_data["map_id"]

        # Use the specific element reactor class if available, otherwise fallback to parent
        target_reactor_class = ref_data[:element_reactor_class] ||
                               ref_data["element_reactor_class"] ||
                               reactor_class_name

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
