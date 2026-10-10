# frozen_string_literal: true

module RubyReactor
  module RSpec
    # Test-only `reset!` impls layered onto storage adapters at framework
    # load time. Kept out of `lib/ruby_reactor/storage/*` so production code
    # never gains a "wipe everything" entry point.
    module StorageReset
      module RedisAdapterReset
        def reset!
          @redis.flushdb
        end
      end

      # Empties every storage table except the schema-version marker.
      module ActiveRecordAdapterReset
        def reset!
          with_db { (self.class::MODELS - [self.class::Schema]).each(&:delete_all) }
        end
      end

      # Idempotent per adapter. Called again when the ActiveRecord adapter is
      # loaded after RSpec was configured (it loads lazily, on selection).
      def self.install!
        @installed ||= {}
        install_on("RubyReactor::Storage::RedisAdapter", RedisAdapterReset)
        install_on("RubyReactor::Storage::ActiveRecordAdapter", ActiveRecordAdapterReset)
      end

      def self.install_on(class_name, reset)
        return if @installed[class_name] || !Object.const_defined?(class_name)

        Object.const_get(class_name).prepend(reset)
        @installed[class_name] = true
      end
    end
  end
end
