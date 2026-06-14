# frozen_string_literal: true

module RubyReactor
  module RSpec
    # Globally-included helpers. Only methods whose names clearly belong to
    # RubyReactor's test surface live here (`test_reactor`). Sidekiq-coupled
    # helpers live in `SidekiqHelpers` and are scoped to `type: :reactor`.
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
