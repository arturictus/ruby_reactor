# frozen_string_literal: true

module RubyReactor
  class Lock
    class AcquisitionError < StandardError; end

    # Minimum interval between auto-extend pings; protects very small TTLs.
    MIN_EXTEND_INTERVAL = 1.0

    attr_reader :key, :owner, :ttl, :wait, :auto_extend

    def initialize(key, owner:, ttl: 60, wait: 0, auto_extend: true)
      @key = "lock:#{key}"
      @owner = owner
      @ttl = ttl
      @wait = wait
      @auto_extend = auto_extend
      @extender = nil
      @extender_running = false
    end

    def acquire
      start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      loop do
        if adapter.lock_acquire(@key, @owner, @ttl)
          start_extender if @auto_extend
          return true
        end

        if @wait.zero? || (Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time) >= @wait
          raise AcquisitionError, "Could not acquire lock '#{@key}' for owner '#{@owner}'"
        end

        sleep 0.1
      end
    end

    def release
      stop_extender
      adapter.lock_release(@key, @owner)
    end

    def synchronize
      acquire
      yield
    ensure
      release
    end

    private

    def start_extender
      return if @extender&.alive?

      interval = [@ttl / 3.0, MIN_EXTEND_INTERVAL].max
      @extender_running = true

      @extender = Thread.new do
        while @extender_running
          sleep interval
          break unless @extender_running

          begin
            adapter.lock_extend(@key, @owner, @ttl)
          rescue StandardError => e
            RubyReactor.configuration.logger.warn(
              "Lock auto-extend failed for '#{@key}': #{e.message}"
            )
            break
          end
        end
      end
    end

    def stop_extender
      @extender_running = false
      thread = @extender
      @extender = nil
      return unless thread

      thread.wakeup if thread.alive?
      thread.join(0.1)
    rescue StandardError
      # Best-effort shutdown; never let extender teardown break release.
    end

    def adapter
      RubyReactor.configuration.storage_adapter
    end
  end
end
