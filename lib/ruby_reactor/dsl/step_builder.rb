# frozen_string_literal: true

module RubyReactor
  module Dsl
    class StepBuilder
      include RubyReactor::Dsl::TemplateHelpers
      include RubyReactor::Dsl::ValidationHelpers

      attr_accessor :name, :impl, :arguments, :run_block, :compensate_block, :undo_block, :conditions, :guards,
                    :dependencies, :args_validator, :output_validator

      def initialize(name, impl = nil)
        @name = name
        @impl = impl
        @arguments = {}
        @run_block = nil
        @compensate_block = nil
        @undo_block = nil
        @conditions = []
        @guards = []
        @dependencies = []
        @args_validator = nil
        @output_validator = nil
      end

      def argument(name, source, transform: nil)
        @arguments[name] = {
          source: source,
          transform: transform
        }
      end

      def run(&block)
        @run_block = block
      end

      def compensate(&block)
        @compensate_block = block
      end

      def undo(&block)
        @undo_block = block
      end

      def where(&predicate)
        @conditions << predicate
      end

      def guard(&guard_fn)
        @guards << guard_fn
      end

      def wait_for(*step_names)
        @dependencies.concat(step_names)
      end

      def validate_args(schema_or_validator = nil, &block)
        if block_given?
          @args_validator = build_input_validator(block)
        elsif schema_or_validator
          @args_validator = build_input_validator(schema_or_validator)
        end
      end

      def validate_output(schema_or_validator = nil, &block)
        if block_given?
          @output_validator = build_input_validator(block)
        elsif schema_or_validator
          @output_validator = build_input_validator(schema_or_validator)
        end
      end

      def build
        step_config = {
          name: @name,
          impl: @impl,
          arguments: @arguments,
          run_block: @run_block,
          compensate_block: @compensate_block,
          undo_block: @undo_block,
          conditions: @conditions,
          guards: @guards,
          dependencies: @dependencies,
          args_validator: @args_validator,
          output_validator: @output_validator
        }

        RubyReactor::Dsl::StepConfig.new(step_config)
      end

      private

      def build_input_validator(schema_or_block)
        check_dry_validation_available!

        schema = case schema_or_block
                 when Proc
                   build_validation_schema(&schema_or_block)
                 else
                   schema_or_block
                 end

        RubyReactor::Validation::InputValidator.new(schema)
      end

      def build_validation_schema(&block)
        RubyReactor::Validation::SchemaBuilder.build_from_block(&block)
      end

      def check_dry_validation_available!
        return if defined?(Dry::Schema)

        raise LoadError,
              "dry-validation gem is required for validation features. Add 'gem \"dry-validation\"' to your Gemfile."
      end
    end

    class StepConfig
      attr_reader :name, :impl, :arguments, :run_block, :compensate_block, :undo_block, :conditions, :guards,
                  :dependencies, :args_validator, :output_validator

      def initialize(config)
        @name = config[:name]
        @impl = config[:impl]
        @arguments = config[:arguments] || {}
        @run_block = config[:run_block]
        @compensate_block = config[:compensate_block]
        @undo_block = config[:undo_block]
        @conditions = config[:conditions] || []
        @guards = config[:guards] || []
        @dependencies = config[:dependencies] || []
        @args_validator = config[:args_validator]
        @output_validator = config[:output_validator]
      end

      def impl?
        !@impl.nil?
      end

      def run_block?
        !@run_block.nil?
      end

      def should_run?(context)
        @conditions.all? { |condition| condition.call(context) } &&
          @guards.all? { |guard| guard.call(context) }
      end
    end
  end
end
