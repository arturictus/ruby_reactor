# frozen_string_literal: true

require "dry-validation"

module RubyReactor
  module Validation
    class InputValidator < Base
      attr_reader :schema, :wrap_key

      def initialize(schema, wrap_key: nil)
        super()
        @schema = schema
        @wrap_key = wrap_key
      end

      def call(data)
        data = { @wrap_key => data } if @wrap_key
        result = schema.call(data)

        if result.success?
          success(result.to_h)
        else
          failure(format_errors(result.errors))
        end
      end

      private

      def format_errors(errors)
        formatted = {}
        flatten_errors(errors.to_h, formatted, [])
        formatted
      end

      def flatten_errors(errors_hash, formatted, path)
        errors_hash.each do |key, messages|
          current_path = path + [key]

          case messages
          when Array
            # This is a leaf node with error messages
            flat_key = if current_path.size == 1
                         current_path.first.to_s
                       else
                         "#{current_path.first}#{current_path[1..].map { |k| "[#{k}]" }.join}"
                       end
            formatted[flat_key.to_sym] = messages.join(", ")
          when Hash
            # This is a nested structure, recurse
            flatten_errors(messages, formatted, current_path)
          else
            # Single message
            flat_key = if current_path.size == 1
                         current_path.first.to_s
                       else
                         "#{current_path.first}#{current_path[1..].map { |k| "[#{k}]" }.join}"
                       end
            formatted[flat_key.to_sym] = messages.to_s
          end
        end
      end
    end
  end
end
