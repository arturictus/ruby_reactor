# frozen_string_literal: true

module RubyReactor
  module Error
    # Definition-time error for DSL that has been removed. Subclasses
    # ValidationError so existing `rescue Error::ValidationError` sites keep
    # catching it.
    class DeprecatedDslError < ValidationError
    end
  end
end
