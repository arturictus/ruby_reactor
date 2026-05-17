# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Execution Trace Verification", type: :integration do
  let(:captured_output) { StringIO.new }

  # rubocop:disable RSpec/ExpectOutput
  around do |example|
    original_stdout = $stdout
    $stdout = captured_output
    example.run
    $stdout = original_stdout
  end
  # rubocop:enable RSpec/ExpectOutput

  def parse_execution_logs(output)
    executions = []
    output.each_line do |line|
      next unless line.match(/\[EXECUTION\] (RUN|UNDO|COMPENSATE) (\w+)/)

      type = Regexp.last_match(1).downcase.to_sym
      step = Regexp.last_match(2)
      executions << { type: type, step: step }
    end
    executions
  end

  context "when executing asynchronously" do
    around do |example|
      Sidekiq::Testing.inline! { example.run }
    end

    it "verifies that execution trace matches actual execution for successful flow" do
      reactor = RubyReactor::OrderProcessingReactor.new
      result = reactor.run(order_id: "order_123", product_id: "prod_456", quantity: 2, amount: 200.0)

      expect(result).to be_a(RubyReactor::Success)

      # Parse actual execution logs
      actual_execution = parse_execution_logs(captured_output.string)

      # Parse execution trace
      trace_execution = reactor.execution_trace.map do |entry|
        {
          type: entry[:type],
          step: entry[:step],
          timestamp: entry[:timestamp]
        }
      end

      # Print comparison for debugging
      puts "\n=== ACTUAL EXECUTION ==="
      actual_execution.each_with_index do |exec, idx|
        puts "#{idx + 1}. #{exec[:type].upcase} #{exec[:step]}"
      end

      puts "\n=== EXECUTION TRACE ==="
      trace_execution.each_with_index do |trace, idx|
        puts "#{idx + 1}. #{trace[:type].upcase} #{trace[:step]}"
      end

      # Verify counts match
      expect(actual_execution.length).to eq(trace_execution.length),
                                         "Expected #{trace_execution.length} executions, got #{actual_execution.length}"

      # Verify each execution matches
      actual_execution.each_with_index do |actual, idx|
        trace = trace_execution[idx]
        expect(actual[:type]).to eq(trace[:type]),
                                 "Step #{idx + 1}: Expected type #{trace[:type]} but got #{actual[:type]}"
        expect(actual[:step]).to eq(trace[:step].to_s),
                                 "Step #{idx + 1}: Expected step #{trace[:step]} but got #{actual[:step]}"
      end

      # Verify order of execution
      expected_order = %w[validate_order check_inventory reserve_inventory process_payment]
      actual_order = actual_execution.select { |e| e[:type] == :run }.map { |e| e[:step] }
      expect(actual_order).to eq(expected_order)
    end

    it "verifies execution trace matches actual execution with retries" do
      reactor = RubyReactor::OrderProcessingReactor.new
      result = reactor.run(
        order_id: "order_123",
        product_id: "prod_456",
        quantity: 2,
        amount: 200.0,
        fail_at: :check_inventory,
        success_at_retry: 3
      )

      expect(result).to be_a(RubyReactor::Success)

      # Parse actual execution logs
      actual_execution = parse_execution_logs(captured_output.string)

      # Parse execution trace
      trace_execution = reactor.execution_trace.map do |entry|
        {
          type: entry[:type],
          step: entry[:step],
          timestamp: entry[:timestamp]
        }
      end

      # Verify counts match
      expect(actual_execution.length).to eq(trace_execution.length),
                                         "Expected #{trace_execution.length} executions, got #{actual_execution.length}"

      # Verify each execution matches
      actual_execution.each_with_index do |actual, idx|
        trace = trace_execution[idx]
        expect(actual[:type]).to eq(trace[:type]),
                                 "Step #{idx + 1}: Expected type #{trace[:type]} but got #{actual[:type]}"
        expect(actual[:step]).to eq(trace[:step].to_s),
                                 "Step #{idx + 1}: Expected step #{trace[:step]} but got #{actual[:step]}"
      end

      # Verify retry attempts
      check_inventory_runs = actual_execution.select { |e| e[:type] == :run && e[:step] == "check_inventory" }
      expect(check_inventory_runs.length).to eq(3), "Expected 3 attempts at check_inventory"
    end

    it "verifies execution trace matches actual execution with compensation" do
      reactor = RubyReactor::OrderProcessingReactor.new
      result = reactor.run(
        order_id: "order_123",
        product_id: "prod_456",
        quantity: 2,
        amount: 200.0,
        fail_at: :reserve_inventory,
        success_at_retry: 999 # Never succeed, exhaust all retries
      )

      # Debug output - write to real stdout
      File.write("/tmp/test_debug.log", "RESULT TYPE: #{result.class}\n")
      File.open("/tmp/test_debug.log", "a") do |f|
        f.puts "CAPTURED OUTPUT:"
        f.puts captured_output.string
        f.puts "EXECUTION TRACE COUNT: #{reactor.execution_trace.length}"
      end

      expect(result).to be_a(RubyReactor::Failure)

      # Parse actual execution logs
      actual_execution = parse_execution_logs(captured_output.string)

      # Parse execution trace
      trace_execution = reactor.execution_trace.map do |entry|
        {
          type: entry[:type],
          step: entry[:step],
          timestamp: entry[:timestamp]
        }
      end

      puts "\n=== ACTUAL COUNT: #{actual_execution.length} ==="
      puts "\n=== TRACE COUNT: #{trace_execution.length} ===\n"

      # Verify counts match
      expect(actual_execution.length).to eq(trace_execution.length),
                                         "Expected #{trace_execution.length} executions, got #{actual_execution.length}"

      # Verify each execution matches
      actual_execution.each_with_index do |actual, idx|
        trace = trace_execution[idx]
        expect(actual[:type]).to eq(trace[:type]),
                                 "Step #{idx + 1}: Expected type #{trace[:type]} but got #{actual[:type]}"
        expect(actual[:step]).to eq(trace[:step].to_s),
                                 "Step #{idx + 1}: Expected step #{trace[:step]} but got #{actual[:step]}"
      end

      # Verify compensation occurred
      compensate_steps = actual_execution.select { |e| e[:type] == :compensate }
      undo_steps = actual_execution.select { |e| e[:type] == :undo }

      expect(compensate_steps.length).to eq(1), "Expected 1 compensate step"
      expect(compensate_steps.first[:step]).to eq("reserve_inventory")

      expect(undo_steps.length).to eq(2), "Expected 2 undo steps"
      expect(undo_steps.map { |u| u[:step] }).to eq(%w[check_inventory validate_order])
    end
  end
end
