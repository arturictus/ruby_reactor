# frozen_string_literal: true

module RubyReactor
  module Storage
    # The completion-signal channel behind the notified wait. Pure latency
    # optimisation: at-most-once, unpersisted, never load-bearing — every waiting
    # path ends at a durable record, so a lost signal costs a fallback interval
    # and never correctness.
    module RedisPubSub
      # SUBSCRIBE puts a connection into subscriber mode — every other command on
      # it then fails — so this MUST NOT use the shared client, or one waiter
      # would poison storage for the whole process. A dedicated connection is
      # opened per subscription and closed on the way out.
      #
      # Blocks the calling thread until the block returns truthy for a message
      # (completion signals are one-shot) or the thread is killed.
      def subscribe(channel, &block)
        connection = Redis.new(@redis_config)
        connection.subscribe(channel) do |on|
          on.message { |_channel, message| connection.unsubscribe if block.call(message) }
        end
      ensure
        connection&.close
      end

      def publish(channel, message)
        @redis.publish(channel, message)
      end
    end
  end
end
