require "roda"

module RubyReactor
  module Web
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
              data = RubyReactor::Configuration.instance.storage_adapter.find_context_by_id(reactor_id)
              return { error: "Reactor not found" } unless data

              reactor_class = data["reactor_class"] ? Object.const_get(data["reactor_class"]) : nil
              structure = {}

              if reactor_class && reactor_class.respond_to?(:steps)
                structure = self.class.build_structure(reactor_class)
              end

              {
                id: data["context_id"],
                class: data["reactor_class"],
                status: if %w[failed paused completed].include?(data["status"])
                          data["status"]
                        elsif data["cancelled"]
                          "cancelled"
                        else
                          (data["current_step"] ? "running" : "completed")
                        end,
                retry_count: data["retry_count"] || 0,
                undo_stack: data["undo_stack"] || [],
                step_attempts: data.dig("retry_context", "step_attempts") || {},
                created_at: data["started_at"],
                inputs: data["inputs"],
                intermediate_results: data["intermediate_results"],
                structure: structure,
                steps: data["execution_trace"] || [],
                composed_contexts: data["composed_contexts"] || {},
                error: data["failure_reason"]
              }
            end

            # POST /api/reactors/:id/retry
            r.post "retry" do
              { success: true, message: "Retry scheduled" }
            end

            # POST /api/reactors/:id/cancel
            r.post "cancel" do
              { success: true, message: "Cancelled" }
            end
          end
        end
      end

      def self.build_structure(reactor_class)
        return {} unless reactor_class&.respond_to?(:steps)

        steps_config = reactor_class.steps
        return {} unless steps_config.is_a?(Hash)

        # Use DependencyGraph to calculate dependencies effectively
        graph = RubyReactor::DependencyGraph.new
        steps_config.each_value { |config| graph.add_step(config) }

        steps_config.map do |name, config|
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
        end.to_h
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
    end
  end
end
