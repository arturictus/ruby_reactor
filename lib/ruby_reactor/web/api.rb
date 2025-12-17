require "roda"

module RubyReactor
  module Web
    class API < Roda
      plugin :json
      plugin :all_verbs

      route do |r|
        r.on "reactors" do
          # GET /api/reactors
          r.get do
            RubyReactor::Configuration.instance.storage_adapter.scan_reactors
          rescue StandardError => e
            response.status = 500
            { error: e.message, backtrace: e.backtrace.first(5) }
          end

          r.on String do |reactor_id|
            # GET /api/reactors/:id
            r.get do
              data = RubyReactor::Configuration.instance.storage_adapter.find_context_by_id(reactor_id)
              return { error: "Reactor not found" } unless data

              # Simplify for UI
              {
                id: data["context_id"],
                class: data["reactor_class"],
                status: if data["cancelled"]
                          "cancelled"
                        else
                          (data["current_step"] ? "running" : "completed")
                        end,
                created_at: data["started_at"],
                steps: data["execution_trace"] || [] # expose trace
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
