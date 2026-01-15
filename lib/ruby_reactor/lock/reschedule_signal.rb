# frozen_string_literal: true

module RubyReactor
  module Lock
    # Signal raised when an async job needs to be rescheduled due to lock contention
    class RescheduleSignal < StandardError
      attr_reader :delay

      def initialize(delay = 5)
        super("Snoozing execution for #{delay}s due to lock")
        @delay = delay
      end
    end
  end
end
