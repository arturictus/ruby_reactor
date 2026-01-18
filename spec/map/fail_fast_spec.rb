# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Map Fail Fast Behavior" do
  # Helper to track execution events
  module EventTracker
    def self.included(base)
      base.extend(ClassMethods)
    end

    module ClassMethods
      def events
        @events ||= []
      end

      def clear_events
        @events = []
      end

      def log(msg)
        events << msg
      end
    end

    def log(msg)
      self.class.log(msg)
    end
  end

  # Base reactor setup
  def create_reactor_class(class_name, fail_fast_val, async_val, batch_size_val = nil)
    Class.new(RubyReactor::Reactor) do
      include EventTracker

      input :items

      map :process_items do
        source input(:items)
        argument :item, element(:process_items)

        # Configure map
        if async_val
          if batch_size_val
            async true, batch_size: batch_size_val
          else
            async true
          end
        end

        # Use a local variable to capture logic if needed, but here we use values directly
        fail_fast fail_fast_val

        step :execute do
          argument :item, input(:item)
          run do |args|
            # Resolve class by name to log reliably
            clazz = Object.const_get(class_name)
            clazz.log "RUN #{args[:item]}"

            if args[:item] == "fail"
              RubyReactor.Failure("Simulated Failure")
            else
              RubyReactor.Success(args[:item])
            end
          end
        end
      end
    end
  end

  # Helper to run async jobs if necessary
  def run_reactor(reactor_class, inputs)
    reactor_class.clear_events
    perform_enqueued_jobs do
      reactor_class.call(inputs)
    end
  end

  def perform_enqueued_jobs(**_args, &block)
    if defined?(Sidekiq::Testing)
      Sidekiq::Testing.inline!(&block)
    else
      yield
    end
  end

  let(:items_with_failure) { %w[ok1 fail ok2 ok3] }

  describe "when fail_fast is true" do
    let(:fail_fast) { true }

    describe "inline map" do
      before do
        stub_const("FailFastInlineTrueReactor", create_reactor_class("FailFastInlineTrueReactor", fail_fast, false))
      end

      let(:reactor_class) { FailFastInlineTrueReactor }

      it "stops processing immediately upon failure" do
        result = run_reactor(reactor_class, items: items_with_failure)

        expect(reactor_class.events).to include("RUN ok1")
        expect(reactor_class.events).to include("RUN fail")
        expect(reactor_class.events).not_to include("RUN ok2")
        expect(reactor_class.events).not_to include("RUN ok3")
        expect(result).to be_a(RubyReactor::Failure)
      end
    end

    describe "async map (default batch/all)" do
      before do
        stub_const("FailFastAsyncTrueReactor", create_reactor_class("FailFastAsyncTrueReactor", fail_fast, true))
      end

      let(:reactor_class) { FailFastAsyncTrueReactor }

      it "stops processing further elements upon failure" do
        # NOTE: In async unlimited mode (or high default batch), multiple items might be queued before one fails.
        # But `fail_fast` logic in Dispatcher checks before dispatching, and ElementExecutor checks before running.
        # If strict ordering is used (default), and sequential processing is implied or enforced?
        # Async map usually fans out.
        # If they run in parallel, "stopping immediately" is race-condition dependent unless strict ordering is enforced.
        # But our implementation checks `fail_fast` status in `ElementExecutor`.
        # So even if queued, they should abort execution if a failure flag is set.
        # However, due to parallel execution, "fail" execution might race with "ok2".
        # BUT for the purpose of this test running inline/mocked, it's sequential.

        run_reactor(reactor_class, items: items_with_failure)

        expect(reactor_class.events).to include("RUN ok1")
        expect(reactor_class.events).to include("RUN fail")
        # ok2 and ok3 should check fail status and skip
        expect(reactor_class.events).not_to include("RUN ok2")
        expect(reactor_class.events).not_to include("RUN ok3")
      end
    end

    describe "async batched map (batch_size: 1)" do
      before do
        stub_const("FailFastBatchTrueReactor", create_reactor_class("FailFastBatchTrueReactor", fail_fast, true, 1))
      end

      let(:reactor_class) { FailFastBatchTrueReactor }

      it "stops processing subsequent batches upon failure" do
        # Batch 1: ok1 -> success
        # Batch 2: fail -> failure
        # Batch 3: ok2 -> should not run (skipped by Dispatcher)

        run_reactor(reactor_class, items: items_with_failure)

        expect(reactor_class.events).to include("RUN ok1")
        expect(reactor_class.events).to include("RUN fail")
        expect(reactor_class.events).not_to include("RUN ok2")
        expect(reactor_class.events).not_to include("RUN ok3")
      end
    end
  end

  describe "when fail_fast is false" do
    let(:fail_fast) { false }

    describe "inline map" do
      before do
        stub_const("FailFastInlineFalseReactor", create_reactor_class("FailFastInlineFalseReactor", fail_fast, false))
      end

      let(:reactor_class) { FailFastInlineFalseReactor }

      it "continues processing all items despite failure" do
        result = run_reactor(reactor_class, items: items_with_failure)

        expect(reactor_class.events).to include("RUN ok1")
        expect(reactor_class.events).to include("RUN fail")
        expect(reactor_class.events).to include("RUN ok2")
        expect(reactor_class.events).to include("RUN ok3")
        # Result of map might be success with failures collected?
        # Default behavior: if fail_fast=false, return success with list of results?
        # MapStep: `results << (fail_fast ? result.value : result)`
        # If fail_fast=false, we get list of Result objects.
        expect(result).to be_a(RubyReactor::Success)
        expect(result.value[:process_items].count).to eq(4)
        expect(result.value[:process_items][1]).to be_a(RubyReactor::Failure)
      end
    end

    describe "async map" do
      before do
        stub_const("FailFastAsyncFalseReactor", create_reactor_class("FailFastAsyncFalseReactor", fail_fast, true))
      end

      let(:reactor_class) { FailFastAsyncFalseReactor }

      it "processes all items despite failure" do
        run_reactor(reactor_class, items: items_with_failure)

        expect(reactor_class.events).to include("RUN ok1")
        expect(reactor_class.events).to include("RUN fail")
        expect(reactor_class.events).to include("RUN ok2")
        expect(reactor_class.events).to include("RUN ok3")
      end
    end

    describe "async batched map (batch_size: 1)" do
      before do
        stub_const("FailFastBatchFalseReactor", create_reactor_class("FailFastBatchFalseReactor", fail_fast, true, 1))
      end

      let(:reactor_class) { FailFastBatchFalseReactor }

      it "processes all batches despite failure" do
        run_reactor(reactor_class, items: items_with_failure)

        expect(reactor_class.events).to include("RUN ok1")
        expect(reactor_class.events).to include("RUN fail")
        expect(reactor_class.events).to include("RUN ok2")
        expect(reactor_class.events).to include("RUN ok3")
      end
    end
  end
end
