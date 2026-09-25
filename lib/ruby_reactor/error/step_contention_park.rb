# frozen_string_literal: true

module RubyReactor
  module Error
    # A step's own coordination was contended inside a worker: park the
    # execution at that step. Carries the `StepCoordination::Contended`, and
    # delegates `original`/`retry_after_seconds` to it so `Worker.snooze_delay`
    # and `Worker.hinted_retry?` treat it exactly like the contention it wraps.
    class StepContentionPark < ExecutionParked
      attr_reader :contended

      def initialize(contended)
        super(contended.message)
        @contended = contended
      end

      def original
        contended.original
      end

      def retry_after_seconds
        contended.retry_after_seconds
      end
    end
  end
end
