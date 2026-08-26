# frozen_string_literal: true

require "spec_helper"
require "ruby_reactor/rspec"

RSpec.describe RubyReactor::RSpec::Helpers do
  include described_class

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
    background all: true
    input :value
    step :add_one do
      run { |inputs| RubyReactor::Success(inputs[:value] + 1) }
    end
  end

  class HelpersAsyncStepReactor < RubyReactor::Reactor
    input :value
    step :add_one do
      run { |inputs| RubyReactor::Success(inputs[:value] + 1) }
    end

    background before: :add_one
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

  # Interrupt Reactor with Validation for testing resume
  class HelpersInterruptWithValidationReactor < RubyReactor::Reactor
    input :user_id

    step :prepare do
      argument :user_id, input(:user_id)
      run { |args| RubyReactor::Success("prepared-#{args[:user_id]}") }
    end

    interrupt :approval do
      wait_for :prepare

      validate do
        required(:approved).filled(:bool)
        required(:approver).filled(:string)
      end
    end

    step :finalize do
      argument :approval_data, result(:approval)
      run { |args| RubyReactor::Success("finalized-by-#{args[:approval_data][:approver]}") }
    end
  end

  describe "#test_reactor" do
    it "returns a TestSubject wrapper" do
      subject = test_reactor(HelpersTestReactor, { value: 1 })
      expect(subject).to be_a(RubyReactor::RSpec::TestSubject)
    end

    it "executes lazily via matcher (success)" do
      subject = test_reactor(HelpersTestReactor, { value: 1 })
      expect(subject).to be_success
      expect(subject.result.value).to eq(2)
    end

    it "executes lazily via matcher (failure)" do
      subject = test_reactor(HelpersFailureReactor, {})
      expect(subject).to be_failure
      expect(subject.error).to include("Boom")
    end

    it "can inspect step execution" do
      subject = test_reactor(HelpersTestReactor, { value: 1 })
      expect(subject).to have_run_step(:add_one).returning(2)
    end

    context "with async reactor" do
      require "sidekiq/testing"

      it "runs async reactor synchronously when forced" do
        subject = test_reactor(HelpersAsyncReactor, { value: 1 }, async: false)
        expect(subject).to be_success
        expect(subject.result.value).to eq(2)
      end

      it "runs async reactor with inline execution (Sidekiq)" do
        subject = test_reactor(HelpersAsyncReactor, { value: 1 })
        # Async execution is now automatically handled inline by default via TestSubject

        expect(subject).to be_success
      end

      it "enqueues async job but does not execute when process_jobs is false" do
        subject = test_reactor(HelpersAsyncReactor, { value: 1 }, process_jobs: false)
        # Ensure it didn't run (status is likely nil or running, result returns nil for unknown/running)
        expect(subject.result).to be_a(RubyReactor::Failure)
        expect(subject.result.error).to include("Reactor is still running")
        # Ensure it enqueued (returned AsyncResult)
        expect(subject.run_result).to be_a(RubyReactor::AsyncResult)
      end
    end

    context "with async steps" do
      it "runs async steps synchronously when forced" do
        subject = test_reactor(HelpersAsyncStepReactor, { value: 1 }, async: false)
        expect(subject).to be_success
      end
    end

    context "with maps" do
      it "processes map items inline" do
        subject = test_reactor(HelpersMapReactor, { items: [1, 2, 3] }, async: false)

        expect(subject).to be_success
        result = subject.step_result(:process_items)
        # Verify it returns an Array (inline execution)
        expect(result).to be_an(Array)
        expect(result.size).to eq(3)
      end

      it "handles map failures when simulated", skip: "Not implemented yet" do
        # We need a failing map, or use failing_at
        # failing_at inside map is tricky, let's use a specific failing reactor for map
      end
    end

    context "with interrupts" do
      it "detects paused state" do
        subject = test_reactor(HelpersInterruptReactor, {}, async: false)
        # It should pause at :wait
        # check status
        # status comes from @reactor_instance.context.status
        # "paused"

        # TestSubject#result returns InterruptResult if paused
        expect(subject.result).to be_a(RubyReactor::InterruptResult)
        expect(subject.reactor_instance.context.status).to eq("paused")
      end

      it "returns true for paused?" do
        subject = test_reactor(HelpersInterruptReactor, {}, async: false)
        expect(subject.paused?).to be true
      end

      it "returns false for paused? when completed" do
        subject = test_reactor(HelpersTestReactor, { value: 1 }, async: false)
        expect(subject.paused?).to be false
      end

      it "returns the current interrupt step name via current_step" do
        subject = test_reactor(HelpersInterruptReactor, {}, async: false)
        expect(subject.current_step).to eq(:wait)
      end

      it "returns nil for current_step when not paused" do
        subject = test_reactor(HelpersTestReactor, { value: 1 }, async: false)
        expect(subject.current_step).to be_nil
      end

      describe "be_paused matcher" do
        it "matches when reactor is paused" do
          subject = test_reactor(HelpersInterruptReactor, {}, async: false)
          expect(subject).to be_paused
        end

        it "does not match when reactor is completed" do
          subject = test_reactor(HelpersTestReactor, { value: 1 }, async: false)
          expect(subject).not_to be_paused
        end

        it "does not match when reactor is failed" do
          subject = test_reactor(HelpersFailureReactor, {}, async: false)
          expect(subject).not_to be_paused
        end
      end

      describe "be_paused_at matcher" do
        it "matches when paused at the specified step" do
          subject = test_reactor(HelpersInterruptReactor, {}, async: false)
          expect(subject).to be_paused_at(:wait)
        end

        it "does not match when paused at a different step" do
          subject = test_reactor(HelpersInterruptReactor, {}, async: false)
          expect(subject).not_to be_paused_at(:other_step)
        end

        it "does not match when not paused" do
          subject = test_reactor(HelpersTestReactor, { value: 1 }, async: false)
          expect(subject).not_to be_paused_at(:wait)
        end
      end

      describe "resume method" do
        it "resumes execution with the provided payload" do
          subject = test_reactor(HelpersInterruptReactor, {}, async: false)
          expect(subject).to be_paused_at(:wait)

          # Resume with payload
          subject.resume(payload: { data: "test" })

          # After resume, reactor should complete
          expect(subject).to be_success
          expect(subject.step_result(:after_wait)).to eq("Done")
        end

        it "allows introspection of step receiving payload" do
          subject = test_reactor(HelpersInterruptWithValidationReactor, { user_id: 123 }, async: false)
          expect(subject).to be_paused_at(:approval)

          # Resume with valid payload
          subject.resume(payload: { approved: true, approver: "admin" })

          expect(subject).to be_success
          # The interrupt result should be stored as intermediate result
          approval_data = subject.step_result(:approval)
          # The step should receive the payload we provided
          expect(approval_data).to eq({ approved: true, approver: "admin" })
        end

        it "raises error when trying to resume a non-paused reactor" do
          subject = test_reactor(HelpersTestReactor, { value: 1 }, async: false)
          expect { subject.resume(payload: {}) }.to raise_error(
            RubyReactor::Error::ValidationError,
            /Cannot resume: reactor is not paused/
          )
        end
      end

      context "with async execution (default)" do
        it "detects paused state with async processing" do
          subject = test_reactor(HelpersInterruptReactor, {})
          expect(subject).to be_paused
          expect(subject.current_step).to eq(:wait)
        end

        it "resumes and completes with async processing" do
          subject = test_reactor(HelpersInterruptReactor, {})
          expect(subject).to be_paused_at(:wait)

          subject.resume(payload: { data: "async_test" })

          expect(subject).to be_success
          expect(subject.step_result(:after_wait)).to eq("Done")
        end

        it "works with validation reactor in async mode" do
          subject = test_reactor(HelpersInterruptWithValidationReactor, { user_id: 456 })
          expect(subject).to be_paused_at(:approval)

          subject.resume(payload: { approved: false, approver: "reviewer" })

          expect(subject).to be_success
          expect(subject.step_result(:approval)).to eq({ approved: false, approver: "reviewer" })
        end
      end

      context "with multiple concurrent interrupts" do
        before do
          MultipleInterruptsReactor.instance_variable_set(:@trace, [])
        end

        it "detects multiple ready interrupt steps with ready_interrupt_steps" do
          subject = test_reactor(MultipleInterruptsReactor, {})

          expect(subject).to be_paused
          expect(subject.ready_interrupt_steps).to contain_exactly(:manager_one_approval, :manager_two_approval)
        end

        it "matches be_paused_at with a single step from multiple ready steps" do
          subject = test_reactor(MultipleInterruptsReactor, {})

          expect(subject).to be_paused_at(:manager_one_approval)
          expect(subject).to be_paused_at(:manager_two_approval)
        end

        it "matches be_paused_at with multiple steps" do
          subject = test_reactor(MultipleInterruptsReactor, {})

          expect(subject).to be_paused_at(:manager_one_approval, :manager_two_approval)
        end

        it "matches have_ready_interrupts for exact set" do
          subject = test_reactor(MultipleInterruptsReactor, {})

          expect(subject).to have_ready_interrupts(:manager_one_approval, :manager_two_approval)
        end

        it "raises error when resuming without specifying step for multiple interrupts" do
          subject = test_reactor(MultipleInterruptsReactor, {})

          expect { subject.resume(payload: { status: "approved" }) }.to raise_error(
            RubyReactor::Error::ValidationError,
            /multiple interrupt steps are ready/
          )
        end

        it "resumes specific step when explicitly specified" do
          subject = test_reactor(MultipleInterruptsReactor, {})

          # Resume manager_one first
          subject.resume(step: :manager_one_approval, payload: { status: "approved" })

          # Should still be paused, waiting for manager_two
          expect(subject).to be_paused
          expect(subject.ready_interrupt_steps).to eq([:manager_two_approval])
        end

        it "completes phase 1 when both interrupts are resumed" do
          subject = test_reactor(MultipleInterruptsReactor, {})

          subject.resume(step: :manager_one_approval, payload: { status: "approved" })
          subject.resume(step: :manager_two_approval, payload: { status: "approved" })

          # Should move to phase 2 (paused at final approval interrupts)
          expect(subject).to be_paused
          expect(subject).to have_ready_interrupts(:final_approval_1, :final_approval_2)
        end

        it "completes the full workflow with all interrupts" do
          subject = test_reactor(MultipleInterruptsReactor, {})

          # Phase 1
          subject.resume(step: :manager_one_approval, payload: { status: "approved" })
          subject.resume(step: :manager_two_approval, payload: { status: "approved" })

          # Phase 2
          subject.resume(step: :final_approval_1, payload: { status: "final_ok" })
          subject.resume(step: :final_approval_2, payload: { status: "final_ok" })

          expect(subject).to be_success
          expect(subject.result.value).to eq("done")
        end

        it "raises error when resuming a step that is not ready" do
          subject = test_reactor(MultipleInterruptsReactor, {})

          expect { subject.resume(step: :final_approval_1, payload: { status: "final_ok" }) }.to raise_error(
            RubyReactor::Error::ValidationError,
            /step :final_approval_1 is not ready/
          )
        end
      end
    end
  end

  describe "#failing_at" do
    it "forces a failure at the specified step" do
      subject = test_reactor(HelpersTestReactor, { value: 1 })
                .failing_at(:add_one)

      expect(subject).to be_failure
      expect(subject.error).to include("Simulated failure at add_one")
      expect(subject).to have_run_step(:add_one)
    end
  end

  describe "matchers" do
    it "verifies step order using .after" do
      subject = test_reactor(HelpersMultiStepReactor, {})
      expect(subject).to be_success
      expect(subject).to have_run_step(:two).after(:one)
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
      subject = test_reactor(HelpersMultiStepReactor, {})
      expect(subject).to be_success
      expect(subject).to have_run_step(:two).after(:one)
    end

    it "verifies validation errors" do
      subject = test_reactor(HelpersValidationReactor, { email: "bad" })
      expect(subject).to be_failure
      expect(subject).to have_validation_error(:email)
    end
  end
end
