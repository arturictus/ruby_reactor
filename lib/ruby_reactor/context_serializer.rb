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

      # rubocop:disable Metrics/CyclomaticComplexity, Metrics/MethodLength
      def serialize_value(value)
        case value
        when RubyReactor::Success
          { "_type" => "Success", "value" => serialize_value(value.value) }
        when RubyReactor::Failure
          { "_type" => "Failure", "error" => serialize_value(value.error), "retryable" => value.retryable }
        when RubyReactor::Context
          { "_type" => "Context", "value" => value.serialize_for_retry }
        when Time
          { "_type" => "Time", "value" => value.iso8601 }
        when BigDecimal
          { "_type" => "BigDecimal", "value" => value.to_s("F") }
        when Rational
          { "_type" => "Rational", "numerator" => value.numerator, "denominator" => value.denominator }
        when Date
          { "_type" => "Date", "value" => value.iso8601 }
        when DateTime
          { "_type" => "DateTime", "value" => value.iso8601 }
        when Complex
          { "_type" => "Complex", "real" => value.real, "imag" => value.imag }
        when Range
          { "_type" => "Range", "begin" => serialize_value(value.begin), "end" => serialize_value(value.end),
            "exclude_end" => value.exclude_end? }
        when Regexp
          { "_type" => "Regexp", "source" => value.source, "options" => value.options }
        when ->(v) { v.respond_to?(:to_global_id) }
          { "_type" => "GlobalID", "gid" => value.to_global_id.to_s }
        when RubyReactor::Template::Element
          { "_type" => "Template::Element", "map_name" => value.map_name.to_s, "path" => value.path }
        when RubyReactor::Template::Input
          { "_type" => "Template::Input", "name" => value.name.to_s, "path" => value.path }
        when RubyReactor::Template::Value
          # Actually Template::Value holds a raw value. We should probably just serialize the raw value if possible,
          # or keep it as a template if we need to distinguish.
          # But wait, Template::Value is used to wrap raw values in arguments.
          # If we serialize it, we should probably deserialize it back to Template::Value.
          { "_type" => "Template::Value", "value" => serialize_value(value.instance_variable_get(:@value)) }
        when RubyReactor::Template::Result
          { "_type" => "Template::Result", "step_name" => value.step_name.to_s, "path" => value.path }
        when RubyReactor::Map::ResultEnumerator
          {
            "_type" => "Map::ResultEnumerator",
            "map_id" => value.map_id,
            "reactor_class_name" => value.reactor_class_name,
            "strict_ordering" => value.strict_ordering,
            "batch_size" => value.batch_size
          }
        when Hash
          value.transform_keys(&:to_s).transform_values { |v| serialize_value(v) }
        when Array
          value.map { |v| serialize_value(v) }
        else
          value
        end
      end

      def deserialize_value(value)
        case value
        when Hash
          if value.key?("_type")
            # Special serialized types (Time, BigDecimal, etc.)
            case value["_type"]
            when "Success"
              RubyReactor::Success(deserialize_value(value["value"]))
            when "Failure"
              RubyReactor::Failure(deserialize_value(value["error"]), retryable: value["retryable"])
            when "Context"
              Context.deserialize_from_retry(value["value"])
            when "Time"
              Time.iso8601(value["value"])
            when "BigDecimal"
              BigDecimal(value["value"])
            when "Rational"
              Rational(value["numerator"], value["denominator"])
            when "Date"
              Date.iso8601(value["value"])
            when "DateTime"
              DateTime.iso8601(value["value"])
            when "Complex"
              Complex(value["real"], value["imag"])
            when "Range"
              Range.new(deserialize_value(value["begin"]), deserialize_value(value["end"]), value["exclude_end"])
            when "Regexp"
              Regexp.new(value["source"], value["options"])
            when "GlobalID"
              GlobalID::Locator.locate(value["gid"])
            when "Template::Element"
              RubyReactor::Template::Element.new(value["map_name"], value["path"])
            when "Template::Input"
              RubyReactor::Template::Input.new(value["name"], value["path"])
            when "Template::Value"
              RubyReactor::Template::Value.new(deserialize_value(value["value"]))
            when "Template::Result"
              RubyReactor::Template::Result.new(value["step_name"], value["path"])
            when "Map::ResultEnumerator"
              RubyReactor::Map::ResultEnumerator.new(
                value["map_id"],
                value["reactor_class_name"],
                strict_ordering: value["strict_ordering"],
                batch_size: value["batch_size"]
              )
            else
              value
            end
          else
            # Regular hash - symbolize all keys recursively
            value.transform_keys(&:to_sym).transform_values { |v| deserialize_value(v) }
          end
        when Array
          value.map { |v| deserialize_value(v) }
        else
          value
        end
      end
      # rubocop:enable Metrics/CyclomaticComplexity, Metrics/MethodLength

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
