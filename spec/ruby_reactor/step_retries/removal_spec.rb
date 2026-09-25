# frozen_string_literal: true

require "spec_helper"

# US1: `retry_defaults` is gone. A step with no `retries` anywhere runs once,
# and nothing reads a reactor-level default.
RSpec.describe "Step retries: reactor-wide retry_defaults removed" do
  it "runs a failing step without `retries` exactly once" do
    reactor_class = Class.new(RubyReactor::Reactor) do
      step :x do
        run { |_args, _ctx| RubyReactor.Failure("boom") }
      end
    end

    reactor = reactor_class.new
    result = reactor.run({})

    expect(result).to be_failure
    expect(reactor.context.retry_context.attempts_for_step(:x)).to eq(1)
    expect(result.error.to_s).not_to start_with("failed after")
  end

  it "gives a compose step without `retries` a single attempt" do
    child = Class.new(RubyReactor::Reactor) do
      step(:inner) { run { |_args, _ctx| RubyReactor.Success(1) } }
    end
    reactor_class = Class.new(RubyReactor::Reactor) do
      compose :c, child
    end

    expect(reactor_class.steps[:c].retry_config[:max_attempts]).to eq(1)
  end

  it "gives an async_reactor step without `retries` a single attempt" do
    child = Class.new(RubyReactor::Reactor) do
      step(:inner) { run { |_args, _ctx| RubyReactor.Success(1) } }
    end
    reactor_class = Class.new(RubyReactor::Reactor) do
      async_reactor :a, child
    end

    expect(reactor_class.steps[:a].retry_config[:max_attempts]).to eq(1)
  end

  it "names a constant-named reactor in the removal error" do
    stub_const("RemovalSpecNamedReactor", Class.new(RubyReactor::Reactor))

    expect { RemovalSpecNamedReactor.class_eval { retry_defaults max_attempts: 3 } }
      .to raise_error(RubyReactor::Error::DeprecatedDslError, /RemovalSpecNamedReactor/)
  end
end
