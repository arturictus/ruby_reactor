# frozen_string_literal: true

module RubyReactor
  module Dsl
    module ValidationHelpers
      # Validation helper methods
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

      # Form 1 / 1b — inline scalar or class type for a single named value.
      def build_inline_validator(name, type, optional, predicates)
        check_dry_validation_available!
        schema = RubyReactor::Validation::SchemaBuilder.build_inline(name, type, optional, predicates)
        RubyReactor::Validation::InputValidator.new(schema)
      end

      # Form 2 — block bound to the value's macro (`required`/`optional`).
      def build_macro_validator(name, optional, &block)
        check_dry_validation_available!
        schema = RubyReactor::Validation::SchemaBuilder.build_macro(name, optional, &block)
        RubyReactor::Validation::InputValidator.new(schema)
      end

      # Compose per-argument inline rules with an optional `validate_args`
      # block / pre-built schema. Returns nil when there is nothing to validate.
      def build_args_validator(inline_rules, validate_input)
        return nil if inline_rules.empty? && validate_input.nil?

        check_dry_validation_available!
        schema = RubyReactor::Validation::SchemaBuilder.build_args(inline_rules, validate_input)
        return nil unless schema

        RubyReactor::Validation::InputValidator.new(schema)
      end

      # Scalar-aware single-value validator (used by `validate_output`). The
      # value is wrapped under `:value` before validation.
      def build_scalar_validator(type, predicates)
        check_dry_validation_available!
        schema = RubyReactor::Validation::SchemaBuilder.build_inline(:value, type, false, predicates)
        RubyReactor::Validation::InputValidator.new(schema, wrap_key: :value)
      end

      private

      def check_dry_validation_available!
        return if defined?(Dry::Schema)

        raise LoadError,
              "dry-validation gem is required for validation features. Add 'gem \"dry-validation\"' to your Gemfile."
      end
    end
  end
end
