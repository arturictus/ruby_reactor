# frozen_string_literal: true

require "singleton"

module RubyReactor
  # Configuration class for RubyReactor settings
  class Configuration
    include Singleton

    attr_writer :sidekiq_queue, :sidekiq_retry_count, :logger, :worker_class

    def sidekiq_queue
      @sidekiq_queue ||= :default
    end

    def sidekiq_retry_count
      @sidekiq_retry_count ||= 3
    end

    def logger
      @logger ||= Logger.new($stderr)
    end

    def worker_class
      @worker_class ||= Worker
    end
  end
end
