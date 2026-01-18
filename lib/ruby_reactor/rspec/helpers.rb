# frozen_string_literal: true

module RubyReactor
  module RSpec
    module Helpers
      def test_reactor(reactor_class, inputs: {}, context: {}, async: nil, process_jobs: true)
        TestSubject.new(
          reactor_class: reactor_class,
          inputs: inputs,
          context: context,
          async: async,
          process_jobs: process_jobs
        )
      end
    end
  end
end
