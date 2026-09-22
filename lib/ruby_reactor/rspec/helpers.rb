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

      # Holds `key` as an EXTERNAL owner for the duration of the block, so a
      # spec can assert against genuine lock contention (a step or reactor
      # failing/parking because something else already holds its key)
      # without reaching into `RubyReactor::Lock` or raw Redis calls itself.
      # Released even if the block raises.
      #
      #   hold_lock("acct:1") { expect(ChargeStep.run({ account_id: 1 }, nil)).to be_a(RubyReactor::Failure) }
      def hold_lock(key, owner: "spec", ttl: 30)
        lock = RubyReactor::Lock.new(key, owner: owner, ttl: ttl, wait: 0, auto_extend: true)
        lock.acquire
        yield
      ensure
        lock&.release
      end
    end
  end
end
