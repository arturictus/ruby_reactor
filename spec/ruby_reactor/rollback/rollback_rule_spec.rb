# frozen_string_literal: true

require "spec_helper"

# US5 (FR-022, FR-023): the coordinator asks each step whether its success is
# tracked for undo; async units answer no themselves.
module RollbackRuleSpec
  class Child < RollbackRecorder::Reactor
    tag "child"
    input :from_a, optional: true
    recording_step :c1
  end

  class Elem < RubyReactor::Reactor
    input :i
    step(:e) { run { RubyReactor.Success() } }
  end

  class AllConstructs < RubyReactor::Reactor
    input :items
    step(:plain) { run { RubyReactor.Success() } }
    compose :composed, Child
    map(:mapped, Elem) do
      source input(:items)
      argument :i, element(:mapped)
    end
    interrupt :paused
    async_step(:unit) { run { RubyReactor.Success() } }
    async_reactor :child_reactor, Child
  end

  class AsyncReactorThenFails < RollbackRecorder::Reactor
    recording_step :a
    async_reactor(:child, Child) { argument :from_a, result(:a) }
    recording_step :b, after: :child, fail: true
  end
end

RSpec.describe "the one rollback rule" do
  let(:steps) { RollbackRuleSpec::AllConstructs.steps }

  it "tracks every same-process construct for undo" do
    expect(%i[plain composed mapped paused].map { |name| steps[name].rollback_tracked? }).to all(be(true))
  end

  it "leaves async units untracked" do
    expect(steps[:unit].rollback_tracked?).to be(false)
    expect(steps[:child_reactor].rollback_tracked?).to be(false)
  end

  it "never undoes an async_reactor child when the parent rolls back (INV-25)" do
    RollbackRuleSpec::AsyncReactorThenFails.run({})
    RubyReactor::RSpec::AsyncTestHelpers.drain_async_jobs

    expect(RollbackRecorder.log).to eq(%w[run:a run:b compensate:b undo:a run:child.c1])
  end
end
