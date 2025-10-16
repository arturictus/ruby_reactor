# frozen_string_literal: true

module RubyReactor
  # Configuration module for RubyReactor settings
  module Configuration
    class << self
      attr_writer :sidekiq_queue, :sidekiq_retry_count

      def configure
        yield self if block_given?
      end

      def sidekiq_queue
        @sidekiq_queue ||= :default
      end

      def sidekiq_retry_count
        @sidekiq_retry_count ||= 3
      end
    end
  end
end
