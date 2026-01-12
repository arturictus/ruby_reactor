# frozen_string_literal: true

module RubyReactor
  module Template
    class DynamicSource < Base
      attr_reader :block, :argument_mappings

      def initialize(argument_mappings, &block)
        super()
        @block = block
        @argument_mappings = argument_mappings
      end

      def resolve(context)
        args = {}
        @argument_mappings.each do |name, source|
          # Handle serialized template objects if necessary, similar to MapStep logic
          # But here we assume source is a Template object that responds to resolve
          next if source.is_a?(RubyReactor::Template::Element)

          args[name] = if source.respond_to?(:resolve)
                         source.resolve(context)
                       else
                         source
                       end
        end

        @block.call(args, context)
      end
    end
  end
end
