# frozen_string_literal: true

module RubyReactor
  module RSpec
    # Entry-point helpers (`test_reactor`), auto-included into examples tagged
    # `type: :reactor`. Specs that want them outside that tag should
    # `include RubyReactor::RSpec::Helpers` explicitly. Sidekiq-coupled helpers
    # live in `SidekiqHelpers`, scoped the same way.
    module Helpers
      # Build a `TestSubject` around a reactor invocation. Captures the run for
      # later introspection via matchers; runs the reactor lazily on first
      # query unless `.run` is called explicitly.
      def test_reactor(reactor_class, inputs, context: {}, async: nil, process_jobs: true)
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
