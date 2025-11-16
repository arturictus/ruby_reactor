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
  end
end
