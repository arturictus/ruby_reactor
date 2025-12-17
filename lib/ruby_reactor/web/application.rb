require "roda"
require "ruby_reactor"
require "json"
require_relative "api"

module RubyReactor
  module Web
    class Application < Roda
      plugin :static, ["/assets"], root: File.expand_path("public", __dir__)
      plugin :json
      plugin :public, root: File.expand_path("public", __dir__)

      route do |r|
        r.public

        r.on "api" do
          r.run API
        end

        # Serve index.html for any other route (SPA fallback)
        r.get do
          File.read(File.expand_path("public/index.html", __dir__))
        rescue Errno::ENOENT
          "UI not built. Please run `rake build:ui`"
        end
      end
    end
  end
end
