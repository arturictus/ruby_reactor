# frozen_string_literal: true

require 'dry-validation'

module RubyReactor
  module Validation
    class InputValidator < Base
      attr_reader :schema

      def initialize(schema)
        @schema = schema
      end

      def call(data)
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
        
        errors.to_h.each do |key, messages|
          case messages
          when Array
            formatted[key] = messages.join(', ')
          when Hash
            # Handle nested errors by flattening them
            messages.each do |nested_key, nested_messages|
              flat_key = "#{key}[#{nested_key}]".to_sym
              formatted[flat_key] = Array(nested_messages).join(', ')
            end
          else
            formatted[key] = messages.to_s
          end
        end
        
        formatted
      end
    end
  end
end