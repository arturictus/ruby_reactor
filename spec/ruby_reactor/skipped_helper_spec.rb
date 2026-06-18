# frozen_string_literal: true

require "spec_helper"

# Verifies `Skipped` is exposed as a bare helper in the same way as
# `Success`/`Failure` — both inside class steps (RubyReactor::Step) and inside
# inline `run` blocks (RubyReactor::Dsl::TemplateHelpers).
RSpec.describe "Skipped helper parity" do
  describe "inside a class step" do
    let(:step_class) do
      Class.new do
        include RubyReactor::Step

        def self.run(arguments, _context)
          arguments[:skip] ? Skipped(reason: "class_step") : Success(:done)
        end
      end
    end

    it "exposes bare Skipped alongside Success/Failure" do
      result = step_class.run({ skip: true }, nil)
      expect(result).to be_a(RubyReactor::Skipped)
      expect(result.skipped?).to be true
      expect(result.reason).to eq("class_step")
    end
  end

  describe "inside an inline run block" do
    let(:reactor_class) do
      Class.new(RubyReactor::Reactor) do
        input :skip

        step :only do
          argument :skip, input(:skip)
          run { |args, _ctx| args[:skip] ? Skipped(reason: "inline_block") : Success(:done) }
        end

        returns :only
      end
    end

    it "exposes bare Skipped alongside Success/Failure" do
      result = reactor_class.run(skip: true)
      expect(result).to be_a(RubyReactor::Skipped)
      expect(result.skipped?).to be true
      expect(result.reason).to eq("inline_block")
    end

    it "returns Success when not skipping" do
      result = reactor_class.run(skip: false)
      expect(result).to be_success
      expect(result.skipped?).to be false
    end
  end
end
