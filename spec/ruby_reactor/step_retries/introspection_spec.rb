# frozen_string_literal: true

require "spec_helper"

# US7: the effective policy and where it came from can be looked up, and a
# class policy is observable like any other (FR-014, FR-016).
RSpec.describe "Step retries: introspection" do
  let(:declaring_class) { Class.new(RubyReactor::Step) { retries max_attempts: 3, base_delay: 0 } }
  let(:bare_class) { Class.new(RubyReactor::Step) }
  let(:reactor_class) do
    declaring = declaring_class
    bare = bare_class
    Class.new(RubyReactor::Reactor) do
      step :from_class, declaring
      step(:from_block, bare) { retries max_attempts: 5, backoff: :linear, base_delay: 2 }
      step(:inline) { run { |_args, _ctx| RubyReactor.Success() } }
    end
  end

  it "reports where each step's policy comes from" do
    expect(reactor_class.steps.transform_values(&:retry_source))
      .to eq(from_class: :step_class, from_block: :step_block, inline: :none)
  end

  it "reports each step's effective policy" do
    steps = reactor_class.steps

    expect(steps[:from_class].retry_config).to eq(max_attempts: 3, backoff: :exponential, base_delay: 0)
    expect(steps[:from_block].retry_config).to eq(max_attempts: 5, backoff: :linear, base_delay: 2)
    expect(steps[:inline].retry_config).to eq(RubyReactor::Dsl::StepConfig::NO_RETRIES)
    expect(steps[:inline]).not_to be_retryable
  end

  it "emits a retry_attempt event per retry of a class step" do
    events = []
    middleware = Class.new(RubyReactor::Middleware) do
      define_method(:on_retry_attempt) { |step_name, attempt, _error, _context| events << [step_name, attempt] }
    end
    step_class = Class.new(RubyReactor::Step) do
      retries max_attempts: 3, base_delay: 0

      def run = Failure("x")
    end
    reactor = Class.new(RubyReactor::Reactor) do
      middleware middleware
      step :charge, step_class
    end

    reactor.run({})

    expect(events).to eq([[:charge, 1], [:charge, 2]])
  end
end
