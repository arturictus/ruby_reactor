# frozen_string_literal: true

module RubyReactor
  module Error
    class SchemaVersionError < Base
      def initialize(message)
        super("Schema version mismatch: #{message}")
      end
    end
  end
end
