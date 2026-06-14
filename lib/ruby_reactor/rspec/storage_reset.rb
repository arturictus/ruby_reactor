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

      def self.install!
        return if @installed

        ::RubyReactor::Storage::RedisAdapter.prepend(RedisAdapterReset)
        @installed = true
      end
    end
  end
end
