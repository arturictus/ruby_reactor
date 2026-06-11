# frozen_string_literal: true

require "spec_helper"

RSpec.describe RubyReactor::Utils::BacktraceLocation do
  describe ".parse" do
    it "parses Ruby 3.x single-quoted backtrace lines" do
      line = "/workspace/demo_app/app/reactors/ar_map_reactor.rb:48:in 'block (3 levels) in <class:ArMapReactor>'"

      expect(described_class.parse(line)).to eq(["/workspace/demo_app/app/reactors/ar_map_reactor.rb", 48])
    end

    it "parses legacy backtick backtrace lines" do
      line = "/path/to/file.rb:11:in `foo'"

      expect(described_class.parse(line)).to eq(["/path/to/file.rb", 11])
    end
  end

  describe ".extract" do
    it "returns the first non-internal frame by default" do
      backtrace = [
        "#{RubyReactor.root}/lib/ruby_reactor/executor/step_executor.rb:120:in `run'",
        "/workspace/demo_app/app/reactors/ar_map_reactor.rb:48:in 'block (3 levels) in <class:ArMapReactor>'"
      ]

      expect(described_class.extract(backtrace)).to eq(
        ["/workspace/demo_app/app/reactors/ar_map_reactor.rb", 48]
      )
    end

    it "falls back to the first frame when all frames are internal" do
      backtrace = [
        "#{RubyReactor.root}/lib/ruby_reactor/executor/step_executor.rb:120:in `run'"
      ]

      expect(described_class.extract(backtrace)).to eq(
        ["#{RubyReactor.root}/lib/ruby_reactor/executor/step_executor.rb", 120]
      )
    end

    it "finds demo app frames inside the mounted workspace root" do
      backtrace = [
        "#{RubyReactor.root}/lib/ruby_reactor.rb:314:in 'Class#new'",
        "... [ruby-reactor-internals-redacted-trace]",
        "#{RubyReactor.root}/demo_app/app/reactors/payment_workflow.rb:83:in " \
        "'block (2 levels) in <class:PaymentWorkflow>'"
      ]

      expect(described_class.extract(backtrace)).to eq(
        ["#{RubyReactor.root}/demo_app/app/reactors/payment_workflow.rb", 83]
      )
    end

    it "treats only gem lib paths as internal" do
      expect(described_class.internal_path?("#{RubyReactor.root}/lib/ruby_reactor/executor.rb")).to be true
      expect(described_class.internal_path?("#{RubyReactor.root}/lib/ruby_reactor.rb")).to be true
      path = "#{RubyReactor.root}/demo_app/app/reactors/payment_workflow.rb"
      expect(described_class.internal_path?(path)).to be false
    end
  end
end
