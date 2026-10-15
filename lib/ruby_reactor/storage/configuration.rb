# frozen_string_literal: true

module RubyReactor
  module Storage
    class Configuration
      # `database` (ActiveRecord adapter only): a database.yml name, URL or
      # Hash for the adapter's own pool; nil uses the host's primary database.
      attr_accessor :adapter, :redis_url, :redis_options, :database

      def initialize
        @adapter = :redis
        @redis_url = "redis://localhost:6379/0"
        @redis_options = {}
      end
    end
  end
end
