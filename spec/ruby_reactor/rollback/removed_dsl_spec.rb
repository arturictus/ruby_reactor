# frozen_string_literal: true

require "spec_helper"

# US6 (008 R-15, R-17): `where`/`guard` are gone. A step that should not run
# returns `Skipped` from its body, which has every effect a Success has —
# including its `undo` running on rollback. Only the trace marks it.
module RemovedDslSpec
  class SkipsItself < RollbackRecorder::Reactor
    recording_step :a
    step :s do
      wait_for :a
      run { |_args, _ctx| RubyReactor.Skipped(:v) }
      undo do |_value, _args, _ctx|
        RollbackRecorder.record("undo:s")
        RubyReactor.Success()
      end
    end
    step :reader do
      argument :value, result(:s)
      run do |args, _ctx|
        RollbackRecorder.record("read:#{args.value}")
        RubyReactor.Failure("reader fails")
      end
    end
  end
end

RSpec.describe "removed `where`/`guard` DSL" do
  { step: :step, async_step: :async_step, interrupt: :interrupt }.each do |label, kind|
    %i[where guard].each do |keyword|
      it "rejects `#{keyword}` on #{label} at definition time" do
        expect do
          Class.new(RubyReactor::Reactor) do
            public_send(kind, :s) do
              public_send(keyword) { |_ctx| true }
            end
          end
        end.to raise_error(RubyReactor::Error::DeprecatedDslError, /:s\b.*Skipped/m)
      end
    end
  end

  it "treats a step that returns Skipped exactly like a Success, undo included" do
    reactor = RemovedDslSpec::SkipsItself.new
    result = reactor.run({})

    expect(result).to be_failure
    expect(RollbackRecorder.log).to eq(%w[run:a read:v undo:s undo:a])
    expect(reactor.context.execution_trace.map { |e| e[:type].to_s }).to include("skipped")
  end
end
