# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Undo Functionality" do
  let(:reactor_class) do
    klass = Class.new(RubyReactor::Reactor) do
      step :step1 do
        run { Success("result1") }
        undo { |result, _args, _context| Success("undid #{result}") }
      end

      step :step2 do
        run { Success("result2") }
        undo { |result, _args, _context| Success("undid #{result}") }
      end

      step :fail_step do
        run { Failure("force fail") }
      end
    end
    stub_const("UndoTestReactor", klass)
    klass
  end

  it "logs undo results in execution_trace and maintains chronological order" do
    reactor = reactor_class.new
    result = reactor.run
    expect(result).to be_a(RubyReactor::Failure)

    trace = reactor.context.execution_trace
    undo_entries = trace.select { |e| e[:type] == :undo }

    # Order should be chronological: step2 then step1
    expect(undo_entries.map { |e| e[:step] }).to eq(%i[step2 step1])

    # Each undo entry should contain the result of the undo operation
    # (Currently it contains the original result.value, we want to fix this)
    expect(undo_entries[0][:result]).to eq("undid result2")
    expect(undo_entries[1][:result]).to eq("undid result1")
  end
end
