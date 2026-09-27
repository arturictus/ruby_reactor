# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Skipped step rollback interaction" do
  # 008 R-17: `Skipped` is only an instrumentation mark — in every effect the
  # same as a Success, so a later failure undoes it too.
  it "undoes a skipped step exactly like a success on a later failure" do
    undone = []

    reactor_class = Class.new(RubyReactor::Reactor) do
      step :one do
        run { |_args, _ctx| Success(:one_done) }

        undo do |_result, _args, _ctx|
          undone << :one
          Success()
        end
      end

      step :two do
        wait_for :one
        run { |_args, _ctx| Skipped(:two_skipped) }

        undo do |_result, _args, _ctx|
          undone << :two
          Success()
        end
      end

      step :three do
        wait_for :two
        run { |_args, _ctx| Failure(StandardError.new("boom")) }
      end
    end

    result = reactor_class.run
    expect(result).to be_failure
    expect(undone).to eq(%i[two one])
  end
end
