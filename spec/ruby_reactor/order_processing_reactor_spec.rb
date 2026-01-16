# frozen_string_literal: true

require "spec_helper"
require "sidekiq/testing"
RSpec.describe RubyReactor::OrderProcessingReactor do
  shared_examples "order processing reactor step execution" do
    describe "step validate_order" do
      it "fails when order_id is missing" do
        result = described_class.new.run(product_id: "prod_456", quantity: 2, amount: 200.0)

        expect(result).to be_a(RubyReactor::Failure)
        expect(result.error).to match("order_id")
      end
    end

    describe "step check_inventory" do
      it "compensates for check_inventory step" do
        reactor = described_class.new
        result = reactor.run(order_id: "order_123", product_id: "prod_456", quantity: 2, amount: 200.0,
                             fail_at: :check_inventory)
        expect(result).to be_a(RubyReactor::Failure)
      end
    end

    describe "step reserve_inventory" do
      it "compensates for reserve_inventory step" do
        if described_class.respond_to?(:async?)
          allow_any_instance_of(RubyReactor::Dsl::StepConfig).to receive(:async?).and_return(false)
        end
        # rubocop:enable RSpec/AnyInstance

        reactor = described_class.new
        result = reactor.run(order_id: "order_123", product_id: "prod_456", quantity: 2, amount: 200.0,
                             fail_at: :reserve_inventory)
        expect(result).to be_a(RubyReactor::Failure)

        steps = reactor.execution_trace.each_with_index.map do |trace_entry, index|
          "#{index + 1}. #{trace_entry[:type]} step=#{trace_entry[:step]}"
        end
        expected_steps = [
          "1. run step=validate_order",
          "2. run step=check_inventory",
          "3. run step=reserve_inventory",
          "4. run step=reserve_inventory",
          "5. run step=reserve_inventory",
          "6. run step=reserve_inventory",
          "7. run step=reserve_inventory",
          "8. compensate step=reserve_inventory",
          "9. undo step=check_inventory",
          "10. undo step=validate_order"
        ]
        expect(steps).to eq(expected_steps)
      end

      it "retries reserve_inventory step until success_at_retry" do
        reactor = described_class.new

        result = reactor.run(order_id: "order_123", product_id: "prod_456", quantity: 2, amount: 200.0,
                             fail_at: :reserve_inventory, success_at_retry: 2)
        expect(result).to be_a(RubyReactor::Success)
        expect(result.value[:reserve_inventory]).to eq({ product_id: "prod_456", status: "reserved", quantity: 2 })
        expect(reactor.context.retry_context.step_attempts["reserve_inventory"]).to eq(2)
      end
    end

    describe "execution order verification" do
      # These tests are critical for ensuring the reactor maintains correct execution order:
      # 1. Steps execute in dependency order (validate -> check -> reserve -> process)
      # 2. Retries happen before compensation
      # 3. Compensation/undo happens in reverse order of successful execution
      # 4. Timestamps maintain chronological order throughout the entire flow

      it "maintains correct execution order during early failure with compensation" do
        reactor = described_class.new
        result = reactor.run(order_id: "order_123", product_id: "prod_456", quantity: 2, amount: 200.0,
                             fail_at: :check_inventory)

        expect(result).to be_a(RubyReactor::Failure)

        # Verify execution order with compensation
        steps_with_types = reactor.execution_trace.map { |e| "#{e[:type]}:#{e[:step]}" }

        # Should have: validate_order run, then check_inventory retries, then undo
        expect(steps_with_types.first).to eq("run:validate_order")
        expect(steps_with_types.count { |s| s == "run:check_inventory" }).to eq(5) # max_attempts

        # Verify undos happen after all retries exhausted
        undo_steps = reactor.execution_trace.select { |e| e[:type] == :undo }.map { |e| e[:step] }
        expect(undo_steps).to eq([:validate_order])

        # Verify undo comes last
        expect(reactor.execution_trace.last[:type]).to eq(:undo)
      end

      it "executes compensation in reverse order of successful steps" do
        reactor = described_class.new
        result = reactor.run(order_id: "order_123", product_id: "prod_456", quantity: 2, amount: 200.0,
                             fail_at: :process_payment)

        expect(result).to be_a(RubyReactor::Failure)

        # Get successful steps (before failure)
        successful_runs = []
        reactor.execution_trace.each do |entry|
          break if entry[:step] == :process_payment && entry[:type] == :run

          successful_runs << entry[:step] if entry[:type] == :run && !successful_runs.include?(entry[:step])
        end

        # Get undo operations
        undo_steps = reactor.execution_trace.select { |e| e[:type] == :undo }.map { |e| e[:step] }

        # Verify undo order is reverse of successful execution
        expect(undo_steps).to eq(successful_runs.reverse)

        # Verify all successful steps were undone
        expect(undo_steps.length).to eq(successful_runs.length)
      end

      it "ensures timestamps maintain chronological order across retries and compensation" do
        reactor = described_class.new
        result = reactor.run(order_id: "order_123", product_id: "prod_456", quantity: 2, amount: 200.0,
                             fail_at: :reserve_inventory)

        expect(result).to be_a(RubyReactor::Failure)

        # Verify all timestamps are present and chronological
        timestamps = reactor.execution_trace.map { |e| e[:timestamp] }
        expect(timestamps).to all(be_a(Time))
        expect(timestamps).to eq(timestamps.sort), "Timestamps should be in chronological order"

        # Verify time progresses through: runs -> retries -> compensate -> undo
        run_times = reactor.execution_trace.select { |e| e[:type] == :run }.map { |e| e[:timestamp] }
        compensate_times = reactor.execution_trace.select { |e| e[:type] == :compensate }.map { |e| e[:timestamp] }
        undo_times = reactor.execution_trace.select { |e| e[:type] == :undo }.map { |e| e[:timestamp] }

        expect(run_times.max).to be <= compensate_times.min if compensate_times.any?

        expect(run_times.max).to be <= undo_times.min if undo_times.any? && run_times.any?
      end

      # ----------------------------
      # Additional tests for other steps would go here...
      # ----------------------------
      it ":validate_order successfully validates order details" do
        result = described_class.new.run(order_id: "order_123", product_id: "prod_456", quantity: 2, amount: 200.0)

        expect(result).to be_a(RubyReactor::Success)
        expect(result.value[:validate_order]).to eq({ id: "order_123", amount: 100.0, currency: "USD" })
      end

      it ":check_inventory succeeds" do
        reactor = described_class.new
        result = reactor.run(order_id: "order_123", product_id: "prod_456", quantity: 2, amount: 200.0)

        expect(result).to be_a(RubyReactor::Success)
        expect(result.value[:check_inventory]).to eq({ product_id: "prod_456", available: true, requested_quantity: 2 })
      end

      it "retries check_inventory step until success_at_retry" do
        reactor = described_class.new
        result = reactor.run(order_id: "order_123", product_id: "prod_456", quantity: 2, amount: 200.0,
                             fail_at: :check_inventory, success_at_retry: 3)

        expect(result).to be_a(RubyReactor::Success)
        expect(result.value[:check_inventory]).to eq({ product_id: "prod_456", available: true, requested_quantity: 2 })
      end

      it ":reserve_inventory succeeds" do
        reactor = described_class.new
        result = reactor.run(order_id: "order_123", product_id: "prod_456", quantity: 2, amount: 200.0)

        expect(result).to be_a(RubyReactor::Success)
        expect(result.value[:reserve_inventory]).to eq({ product_id: "prod_456", status: "reserved", quantity: 2 })
      end

      it "executes steps in correct order for successful flow" do
        reactor = described_class.new
        result = reactor.run(order_id: "order_123", product_id: "prod_456", quantity: 2, amount: 200.0)

        expect(result).to be_a(RubyReactor::Success)

        # Verify execution trace exists and has correct structure
        expect(reactor.execution_trace).to be_an(Array)
        expect(reactor.execution_trace).not_to be_empty

        # Extract only run operations for successful flow
        run_steps = reactor.execution_trace.select { |e| e[:type] == :run }.map { |e| e[:step] }

        # Verify exact execution order
        expected_order = %i[validate_order check_inventory reserve_inventory process_payment]
        expect(run_steps).to eq(expected_order)

        # Verify timestamps are in ascending order (steps executed sequentially)
        timestamps = reactor.execution_trace.map { |e| e[:timestamp] }
        expect(timestamps).to eq(timestamps.sort)

        # Verify no undo or compensate operations in successful flow
        expect(reactor.execution_trace.select { |e| e[:type] == :undo }).to be_empty
        expect(reactor.execution_trace.select { |e| e[:type] == :compensate }).to be_empty
      end
      # -----------------
    end
  end

  context "when executing synchronously" do
    # rubocop:disable RSpec/AnyInstance
    before do
      allow_any_instance_of(RubyReactor::Dsl::StepConfig).to receive(:async?).and_return(false)
    end
    # rubocop:enable RSpec/AnyInstance

    it_behaves_like "order processing reactor step execution"
  end

  context "when executing asynchronously" do
    around do |example|
      Sidekiq::Testing.inline! { example.run }
    end

    it_behaves_like "order processing reactor step execution"
  end
  # Additional tests for other steps would go here...
end
