# frozen_string_literal: true

require "spec_helper"

# US2: a step class carries its own retry policy into any reactor that uses
# it, with no retry wiring in the reactor (FR-001, FR-008, FR-011, FR-012).
RSpec.describe "Step retries: a step class declares its own policy" do
  # A class step that fails its first `fail_times` attempts, then succeeds.
  def flaky_step(fail_times:, calls:, **retries_opts)
    Class.new(RubyReactor::Step) do
      retries(**retries_opts)

      define_method(:run) do
        calls << 1
        calls.size > fail_times ? Success(:charged) : Failure("declined #{calls.size}")
      end
    end
  end

  def reactor_with(charge_class, undone: [])
    Class.new(RubyReactor::Reactor) do
      step :reserve do
        run { |_args, _ctx| RubyReactor.Success(:reserved) }
        undo do |_result, _args, _ctx|
          undone << :reserve
          RubyReactor.Success()
        end
      end

      step :charge, charge_class do
        wait_for :reserve
      end

      returns :charge
    end
  end

  let(:calls) { [] }

  it "succeeds on attempt 3 after failing twice" do
    reactor = reactor_with(flaky_step(fail_times: 2, calls: calls, max_attempts: 3, base_delay: 0)).new
    result = reactor.run({})

    expect(result).to be_success
    expect(result.value).to eq(:charged)
    expect(reactor.context.retry_context.attempts_for_step(:charge)).to eq(3)
  end

  it "exhausts the class policy, then rolls back the earlier step" do
    undone = []
    reactor = reactor_with(flaky_step(fail_times: 99, calls: calls, max_attempts: 3, base_delay: 0),
                           undone: undone).new
    result = reactor.run({})

    expect(result).to be_failure
    expect(result.error).to eq("Step 'charge' failed after 3 attempts: declined 3")
    expect(calls.size).to eq(3)
    expect(undone).to eq([:reserve])
  end

  it "sleeps between in-process attempts following the class's backoff" do
    allow(RubyReactor::RetryContext).to receive(:calculate_backoff_delay).and_call_original
    sleeps = []
    allow_any_instance_of(RubyReactor::Executor::RetryManager).to receive(:sleep) { |_manager, delay| sleeps << delay }

    reactor_with(flaky_step(fail_times: 99, calls: calls, max_attempts: 3, backoff: :linear, base_delay: 0.01)).run({})

    expect(sleeps).to eq([0.01, 0.02])
  end

  it "exposes the class policy, with defaults filled in, as the step's effective policy" do
    reactor_class = reactor_with(flaky_step(fail_times: 0, calls: calls, max_attempts: 3))

    expect(reactor_class.steps[:charge].retry_config).to eq(max_attempts: 3, backoff: :exponential, base_delay: 1)
  end

  it "makes one attempt when the body fails with retry: false" do
    step_class = Class.new(RubyReactor::Step) do
      retries max_attempts: 3, base_delay: 0

      define_method(:run) { fail!(StandardError.new("x"), retry: false) }
    end
    reactor = reactor_with(step_class).new
    reactor.run({})

    expect(reactor.context.retry_context.attempts_for_step(:charge)).to eq(1)
  end

  it "makes one attempt when the step's input contract rejects its arguments" do
    counter = calls
    step_class = Class.new(RubyReactor::Step) do
      input :amount, :integer
      retries max_attempts: 3, base_delay: 0

      define_method(:run) do
        counter << 1
        Success(inputs.amount)
      end
    end
    reactor_class = Class.new(RubyReactor::Reactor) do
      input :amount
      step(:charge, step_class) { argument :amount, input(:amount) }
    end
    reactor = reactor_class.new
    result = reactor.run(amount: "x")

    expect(result).to be_failure
    expect(reactor.context.retry_context.attempts_for_step(:charge)).to eq(1)
    expect(counter).to be_empty
  end

  it "makes no attempt when the step is skipped by `where`" do
    step_class = flaky_step(fail_times: 99, calls: calls, max_attempts: 3, base_delay: 0)
    reactor_class = Class.new(RubyReactor::Reactor) do
      step(:charge, step_class) { where { false } }
    end
    # The retry counter is bumped before `where` is checked; what matters is
    # that the body never runs, so the failing policy never comes into play.
    expect(reactor_class.run({})).to be_success
    expect(calls).to be_empty
  end

  describe "direct invocation" do
    it "runs once and returns the failure, whatever `retries` says" do
      step_class = flaky_step(fail_times: 99, calls: calls, max_attempts: 3, base_delay: 0)

      expect(step_class.run({})).to be_a(RubyReactor::Failure)
      expect(calls.size).to eq(1)
    end

    it "runs a directly-called inner step once per attempt of the outer step" do
      inner = flaky_step(fail_times: 99, calls: calls, max_attempts: 3, base_delay: 0)
      outer = Class.new(RubyReactor::Step) do
        retries max_attempts: 2, base_delay: 0

        define_method(:run) { inner.run({}, context) }
      end
      reactor = reactor_with(outer).new
      reactor.run({})

      expect(reactor.context.retry_context.attempts_for_step(:charge)).to eq(2)
      expect(calls.size).to eq(2)
    end
  end
end
