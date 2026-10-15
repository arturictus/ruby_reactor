# frozen_string_literal: true

module RubyReactor
  module Error
    # A control signal, never a failure (009 R-04): a fan-out map started its
    # distributed rollback and must wait for its element jobs. Raised from
    # `MapStep#compensate` / `#undo`, it unwinds the rollback without popping
    # the map's undo entry (the resume cursor), passes every `rescue
    # Error::Rescuable` (see `Rescuable.===`), and is rescued only by
    # `Executor` and `Reactor#undo`, which record where the rollback stands,
    # save, and hand the run off as `rolling_back`.
    #
    # `failure` carries the Failure the run will end with, minus its rollback
    # failures, set by the `ResultHandler` it passes through and consumed by
    # the executor of that level.
    #
    # A rollback hop (011 R-07) is the same signal aimed at a queue: the next
    # entry's undo belongs to a job there. Exactly one of `map_id` / `queue`.
    class RollbackHandedOff < Base
      attr_reader :map_id, :reactor_class_name, :queue
      attr_accessor :failure

      # `deduped`: a job for `queue` is already on its way (a replayed job), so
      # this one only stops.
      def initialize(map_id: nil, queue: nil, reactor_class_name: nil, message: nil, deduped: false)
        super(message || (queue ? "rollback hops to queue #{queue}" : "rollback handed off at map #{map_id}"))
        @map_id = map_id
        @queue = queue
        @reactor_class_name = reactor_class_name
        @deduped = deduped
      end

      def deduped? = @deduped
    end
  end
end
