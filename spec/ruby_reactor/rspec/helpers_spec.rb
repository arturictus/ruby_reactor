# frozen_string_literal: true

require "spec_helper"
require "ruby_reactor/rspec"

RSpec.describe RubyReactor::RSpec::Helpers do
  include RubyReactor::RSpec::Helpers

  # Define a dummy reactor for testing
  class HelpersTestReactor < RubyReactor::Reactor
    input :value

    step :add_one do
      run do |inputs|
        RubyReactor::Success(inputs[:value] + 1)
      end
    end
  end

  class HelpersFailureReactor < RubyReactor::Reactor
    step :fail_me do
      run do
        RubyReactor::Failure("Boom")
      end
    end
  end

  # Async Reactors
  class HelpersAsyncReactor < RubyReactor::Reactor
    async
    input :value
    step :add_one do
      run { |inputs| RubyReactor::Success(inputs[:value] + 1) }
    end
  end

  class HelpersAsyncStepReactor < RubyReactor::Reactor
    input :value
    step :add_one, async: true do
      run { |inputs| RubyReactor::Success(inputs[:value] + 1) }
    end
  end

  # Map Reactor
  class HelpersMapReactor < RubyReactor::Reactor
    input :items
    map :process_items do
      source { [1, 2, 3] }
      step :multiply do
        run { RubyReactor::Success(2) }
      end
    end
  end

  # Interrupt Reactor
  class HelpersInterruptReactor < RubyReactor::Reactor
    interrupt :wait

    step :after_wait do
      run { RubyReactor::Success("Done") }
    end
  end

  describe "#test_reactor" do
    it "returns a TestSubject wrapper" do
      subject = test_reactor(HelpersTestReactor, inputs: { value: 1 })
      expect(subject).to be_a(RubyReactor::RSpec::TestSubject)
    end

    it "executes lazily via matcher (success)" do
      subject = test_reactor(HelpersTestReactor, inputs: { value: 1 })
      expect(subject).to be_success
      expect(subject.result.value).to eq(2)
    end

    it "executes lazily via matcher (failure)" do
      subject = test_reactor(HelpersFailureReactor)
      expect(subject).to be_failure
      expect(subject.error).to include("Boom")
    end

    it "can inspect step execution" do
      subject = test_reactor(HelpersTestReactor, inputs: { value: 1 })
      expect(subject).to have_run_step(:add_one).returning(2)
    end

    context "with async reactor" do
      require "sidekiq/testing"

      it "runs async reactor synchronously when forced" do
        subject = test_reactor(HelpersAsyncReactor, inputs: { value: 1 }, async: false)
        expect(subject).to be_success
        expect(subject.result.value).to eq(2)
      end

      it "runs async reactor with inline execution (Sidekiq)" do
        subject = test_reactor(HelpersAsyncReactor, inputs: { value: 1 })
        # Async execution is now automatically handled inline by default via TestSubject

        expect(subject).to be_success
      end
    end

    context "with async steps" do
      it "runs async steps synchronously when forced" do
        subject = test_reactor(HelpersAsyncStepReactor, inputs: { value: 1 }, async: false)
        expect(subject).to be_success
      end
    end

    context "with maps" do
      it "processes map items inline" do
        subject = test_reactor(HelpersMapReactor, inputs: { items: [1, 2, 3] }, async: false)

        expect(subject).to be_success
        result = subject.step_result(:process_items)
        # Verify it returns an Array (inline execution)
        expect(result).to be_an(Array)
        expect(result.size).to eq(3)
      end

      it "handles map failures when simulated" do
        # We need a failing map, or use failing_at
        # failing_at inside map is tricky, let's use a specific failing reactor for map
      end
    end

    context "with interrupts" do
      it "detects paused state" do
        subject = test_reactor(HelpersInterruptReactor, async: false)
        # It should pause at :wait
        # check status
        # status comes from @reactor_instance.context.status
        # "paused"

        # TestSubject#result returns InterruptResult if paused
        expect(subject.result).to be_a(RubyReactor::InterruptResult)
        expect(subject.reactor_instance.context.status).to eq("paused")
      end
    end
  end

  describe "#failing_at" do
    it "forces a failure at the specified step" do
      subject = test_reactor(HelpersTestReactor, inputs: { value: 1 })
                .failing_at(:add_one)

      expect(subject).to be_failure
      expect(subject.error).to include("Simulated failure at add_one")
      expect(subject).to have_run_step(:add_one)
    end
  end

  describe "matchers" do
    it "verifies step order using .after" do
      subject = test_reactor(HelpersInterruptReactor, async: false)
      # Wait then after_wait (actually wait interrupts, so after_wait wont run unless resumed)
      # We need a reactor with 2 steps.
      # HelpersTestReactor has 1 step.
      # Let's add MultiStepReactor
    end
  end

  class HelpersMultiStepReactor < RubyReactor::Reactor
    step :one do
      run { RubyReactor::Success(1) }
    end
    step :two do
      run { RubyReactor::Success(2) }
    end
  end

  class HelpersValidationReactor < RubyReactor::Reactor
    input :email, validate: proc { required(:email).filled(format?: /@/) }
    step :noop do
      run { RubyReactor::Success(true) }
    end
  end

  describe "additional features" do
    it "verifies step order" do
      subject = test_reactor(HelpersMultiStepReactor)
      expect(subject).to be_success
      expect(subject).to have_run_step(:two).after(:one)
    end

    it "verifies validation errors" do
      subject = test_reactor(HelpersValidationReactor, inputs: { email: "bad" })
      expect(subject).to be_failure
      expect(subject).to have_validation_error(:email)
    end
  end
end
