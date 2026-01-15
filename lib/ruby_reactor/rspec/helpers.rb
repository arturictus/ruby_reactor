# frozen_string_literal: true

module RubyReactor
  module RSpec
    module Helpers
      def test_reactor(reactor_class, inputs: {}, context: {}, async: nil)
        TestSubject.new(
          reactor_class: reactor_class,
          inputs: inputs,
          context: context,
          async: async
        )
      end
    end
  end
end
