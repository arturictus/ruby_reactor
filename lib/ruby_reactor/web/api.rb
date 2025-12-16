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
            # TODO: Fetch real reactors from storage
            [
              { id: "123", class: "MyReactor", status: "running", created_at: Time.now.to_s },
              { id: "124", class: "OrderReactor", status: "completed", created_at: Time.now.to_s }
            ]
          end

          r.on String do |reactor_id|
            # GET /api/reactors/:id
            r.get do
              { id: reactor_id, class: "MyReactor", status: "running", steps: [] }
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
