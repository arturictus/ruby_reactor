# frozen_string_literal: true

module RubyReactor
  # The shared FR-005 wait core behind `result(:name)` for an `async_step` or an
  # `async_reactor` that has not finished yet. Both callers hand it a pub/sub
  # channel and a callable that returns the terminal value (or nil while the work
  # is still in flight), so there is exactly one implementation of the wait.
  #
  # The contract is "durable record answers, signal only hurries":
  #
  #   * the completing side writes its durable outcome FIRST, then publishes;
  #   * this side checks the durable target, then blocks until either the signal
  #     arrives or a coarse fallback interval elapses, then re-checks.
  #
  # Redis pub/sub is at-most-once and unpersisted, so a dropped signal must never
  # cost correctness — only fallback latency. Every exit path here goes through
  # the durable check, and the whole thing is bounded: it raises rather than
  # hanging (SC-005).
  class AsyncWaiter
    # Latency backstop for a lost signal, not a tuning surface — derived from the
    # timeout rather than configured (Principle V). The clamp guarantees ~10
    # re-checks inside any bound, so a dropped notification costs at most ~10% of
    # the wait, and never re-checks hotter than once a second.
    FALLBACK_BOUNDS = (1.0..5.0)

    attr_reader :channel, :timeout

    # @param channel [String] completion-signal channel to listen on
    # @param timeout [Numeric, nil] seconds; defaults to `async_wait_timeout`
    # @yieldreturn [Object, nil] the terminal value, or nil while still pending
    def initialize(channel:, timeout: nil, &terminal_check)
      @channel = channel
      @timeout = timeout || RubyReactor.configuration.async_wait_timeout
      @terminal_check = terminal_check
      @mutex = Mutex.new
      @condition = ConditionVariable.new
      @signalled = false
    end

    def wait
      deadline = monotonic + @timeout
      subscriber = start_subscriber

      loop do
        value = @terminal_check.call
        return value unless value.nil?

        remaining = deadline - monotonic
        raise timeout_error if remaining <= 0

        block_until_signalled_or([fallback_interval, remaining].min)
      end
    ensure
      # ponytail: killing the thread is enough — `subscribe`'s own ensure closes
      # the dedicated connection on the way out.
      subscriber&.kill
    end

    private

    def fallback_interval
      (@timeout / 10.0).clamp(FALLBACK_BOUNDS)
    end

    # Subscribing happens before the first durable check so a completion landing
    # mid-check still wakes us. The subscription is established asynchronously,
    # so this narrows the race rather than closing it outright — which is fine
    # precisely because the fallback re-check, not the signal, is what makes the
    # wait correct.
    def start_subscriber
      Thread.new do
        RubyReactor.configuration.storage_adapter.subscribe(@channel) do |_message|
          signal!
          true # stop subscribing — completion is one-shot
        end
      rescue StandardError => e
        # A waiter that loses its notification channel degrades to the fallback
        # re-check; it must not take the waiting step down with it.
        RubyReactor.configuration.logger.warn(
          "RubyReactor: async completion subscription to #{@channel} failed (#{e.class}: #{e.message}); " \
          "falling back to periodic re-checks"
        )
      end
    end

    def signal!
      @mutex.synchronize do
        @signalled = true
        @condition.broadcast
      end
    end

    def block_until_signalled_or(seconds)
      @mutex.synchronize do
        @condition.wait(@mutex, seconds) unless @signalled
        @signalled = false
      end
    end

    def timeout_error
      Error::AsyncWaitTimeoutError.new(
        "Timed out after #{@timeout}s waiting for async completion on '#{@channel}'. " \
        "The dispatched work never reached a terminal state within " \
        "`RubyReactor.configuration.async_wait_timeout` — check that a worker is running and " \
        "consuming the queue, or raise the timeout if this unit is legitimately slower."
      )
    end

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
