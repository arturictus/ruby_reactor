# frozen_string_literal: true

require "spec_helper"

# US3: step-block `retries` behaves as before, and the same line in a step
# class body gives the same outcome (FR-002, FR-003).
RSpec.describe "Step retries: step-block and class declarations are equivalent" do
  # Returns a body that fails its first `fail_times` calls, then succeeds.
  def body(fail_times, calls)
    lambda do
      calls << 1
      calls.size > fail_times ? RubyReactor.Success(:ok) : RubyReactor.Failure("boom #{calls.size}")
    end
  end

  def inline_reactor(outcome)
    Class.new(RubyReactor::Reactor) do
      step :s do
        retries max_attempts: 3, backoff: :fixed, base_delay: 0
        run { |_args, _ctx| outcome.call }
      end

      returns :s
    end
  end

  def class_reactor(outcome)
    step_class = Class.new(RubyReactor::Step) do
      retries max_attempts: 3, backoff: :fixed, base_delay: 0

      define_method(:run) { outcome.call }
    end
    Class.new(RubyReactor::Reactor) do
      step :s, step_class
      returns :s
    end
  end

  def run_and_observe(reactor_class)
    reactor = reactor_class.new
    result = reactor.run({})
    {
      attempts: reactor.context.retry_context.attempts_for_step(:s),
      result_class: result.class,
      message: result.failure? ? result.error : result.value
    }
  end

  it "retries an inline step with its own `retries` until it succeeds" do
    calls = []
    observed = run_and_observe(inline_reactor(body(2, calls)))

    expect(observed).to include(attempts: 3, message: :ok)
  end

  it "retries a class step without its own policy under a step-block `retries`" do
    calls = []
    outcome = body(2, calls)
    step_class = Class.new(RubyReactor::Step) { define_method(:run) { outcome.call } }
    reactor_class = Class.new(RubyReactor::Reactor) do
      step :s, step_class do
        retries max_attempts: 3, base_delay: 0
      end
      returns :s
    end

    expect(reactor_class.steps[:s].retry_config[:max_attempts]).to eq(3)
    expect(run_and_observe(reactor_class)).to include(attempts: 3, message: :ok)
  end

  { "fail, fail, succeed" => 2, "always fail" => 99 }.each do |sequence, fail_times|
    it "gives identical outcomes for #{sequence}" do
      inline = run_and_observe(inline_reactor(body(fail_times, [])))
      klass = run_and_observe(class_reactor(body(fail_times, [])))

      expect(klass).to eq(inline)
    end
  end
end
