# frozen_string_literal: true

module RubyReactor
  # Utility class for handling context serialization and deserialization
  class ContextSerializer
    MAX_CONTEXT_SIZE = 512 * 1024 * 1024 # 512MB Redis limit
    SCHEMA_VERSION = "1.0"

    class << self
      def serialize(context, job_id: nil, started_at: nil)
        data = context.serialize_for_retry(job_id: job_id, started_at: started_at)
        data[:schema_version] = SCHEMA_VERSION

        serialized = JSON.generate(data)
        validate_size(serialized)

        compress_if_needed(serialized)
      end

      def deserialize(serialized_data)
        decompressed = decompress_if_needed(serialized_data)
        data = JSON.parse(decompressed, symbolize_names: false)

        validate_schema_version(data)

        Context.deserialize_from_retry(data)
      rescue JSON::ParserError => e
        raise RubyReactor::Error::DeserializationError, "Failed to parse serialized context: #{e.message}"
      end

      private

      def validate_size(data)
        size = data.bytesize
        return if size <= MAX_CONTEXT_SIZE

        raise RubyReactor::Error::ContextTooLargeError,
              "Context size #{size} bytes exceeds maximum allowed size of #{MAX_CONTEXT_SIZE} bytes"
      end

      def compress_if_needed(data)
        # For now, return uncompressed. Compression can be added later if needed
        data
      end

      def decompress_if_needed(data)
        # For now, assume uncompressed. Decompression logic can be added later
        data
      end

      def validate_schema_version(data)
        version = data["schema_version"]
        return if version == SCHEMA_VERSION

        # For now, only support exact version match
        # Future versions could handle migration
        raise RubyReactor::Error::SchemaVersionError,
              "Unsupported schema version: #{version}. Expected: #{SCHEMA_VERSION}"
      end
    end
  end
end
