# frozen_string_literal: true

require "dry-validation"

module RubyReactor
  module Validation
    class SchemaBuilder
      def self.build_from_block(&block)
        Dry::Schema.Params(&block)
      end

      def self.build_contract_from_block(&block)
        Class.new(Dry::Validation::Contract, &block).new
      end

      # Form 1 / 1b — a single named value with an optional type and predicates.
      #
      #   build_inline(:age, :integer, false, { gteq?: 18 })
      #     => required(:age).filled(:integer, gteq?: 18)
      #   build_inline(:user, User, false, {})
      #     => required(:user).filled(type?: User)
      #   build_inline(:bio, :string, true, { max_size?: 100 })
      #     => optional(:bio).maybe(:string, max_size?: 100)
      def self.build_inline(name, type, optional, predicates)
        rules = [[name, type, optional, predicates]]
        Dry::Schema.Params do
          SchemaBuilder.apply_inline_rules(self, rules)
        end
      end

      # Form 2 — the block receives the macro already bound to the name and
      # optionality (`required(name)` / `optional(name)`). Because it is invoked
      # as a block argument (not via instance_eval) the caller's `self` and
      # lexical scope (class constants, helper methods) stay reachable.
      def self.build_macro(name, optional, &block)
        macro_method = optional ? :optional : :required
        Dry::Schema.Params do
          block.call(public_send(macro_method, name))
        end
      end

      # Compose per-argument inline rules with an optional `validate_args`
      # input (block or pre-built schema). Block/inline rules are applied first;
      # a pre-built schema is merged last so its rules win.
      def self.build_args(inline_rules, validate_input)
        block = validate_input.is_a?(Proc) ? validate_input : nil
        prebuilt = !validate_input.nil? && block.nil? ? schema_for(validate_input) : nil

        composed = build_args_base(inline_rules, block)

        if prebuilt && composed
          composed.merge(prebuilt)
        elsif prebuilt
          prebuilt
        else
          composed
        end
      end

      def self.build_args_base(inline_rules, block)
        return Dry::Schema.Params(&block) if inline_rules.empty? && block
        return nil if inline_rules.empty?

        Dry::Schema.Params do
          SchemaBuilder.apply_inline_rules(self, inline_rules)
          instance_exec(&block) if block
        end
      end

      # Apply a list of inline rules ([name, type, optional, predicates]) onto a
      # dry-schema DSL context.
      def self.apply_inline_rules(dsl, rules)
        rules.each do |name, type, optional, predicates|
          macro_method = optional ? :optional : :required
          rule_method  = optional ? :maybe : :filled
          positional   = type.is_a?(Symbol) ? [type] : []
          kwargs       = type.is_a?(Module) ? { type?: type, **predicates } : predicates

          macro = dsl.public_send(macro_method, name)
          if kwargs.empty?
            macro.public_send(rule_method, *positional)
          else
            macro.public_send(rule_method, *positional, **kwargs)
          end
        end
      end

      # Unwrap an InputValidator into its underlying dry-schema; pass dry-schemas
      # through unchanged.
      def self.schema_for(schema_or_validator)
        if schema_or_validator.is_a?(RubyReactor::Validation::InputValidator)
          schema_or_validator.schema
        else
          schema_or_validator
        end
      end
    end
  end
end
