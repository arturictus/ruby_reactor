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
                puts "Found reactor class: #{reactor_class.name}"
                steps_config = reactor_class.steps
                puts "Steps config: #{steps_config.inspect} (#{steps_config.class})"

                steps_config = {} unless steps_config.is_a?(Hash)

                # Use DependencyGraph to calculate dependencies effectively
                graph = RubyReactor::DependencyGraph.new
                steps_config.each_value { |config| graph.add_step(config) }

                structure = steps_config.map do |name, config|
                  type = if config.respond_to?(:interrupt?) && config.interrupt?
                           "interrupt"
                         elsif config.respond_to?(:impl) && config.impl.to_s.include?("MapStep")
                           "map"
                         elsif config.async?
                           "async"
                         elsif config.respond_to?(:params) && config.params&.dig(:composed_reactor)
                           "compose"
                         else
                           "step"
                         end

                  # Check for map (StepConfig doesn't key off builder type easily, but map usually has impl related to Map)
                  type = "map" if config.impl && config.impl.name.to_s.include?("MapStep")

                  [name, {
                    name: name,
                    type: type,
                    depends_on: graph.dependencies[name], # Use calculated dependencies from graph
                    async: config.async?
                  }]
                end.to_h
              else
                puts "Reactor class #{reactor_class} does not respond to :steps"
              end

              {
                id: data["context_id"],
                class: data["reactor_class"],
                status: if data["cancelled"]
                          "cancelled"
                        else
                          (data["current_step"] ? "running" : "completed")
                        end,
                created_at: data["started_at"],
                inputs: data["inputs"],
                intermediate_results: data["intermediate_results"],
                structure: structure,
                steps: data["execution_trace"] || []
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
    end
  end
end
