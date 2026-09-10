# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Signal objects" do
  describe RubyReactor::Halt do
    it "carries reason, period_key, and step_name" do
      halt = described_class.new(reason: "user opted out", period_key: "2026-09", step_name: :check)

      expect(halt.reason).to eq("user opted out")
      expect(halt.period_key).to eq("2026-09")
      expect(halt.step_name).to eq(:check)
    end

    it "answers halted?" do
      expect(described_class.new(reason: "x").halted?).to be true
    end

    it "does not respond to skipped?" do
      expect(described_class.new(reason: "x")).not_to respond_to(:skipped?)
    end

    it "is a Success subclass" do
      halt = described_class.new(reason: "x")
      expect(halt).to be_a(RubyReactor::Success)
      expect(halt.success?).to be true
    end
  end

  describe RubyReactor::Skipped do
    it "wraps a value" do
      expect(described_class.new(:the_value).value).to eq(:the_value)
    end

    it "answers skipped?" do
      expect(described_class.new(:v).skipped?).to be true
    end

    it "answers halted? as false" do
      expect(described_class.new(:v).halted?).to be false
    end

    it "is a Success subclass" do
      skipped = described_class.new(:v)
      expect(skipped).to be_a(RubyReactor::Success)
      expect(skipped.success?).to be true
    end
  end

  describe RubyReactor::Success do
    it "answers halted? and skipped? with false" do
      result = described_class.new(:v)
      expect(result.halted?).to be false
      expect(result.skipped?).to be false
    end
  end

  describe RubyReactor::Failure do
    it "answers halted? and skipped? with false" do
      result = described_class.new(StandardError.new("boom"))
      expect(result.halted?).to be false
      expect(result.skipped?).to be false
    end
  end

  describe "RubyReactor.Skipped migration guard" do
    it "raises ArgumentError naming Halt when called with only reason:" do
      expect { RubyReactor.Skipped(reason: "x") }.to raise_error(
        ArgumentError, /Halt/
      )
    end
  end
end
