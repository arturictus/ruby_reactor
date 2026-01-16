# frozen_string_literal: true

module RubyReactor
  class Lock
    class AcquisitionError < StandardError; end

    attr_reader :key, :owner, :ttl, :wait

    def initialize(key, owner:, ttl: 60, wait: 0)
      @key = "lock:#{key}"
      @owner = owner
      @ttl = ttl
      @wait = wait
    end

    def acquire
      start_time = Time.now.to_i

      loop do
        return true if adapter.lock_acquire(@key, @owner, @ttl)

        if @wait.zero? || (Time.now.to_i - start_time) >= @wait
          raise AcquisitionError, "Could not acquire lock '#{@key}' for owner '#{@owner}'"
        end

        # Exponential backoff or simple sleep
        sleep 0.1
      end
    end

    def release
      adapter.lock_release(@key, @owner)
    end

    def synchronize
      acquire
      yield
    ensure
      release
    end

    private

    def adapter
      RubyReactor.configuration.storage_adapter
    end
  end
end
