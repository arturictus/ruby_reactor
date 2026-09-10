# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Compensation and undo defaults" do
  it "reports skipped for an undefined compensation and still proceeds with rollback" do
    undone = []

    reactor_class = Class.new(RubyReactor::Reactor) do
      step :with_undo do
        run { |_args, _ctx| Success(:done) }
        undo do |_result, _args, _ctx|
          undone << :with_undo
          Success()
        end
      end

      step :no_compensate do
        wait_for :with_undo
        run { |_args, _ctx| Failure(StandardError.new("boom")) }
      end
    end

    reactor = reactor_class.new
    result = reactor.run
    expect(result).to be_failure
    expect(undone).to eq([:with_undo])

    entry = reactor.execution_trace.find { |e| e[:type] == :compensate && e[:step] == :no_compensate }
    expect(entry).not_to be_nil
    expect(entry[:skipped]).to be true
  end

  it "reports skipped for an undefined undo" do
    reactor_class = Class.new(RubyReactor::Reactor) do
      step :no_undo do
        run { |_args, _ctx| Success(:done) }
      end

      step :fails do
        wait_for :no_undo
        run { |_args, _ctx| Failure(StandardError.new("boom")) }
      end
    end

    reactor = reactor_class.new
    reactor.run

    entry = reactor.execution_trace.find { |e| e[:type] == :undo && e[:step] == :no_undo }
    expect(entry).not_to be_nil
    expect(entry[:skipped]).to be true
  end

  # `compensate` is invoked on the step that FAILED (an alternate recovery
  # for that step's own failure), distinct from `undo`, which runs on prior
  # already-completed steps during rollback.
  it "distinguishes a defined, successful compensation from the skipped default" do
    reactor_class = Class.new(RubyReactor::Reactor) do
      step :fails_with_compensate do
        run { |_args, _ctx| Failure(StandardError.new("boom")) }
        compensate do |_reason, _args, _ctx|
          Success(:compensated)
        end
      end
    end

    reactor = reactor_class.new
    reactor.run

    entry = reactor.execution_trace.find { |e| e[:type] == :compensate && e[:step] == :fails_with_compensate }
    expect(entry).not_to be_nil
    expect(entry[:skipped]).to be false
    expect(entry[:result]).to eq(:compensated)
  end

  it "still raises CompensationError when a defined compensation fails, never confused with skipped" do
    reactor_class = Class.new(RubyReactor::Reactor) do
      step :fails_with_bad_compensate do
        run { |_args, _ctx| Failure(StandardError.new("boom")) }
        compensate do |_reason, _args, _ctx|
          Failure(StandardError.new("compensation exploded"))
        end
      end
    end

    context = RubyReactor::Context.new({}, reactor_class)
    manager = RubyReactor::Executor::CompensationManager.new(context)
    step_config = reactor_class.steps[:fails_with_bad_compensate]

    expect do
      manager.handle_step_failure(step_config, StandardError.new("boom"), {})
    end.to raise_error(RubyReactor::Error::CompensationError)
  end
end
