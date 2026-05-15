# frozen_string_literal: true

module RubyReactor
  module Dsl
    module Lockable
      def self.included(base)
        base.extend(ClassMethods)
      end

      module ClassMethods
        attr_reader :lock_config, :semaphore_config

        # Propagate lock/semaphore config to subclasses; without this a subclass
        # of a locked reactor would silently run without the lock.
        def inherited(subclass)
          super
          subclass.instance_variable_set(:@lock_config, @lock_config) if @lock_config
          subclass.instance_variable_set(:@semaphore_config, @semaphore_config) if @semaphore_config
        end

        # Configure locking for this reactor
        # @param ttl [Integer] Time to live in seconds (default: 60)
        # @param wait [Integer] Time to wait for lock in seconds (default: 0)
        # @param auto_extend [Boolean] When true (default), a background thread
        #   refreshes the lock TTL every ttl/3 seconds while the reactor runs,
        #   protecting steps that may legitimately outlast `ttl`. Pass `false`
        #   to disable and rely solely on `ttl` for expiry.
        # @yield [inputs] Block that returns the lock key string
        def with_lock(ttl: 60, wait: 0, auto_extend: true, &block)
          @lock_config = {
            ttl: ttl,
            wait: wait,
            auto_extend: auto_extend,
            key_proc: block
          }
        end

        # Configure semaphore for this reactor
        # @param limit [Integer] Maximum concurrent executions
        # @param wait [Integer] Time to wait for a token in seconds (default: 0)
        # @yield [inputs] Block that returns the semaphore key string
        def with_semaphore(limit:, wait: 0, &block)
          @semaphore_config = {
            limit: limit,
            wait: wait,
            key_proc: block
          }
        end
      end
    end
  end
end
