# frozen_string_literal: true

module RubyReactor
  module Error
    # A composed child's OWN reactor-level lock, semaphore or rate limit was
    # contended inside a worker, before the child was admitted. Nothing between
    # the child and the worker snoozes a nested executor's contention error, so
    # the child raises this park signal instead: every executor above it keeps
    # its holds, and the worker requeues the job. Carries the contention error,
    # and delegates `original`/`retry_after_seconds` to it so `Worker.snooze_delay`
    # and `Worker.hinted_retry?` treat it exactly like the error it wraps (as
    # `StepContentionPark` does).
    class ReactorContentionPark < ExecutionParked
      attr_reader :original

      def initialize(original)
        super(original.message)
        @original = original
      end

      def retry_after_seconds
        original.retry_after_seconds if original.respond_to?(:retry_after_seconds)
      end
    end
  end
end
