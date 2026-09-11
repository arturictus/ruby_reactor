# frozen_string_literal: true

module RubyReactor
  class Step
    # The inputs one unit of work accepts: declared with `input` on a step
    # class, or inside an inline step's `inputs do ... end` block. Both forms
    # are enforced by the same `#enforce!`, so they cannot drift apart.
    class InputContract
      include RubyReactor::Dsl::ValidationHelpers

      Declaration = Struct.new(:name, :type, :optional, :default, :redact, :predicates, :macro_block, :schema,
                               :validator, keyword_init: true)

      REDACTED = "[REDACTED]"

      attr_reader :owner, :declarations, :cross_field_validators

      def initialize(owner: nil, declarations: {}, cross_field_validators: [])
        @owner = owner
        @declarations = declarations
        @cross_field_validators = cross_field_validators
      end

      # rubocop:disable Metrics/ParameterLists
      def input(name, type = nil, optional: false, default: nil, redact: false, validate: nil, **predicates, &block)
        # rubocop:enable Metrics/ParameterLists
        check_dry_validation_available!
        unless default.nil? || optional
          raise Error::ValidationError,
                "input :#{name} declares `default:` but is required; a default only applies to an " \
                "optional input, so add `optional: true`."
        end

        @declarations[name] = Declaration.new(
          name: name, type: type, optional: optional, default: default, redact: redact,
          predicates: predicates, macro_block: block, schema: validate,
          validator: build_declaration_validator(name, type, optional, validate, predicates, &block)
        )
      end

      # Cross-field rules over the whole argument hash, applied after the
      # per-input rules. A block, a dry-schema, or a dry-validation contract.
      def validate_inputs(schema = nil, &block)
        @cross_field_validators << create_input_validator(block || Validation::SchemaBuilder.schema_for(schema))
      end

      def declares?(name)
        @declarations.key?(name.to_sym)
      end

      def required_names
        @declarations.values.reject(&:optional).map(&:name)
      end

      def optional_names
        @declarations.values.select(&:optional).map(&:name)
      end

      def defaults
        @declarations.values.reject { |d| d.default.nil? }.to_h { |d| [d.name, d.default] }
      end

      def redacted_names
        @declarations.values.select(&:redact).map(&:name)
      end

      def empty?
        @declarations.empty? && @cross_field_validators.empty?
      end

      # A child's contract: the parent's declarations plus the child's, where a
      # same-named child input replaces the parent's. Neither side is mutated.
      def merge(child)
        self.class.new(
          owner: child.owner,
          declarations: @declarations.merge(child.declarations),
          cross_field_validators: @cross_field_validators + child.cross_field_validators
        )
      end

      def redact(args)
        names = redacted_names
        return args if names.empty?

        args.to_h { |key, value| [key, names.include?(key.to_sym) ? REDACTED : value] }
      end

      # Returns `args` with defaults applied — the resolved values, never the
      # schema's coerced output — or raises InputValidationError. `step_name`
      # is left for the caller, which knows it.
      def enforce!(args)
        args = apply_defaults(args)
        errors = {}

        @declarations.each_value do |declaration|
          next unless declaration.validator
          next if declaration.optional && !args.key?(declaration.name)

          # `slice`, so an absent key reads "is missing" and nil "must be filled".
          collect_errors(errors, declaration.validator.call(args.slice(declaration.name)))
        end
        @cross_field_validators.each { |validator| collect_errors(errors, validator.call(args)) }

        return args if errors.empty?

        error = Error::InputValidationError.new(errors)
        error.step_arguments = redact(args)
        raise error
      end

      private

      # Applied when the key is absent or the value is nil — never for `false`.
      def apply_defaults(args)
        defaults = self.defaults
        return args if defaults.empty?

        args.merge(defaults) { |_name, supplied, default| supplied.nil? ? default : supplied }
      end

      def collect_errors(errors, result)
        errors.merge!(result.error.field_errors) if result.failure?
      end
    end
  end
end
