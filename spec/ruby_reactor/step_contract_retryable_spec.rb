# frozen_string_literal: true

require "spec_helper"

# FR-017, research.md D10: a Failure built from a step's own input-validation
# error must be non-retryable on every execution path, including through
# `compose`. Confirmed red today: neither
# `Executor::ResultHandler#build_validation_failure` nor
# `Step::ComposeStep#handle_execution_result` passes `retryable:` explicitly,
# so `RubyReactor::Failure`'s default (`error.respond_to?(:retryable?) ?
# error.retryable? : true`) resolves to `true` in both cases, because
# `Error::InputValidationError` has no `retryable?` method yet.
RSpec.describe "Input-validation failures are non-retryable" do
  before do
    stub_const("ViolatingStep", Class.new(RubyReactor::Step) do
      input :n, :integer

      def run = Success(inputs)
    end)
  end

  it "is non-retryable on the synchronous execution path (a)" do
    reactor = Class.new(RubyReactor::Reactor) do
      input :n
      step(:only, ViolatingStep) { argument :n, input(:n) }
    end

    result = reactor.run(n: "not an integer")

    expect(result).to be_failure
    expect(result.retryable?).to be(false)
  end

  it "stays non-retryable on the PARENT's Failure when the violation is inside a composed child (b)" do
    child = stub_const("ViolatingChildReactor", Class.new(RubyReactor::Reactor) do
      input :n
      step(:only, ViolatingStep) { argument :n, input(:n) }
    end)
    parent = Class.new(RubyReactor::Reactor) do
      input :n
      compose :child, child do
        argument :n, input(:n)
      end
    end

    result = parent.run(n: "not an integer")

    expect(result).to be_failure
    expect(result.retryable?).to be(false)
  end
end
