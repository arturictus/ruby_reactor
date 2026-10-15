# frozen_string_literal: true

module RubyReactor
  module Error
    # A class-level declaration (`queue`, ...) called outside the class's own
    # definition. Declarations are fixed for the life of the process (011
    # FR-004), so the call changes nothing and raises. Subclasses
    # ValidationError so existing `rescue Error::ValidationError` sites keep
    # catching it.
    class StaticConfigurationError < ValidationError
      MESSAGE = "Can not modify static configurations in the runtime"

      def initialize(message = MESSAGE, **options)
        super
      end
    end
  end
end
