# frozen_string_literal: true

module RubyReactor
  module Dsl
    module Lockable
      def self.included(base)
        base.extend(ClassMethods)
      end

      module ClassMethods
        attr_reader :lock_config

        # Configure locking for this reactor
        # @param ttl [Integer] Time to live in seconds (default: 60)
        # @param wait [Integer] Time to wait for lock in seconds (default: 0)
        # @yield [inputs] Block that returns the lock key string
        def with_lock(ttl: 60, wait: 0, &block)
          @lock_config = {
            ttl: ttl,
            wait: wait,
            key_proc: block
          }
        end

        # Helper method for semaphores (future extension)
        def with_semaphore(limit:, wait: 0, &block)
          # TODO: Implement semaphore config separation if needed
          # For now, we focus on exclusive locks as per immediate plan.
        end
      end
    end
  end
end
