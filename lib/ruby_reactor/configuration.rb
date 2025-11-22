# frozen_string_literal: true

require "singleton"

module RubyReactor
  # Configuration class for RubyReactor settings
  class Configuration
    include Singleton

    attr_writer :sidekiq_queue, :sidekiq_retry_count, :logger, :async_router

    def sidekiq_queue
      @sidekiq_queue ||= :default
    end

    def sidekiq_retry_count
      @sidekiq_retry_count ||= 3
    end

    def logger
      @logger ||= Logger.new($stderr)
    end

    def async_router
      @async_router ||= RubyReactor::AsyncRouter
    end

    def storage
      @storage ||= RubyReactor::Storage::Configuration.new
    end

    def storage_adapter
      @storage_adapter ||= case storage.adapter
                           when :redis
                             RubyReactor::Storage::RedisAdapter.new(url: storage.redis_url, **storage.redis_options)
                           else
                             raise "Unknown storage adapter: #{storage.adapter}"
                           end
    end
  end
end
