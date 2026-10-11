# frozen_string_literal: true

module RubyReactor
  module Error
    # The ActiveRecord storage schema is missing or doesn't match this gem
    # version (011 R-16). Not a SchemaVersionError: workers rescue that one as
    # a context-deserialization failure, which would turn a deployment mistake
    # into failed runs.
    class StorageSchemaError < Base
    end
  end
end
