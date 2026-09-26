# frozen_string_literal: true

module RubyReactor
  class Step
    # What step code (`run`, `undo`, `compensate`) receives as its inputs: a
    # frozen, read-only view of the argument Hash with one reader per name the
    # step may read. Any other name raises `Error::UndeclaredInputError` on the
    # line that reads it, instead of returning nil and failing somewhere else.
    #
    #   inputs.order_guid      # the value, or nil for an absent optional input
    #   inputs.order_id        # raises UndeclaredInputError
    #   inputs.to_h            # supplied values, readable names only
    #   Service.call(**inputs) # via `to_hash`
    #
    # Readable names are the contract's declarations, or the keys present when
    # the step has none. Built only where inputs reach step code; everything
    # else in the gem keeps the Hash.
    class Inputs
      def initialize(values, contract: nil, owner: nil)
        @values = values.to_h
        @owner = owner
        declared = contract&.declarations&.keys || []
        @names = declared.empty? ? @values.keys.map(&:to_sym).uniq : declared
        @redacted = contract&.redacted_names || []
        freeze
      end

      def to_h
        @names.each_with_object({}) do |name, hash|
          hash[name] = Utils::FetchIndifferent.call(@values, name) if supplied?(name)
        end
      end
      alias to_hash to_h

      def inspect
        to_h.to_h { |name, value| [name, @redacted.include?(name) ? InputContract::REDACTED : value] }.inspect
      end

      private

      def method_missing(name, *args)
        return Utils::FetchIndifferent.call(@values, name) if args.empty? && @names.include?(name)

        declared = @names.empty? ? "none" : @names.map(&:inspect).join(", ")
        raise Error::UndeclaredInputError.new("#{@owner} has no input :#{name}. Declared inputs: #{declared}.", name)
      end

      def respond_to_missing?(name, include_private = false)
        @names.include?(name) || super
      end

      def supplied?(name)
        @values.key?(name) || @values.key?(name.to_s)
      end
    end
  end
end
