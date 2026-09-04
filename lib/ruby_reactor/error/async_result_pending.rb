# frozen_string_literal: true

module RubyReactor
  module Error
    # Raised inside a WORKER when `result(:name)` references an `async_step` /
    # `async_reactor` that is not yet terminal. Instead of blocking the worker
    # thread for the whole wait (the sync-caller behavior), the executor parks:
    # exclusive lock / semaphore stay HELD (recorded on the context), the job
    # re-enqueues itself via the snooze path, and the wait resumes on
    # redelivery. Bounded by `Configuration#async_park_timeout`, enforced at
    # the wait site before this is raised.
    class AsyncResultPending < Base
      attr_reader :channel

      def initialize(message, channel: nil)
        super(message)
        @channel = channel
      end
    end
  end
end
