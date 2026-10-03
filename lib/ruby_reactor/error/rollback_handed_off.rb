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
    class RollbackHandedOff < Base
      attr_reader :map_id, :reactor_class_name
      attr_accessor :failure

      def initialize(map_id:, reactor_class_name: nil, message: "rollback handed off at map #{map_id}")
        super(message)
        @map_id = map_id
        @reactor_class_name = reactor_class_name
      end
    end
  end
end
