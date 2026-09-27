# frozen_string_literal: true

module RubyReactor
  module Error
    # `rescue Error::Rescuable` catches every exception reactor code can raise —
    # standard or not (`NotImplementedError`, `SystemStackError`, a custom
    # `Exception` subclass) — so it fails its step and rolls back (008 R-16).
    #
    # It lets through only interruptions: exceptions raised INTO running code
    # from outside it. A signal (incl. `Interrupt`, `Sidekiq::Shutdown`), an
    # exit, running out of memory, and the one an enclosing `Timeout.timeout`
    # raises — rescuing that would stop the caller's timeout from ever firing.
    # Running rollback code during any of them is unsafe; the executor marks
    # the run `aborted` for a manual undo instead.
    module Rescuable
      INTERRUPTIONS = [SignalException, SystemExit, NoMemoryError].freeze

      def self.===(exception)
        exception.is_a?(Exception) && !interruption?(exception)
      end

      def self.interruption?(exception)
        INTERRUPTIONS.any? { |klass| exception.is_a?(klass) } ||
          (defined?(::Timeout::ExitException) && exception.is_a?(::Timeout::ExitException))
      end
    end
  end
end
