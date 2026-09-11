# frozen_string_literal: true

require "spec_helper"

# Verifies `Halt` is exposed as a bare helper in the same way as
# `Success`/`Failure` — both inside class steps (RubyReactor::Step) and inside
# inline `run` blocks (RubyReactor::Dsl::TemplateHelpers) — and that halting
# stops the run with no compensation of already-completed steps.
RSpec.describe "Halt helper parity" do
  describe "inside a class step" do
    let(:step_class) do
      Class.new(RubyReactor::Step) do
        def run
          inputs[:skip] ? Halt(reason: "class_step") : Success(:done)
        end
      end
    end

    it "exposes bare Halt alongside Success/Failure" do
      result = step_class.run({ skip: true }, nil)
      expect(result).to be_a(RubyReactor::Halt)
      expect(result.halted?).to be true
      expect(result.reason).to eq("class_step")
    end
  end

  describe "inside an inline run block" do
    let(:reactor_class) do
      Class.new(RubyReactor::Reactor) do
        input :skip

        step :first do
          run { |_args, _ctx| Success(:first_done) }
        end

        step :only do
          argument :skip, input(:skip)
          run { |args, _ctx| args[:skip] ? Halt(reason: "inline_block") : Success(:done) }
        end

        returns :only
      end
    end

    it "exposes bare Halt alongside Success/Failure" do
      result = reactor_class.run(skip: true)
      expect(result).to be_a(RubyReactor::Halt)
      expect(result.halted?).to be true
      expect(result.reason).to eq("inline_block")
    end

    it "returns Success when not halting" do
      result = reactor_class.run(skip: false)
      expect(result).to be_success
      expect(result.halted?).to be false
    end

    it "stops the run and leaves completed steps uncompensated" do
      reactor = reactor_class.new
      result = reactor.run(skip: true)
      expect(result).to be_halted
      expect(reactor.undo_trace).to be_empty
    end
  end
end
