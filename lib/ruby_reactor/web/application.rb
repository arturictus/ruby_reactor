# frozen_string_literal: true

require "roda"
require "ruby_reactor"
require "json"
require_relative "api"

module RubyReactor
  module Web
    class Application < Roda
      plugin :static, ["/assets"], root: File.expand_path("public", __dir__)
      def serve_index(r)
        content = File.read(File.expand_path("public/index.html", __dir__))
        # Inject the base path for React Router
        # request.script_name contains the mount path (e.g. "/ruby_reactor")
        base_path = r.script_name.empty? ? "/" : r.script_name

        # Ensure trailing slash for base href to support relative assets (base: './')
        href = base_path.end_with?("/") ? base_path : "#{base_path}/"

        # Inject config and base tag
        content.sub!("<head>", "<head><base href='#{href}'><script>window.RUBY_REACTOR_BASE = '#{base_path}';</script>")
        content
      rescue Errno::ENOENT
        "UI not built. Please run `rake build:ui`"
      end
      plugin :json
      plugin :public, root: File.expand_path("public", __dir__)

      route do |r|
        # 1. Handle Root (Inject config) - MUST be before r.public
        r.root do
          serve_index(r)
        end

        # 2. Serve Static Assets (e.g. /assets/...) from public folder
        r.public

        # 3. API
        r.on "api" do
          r.run API
        end

        # 4. Fallback (Inject config for deep links)
        r.get do
          serve_index(r)
        end
      end
    end
  end
end
