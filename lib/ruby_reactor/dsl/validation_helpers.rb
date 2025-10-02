# frozen_string_literal: true

module RubyReactor
  module Dsl
    module ValidationHelpers
      def self.included(base)
        base.extend(ClassMethods)
      end

      module ClassMethods
        def build_validation_schema(&block)
          check_dry_validation_available!
          RubyReactor::Validation::SchemaBuilder.build_from_block(&block)
        end

        def create_input_validator(schema_or_block)
          check_dry_validation_available!

          schema = case schema_or_block
                   when Proc
                     build_validation_schema(&schema_or_block)
                   else
                     schema_or_block
                   end

          RubyReactor::Validation::InputValidator.new(schema)
        end

        private

        def check_dry_validation_available!
          return if defined?(Dry::Schema)

          raise LoadError,
                "dry-validation gem is required for validation features. Add 'gem \"dry-validation\"' to your Gemfile."
        end
      end

      # Instance methods for use within step blocks
      def validate_with_schema(data, schema)
        validator = self.class.create_input_validator(schema)
        validator.call(data)
      end

      def build_schema(&block)
        self.class.build_validation_schema(&block)
      end
    end
  end
end
