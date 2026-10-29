# frozen_string_literal: true

module RubyReactor
  module Error
    # A park on another queue (011 R-05): the run reached a node whose queue is
    # not the current job's. Every executor on the stack parks its holds and
    # saves, as for any park; the Worker then enqueues the continuation on
    # `queue` instead of snoozing. `deduped`: a job for that queue is already
    # on its way, so this one only stops.
    class QueueHop < ExecutionParked
      attr_reader :queue, :step

      def initialize(queue:, step:, deduped: false)
        super("queue hop to #{queue} at #{step}")
        @queue = queue
        @step = step
        @deduped = deduped
      end

      def deduped? = @deduped
    end
  end
end
