# frozen_string_literal: true

module RubyReactor
  class Semaphore
    class AcquisitionError < StandardError; end

    attr_reader :key, :limit, :wait, :token

    def initialize(key, limit: 1, wait: 0)
      @key = "semaphore:#{key}"
      @limit = limit
      @wait = wait
      @token = nil
    end

    def acquire # rubocop:disable Naming/PredicateMethod
      ensure_initialized

      token = adapter.semaphore_acquire(@key, timeout: @wait)
      raise AcquisitionError, "Could not acquire semaphore '#{@key}' within #{@wait} seconds" unless token

      @token = token
      true
    end

    # Returns true if a held token was returned to the pool.
    # Idempotent: a second release (or one without a prior acquire) is a no-op.
    def release
      return false unless @token

      result = adapter.semaphore_release(@key, @token, @limit)
      @token = nil
      result
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
