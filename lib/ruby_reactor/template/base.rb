# frozen_string_literal: true

module RubyReactor
  module Template
    class Base
      def resolve(context)
        raise NotImplementedError, "Subclasses must implement #resolve"
      end

      def inspect
        "#<#{self.class.name}>"
      end
    end
  end
end