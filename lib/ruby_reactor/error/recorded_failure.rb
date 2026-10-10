# frozen_string_literal: true

module RubyReactor
  module Error
    # The reason a cut-off `compensate` receives when a manual undo runs it
    # again (010 R-10): the run was aborted while it ran, and the original
    # exception cannot be rebuilt from storage. It carries that exception's
    # message, and its class name as `original_class`.
    class RecordedFailure < Base
      attr_reader :original_class

      def initialize(message, original_class:)
        super(message)
        @original_class = original_class
      end
    end
  end
end
