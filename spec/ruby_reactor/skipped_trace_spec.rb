# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Skipped step execution trace", type: :reactor do
  class SkippedTraceSyncReactor < RubyReactor::Reactor
    input :should_skip

    step :maybe_sync do
      argument :should_skip, input(:should_skip)
      run { |args, _ctx| args[:should_skip] ? Skipped("cached") : Success("fresh") }
    end

    step :notify do
      argument :value, result(:maybe_sync)
      run { |args, _ctx| Success("notified:#{args[:value]}") }
    end

    returns :notify
  end

  class SkippedTraceReactor < RubyReactor::Reactor
    background all: true
    input :should_skip

    step :maybe_sync do
      argument :should_skip, input(:should_skip)
      run { |args, _ctx| args[:should_skip] ? Skipped("cached") : Success("fresh") }
    end

    step :notify do
      argument :value, result(:maybe_sync)
      run { |args, _ctx| Success("notified:#{args[:value]}") }
    end

    returns :notify
  end

  it "holds a { type: :skipped, step: } entry in the execution trace" do
    reactor = SkippedTraceSyncReactor.new
    reactor.run(should_skip: true)

    entry = reactor.execution_trace.find { |e| e[:type] == :skipped }
    expect(entry).not_to be_nil
    expect(entry[:step]).to eq(:maybe_sync)
  end

  it "survives an async round trip through a real worker (live Redis)" do
    subject = test_reactor(SkippedTraceReactor, { should_skip: true })

    expect(subject).to be_success
    expect(subject.step_result(:notify)).to eq("notified:cached")

    trace = subject.reactor_instance.context.execution_trace
    entry = trace.find { |e| e[:type].to_s == "skipped" }
    expect(entry).not_to be_nil
    expect(entry[:step].to_s).to eq("maybe_sync")
  end
end
