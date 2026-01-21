# frozen_string_literal: true

require "spec_helper"
require "sidekiq/testing"
RSpec.describe RubyReactor::OrderProcessingReactor do
  shared_examples "order processing reactor step execution" do
    def execute_op_reactor(inputs = {})
      test_reactor(described_class, inputs, async: is_async)
    end

    describe "step validate_order" do
      it "fails when order_id is missing" do
        execution = execute_op_reactor(product_id: "prod_456", quantity: 2, amount: 200.0)

        expect(execution).to be_failure
        expect(execution.result.error).to match("order_id")
      end
    end

    describe "step check_inventory" do
      it "compensates for check_inventory step" do
        execution = execute_op_reactor(order_id: "order_123", product_id: "prod_456", quantity: 2, amount: 200.0,
                                       fail_at: :check_inventory)
        expect(execution).to be_failure
      end
    end

    describe "step reserve_inventory" do
      it "compensates for reserve_inventory step" do
        execution = execute_op_reactor(order_id: "order_123", product_id: "prod_456", quantity: 2, amount: 200.0,
                                       fail_at: :reserve_inventory)
        expect(execution).to be_failure

        steps = execution.reactor_instance.execution_trace.each_with_index.map do |trace_entry, index|
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
        execution = execute_op_reactor(order_id: "order_123", product_id: "prod_456", quantity: 2, amount: 200.0,
                                       fail_at: :reserve_inventory, success_at_retry: 2)
        expect(execution).to be_success
        expect(execution.step_result(:reserve_inventory)).to eq({ product_id: "prod_456", status: "reserved",
                                                                  quantity: 2 })
        expect(execution.reactor_instance.context.retry_context.attempts_for_step("reserve_inventory")).to eq(2)
      end
    end

    describe "execution order verification" do
      # These tests are critical for ensuring the reactor maintains correct execution order:
      # 1. Steps execute in dependency order (validate -> check -> reserve -> process)
      # 2. Retries happen before compensation
      # 3. Compensation/undo happens in reverse order of successful execution
      # 4. Timestamps maintain chronological order throughout the entire flow

      it "maintains correct execution order during early failure with compensation" do
        execution = execute_op_reactor(order_id: "order_123", product_id: "prod_456", quantity: 2, amount: 200.0,
                                       fail_at: :check_inventory)

        expect(execution).to be_failure

        # Verify execution order with compensation
        trace = execution.reactor_instance.execution_trace
        steps_with_types = trace.map { |e| "#{e[:type]}:#{e[:step]}" }

        # Should have: validate_order run, then check_inventory retries, then undo
        expect(steps_with_types.first).to eq("run:validate_order")
        expect(steps_with_types.count { |s| s == "run:check_inventory" }).to eq(5) # max_attempts

        # Verify undos happen after all retries exhausted
        undo_steps = trace.select { |e| e[:type] == :undo }.map { |e| e[:step] }
        expect(undo_steps).to eq([:validate_order])

        # Verify undo comes last
        expect(trace.last[:type]).to eq(:undo)
      end

      it "executes compensation in reverse order of successful steps" do
        execution = execute_op_reactor(order_id: "order_123", product_id: "prod_456", quantity: 2, amount: 200.0,
                                       fail_at: :process_payment)

        expect(execution).to be_failure

        # Get successful steps (before failure)
        trace = execution.reactor_instance.execution_trace
        successful_runs = []
        trace.each do |entry|
          break if entry[:step] == :process_payment && entry[:type] == :run

          successful_runs << entry[:step] if entry[:type] == :run && !successful_runs.include?(entry[:step])
        end

        # Get undo operations
        undo_steps = trace.select { |e| e[:type] == :undo }.map { |e| e[:step] }

        # Verify undo order is reverse of successful execution
        expect(undo_steps).to eq(successful_runs.reverse)

        # Verify all successful steps were undone
        expect(undo_steps.length).to eq(successful_runs.length)
      end

      it "ensures timestamps maintain chronological order across retries and compensation" do
        execution = execute_op_reactor(order_id: "order_123", product_id: "prod_456", quantity: 2, amount: 200.0,
                                       fail_at: :reserve_inventory)

        expect(execution).to be_failure

        # Verify all timestamps are present and chronological
        trace = execution.reactor_instance.execution_trace
        timestamps = trace.map { |e| e[:timestamp] }
        expect(timestamps).to all(be_a(Time))
        expect(timestamps).to eq(timestamps.sort), "Timestamps should be in chronological order"

        # Verify time progresses through: runs -> retries -> compensate -> undo
        run_times = trace.select { |e| e[:type] == :run }.map { |e| e[:timestamp] }
        compensate_times = trace.select { |e| e[:type] == :compensate }.map { |e| e[:timestamp] }
        undo_times = trace.select { |e| e[:type] == :undo }.map { |e| e[:timestamp] }

        expect(run_times.max).to be <= compensate_times.min if compensate_times.any?

        expect(run_times.max).to be <= undo_times.min if undo_times.any? && run_times.any?
      end

      # ----------------------------
      # Additional tests for other steps would go here...
      # ----------------------------
      it ":validate_order successfully validates order details" do
        execution = execute_op_reactor(order_id: "order_123", product_id: "prod_456", quantity: 2, amount: 200.0)

        expect(execution).to be_success
        expect(execution.step_result(:validate_order)).to eq({ id: "order_123", amount: 100.0, currency: "USD" })
      end

      it ":check_inventory succeeds" do
        execution = execute_op_reactor(order_id: "order_123", product_id: "prod_456", quantity: 2, amount: 200.0)

        expect(execution).to be_success
        expect(execution.step_result(:check_inventory)).to eq({ product_id: "prod_456", available: true,
                                                                requested_quantity: 2 })
      end

      it "retries check_inventory step until success_at_retry" do
        execution = execute_op_reactor(order_id: "order_123", product_id: "prod_456", quantity: 2, amount: 200.0,
                                       fail_at: :check_inventory, success_at_retry: 3)

        expect(execution).to be_success
        expect(execution.step_result(:check_inventory)).to eq({ product_id: "prod_456", available: true,
                                                                requested_quantity: 2 })
      end

      it ":reserve_inventory succeeds" do
        execution = execute_op_reactor(order_id: "order_123", product_id: "prod_456", quantity: 2, amount: 200.0)

        expect(execution).to be_success
        expect(execution.step_result(:reserve_inventory)).to eq({ product_id: "prod_456", status: "reserved",
                                                                  quantity: 2 })
      end

      it "executes steps in correct order for successful flow" do
        execution = execute_op_reactor(order_id: "order_123", product_id: "prod_456", quantity: 2, amount: 200.0)

        expect(execution).to be_success

        # Verify execution trace exists and has correct structure
        trace = execution.reactor_instance.execution_trace
        expect(trace).to be_an(Array)
        expect(trace).not_to be_empty

        # Extract only run operations for successful flow
        run_steps = trace.select { |e| e[:type] == :run }.map { |e| e[:step] }

        # Verify exact execution order
        expected_order = %i[validate_order check_inventory reserve_inventory process_payment]
        expect(run_steps).to eq(expected_order)

        # Verify timestamps are in ascending order (steps executed sequentially)
        timestamps = trace.map { |e| e[:timestamp] }
        expect(timestamps).to eq(timestamps.sort)

        # Verify no undo or compensate operations in successful flow
        expect(trace.select { |e| e[:type] == :undo }).to be_empty
        expect(trace.select { |e| e[:type] == :compensate }).to be_empty
      end
      # -----------------
    end
  end

  context "when executing synchronously" do
    let(:is_async) { false }

    it_behaves_like "order processing reactor step execution"
  end

  context "when executing asynchronously" do
    let(:is_async) { true }

    around do |example|
      Sidekiq::Testing.inline! { example.run }
    end

    it_behaves_like "order processing reactor step execution"
  end
  # Additional tests for other steps would go here...
end
