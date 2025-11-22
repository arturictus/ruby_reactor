# frozen_string_literal: true

module RubyReactor
  module Storage
    class Configuration
      attr_accessor :adapter, :redis_url, :redis_options

      def initialize
        @adapter = :redis
        @redis_url = "redis://localhost:6379/0"
        @redis_options = {}
      end
    end
  end
end
