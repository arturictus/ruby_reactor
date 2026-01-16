# frozen_string_literal: true

module RubyReactor
  class Semaphore
    class AcquisitionError < StandardError; end

    attr_reader :key, :limit, :wait

    def initialize(key, limit: 1, wait: 0)
      @key = "semaphore:#{key}"
      @limit = limit
      @wait = wait
    end

    def acquire
      ensure_initialized

      unless adapter.semaphore_acquire(@key, timeout: @wait)
        raise AcquisitionError, "Could not acquire semaphore '#{@key}' within #{@wait} seconds"
      end

      true
    end

    def release
      adapter.semaphore_release(@key)
    end

    def synchronize
      acquire
      yield
    ensure
      release
    end

    private

    def ensure_initialized
      # Double-checked locking pattern optimized for Redis
      # 1. Optimistic check (if key exists)
      return if adapter.semaphore_exists?(@key)

      # 2. Try to init
      adapter.semaphore_init(@key, @limit)
    end

    def adapter
      RubyReactor.configuration.storage_adapter
    end
  end
end
