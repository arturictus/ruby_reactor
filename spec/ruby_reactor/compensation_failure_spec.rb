# frozen_string_literal: true

require "spec_helper"

# A failing step's `compensate` that raises is a compensation failure, exactly
# like one that returns a Failure: the rest of the rollback still runs, and the
# reactor's Failure reports it.
RSpec.describe "A compensation that fails" do
  let(:undone) { [] }

  def reactor_with_compensate(&compensate_body)
    log = undone
    Class.new(RubyReactor::Reactor) do
      step :reserve do
        run { |_args, _ctx| Success(:reserved) }
        undo do |_result, _args, _ctx|
          log << :reserve
          Success()
        end
      end

      step :charge do
        wait_for :reserve
        run { |_args, _ctx| Failure("charge declined") }
        compensate(&compensate_body)
      end
    end
  end

  it "still rolls back the completed steps when it raises, and reports it on the Failure" do
    result = reactor_with_compensate { |*| raise "compensate blew up" }.new.run

    expect(result).to be_failure
    expect(undone).to eq([:reserve])
    expect(result.error.to_s).to include("Compensation for step 'charge' failed: compensate blew up")
    expect(result.rollback_failures).to contain_exactly(
      hash_including(step: :charge, kind: :compensate, reason: :raised, message: "compensate blew up")
    )
  end

  it "behaves the same when it returns a Failure instead (control)" do
    result = reactor_with_compensate { |*| RubyReactor.Failure("comp-fail") }.new.run

    expect(result).to be_failure
    expect(undone).to eq([:reserve])
    expect(result.error.to_s).to include("Compensation for step 'charge' failed: comp-fail")
    expect(result.rollback_failures).to contain_exactly(
      hash_including(step: :charge, kind: :compensate, reason: :returned_failure, message: "comp-fail")
    )
  end
end
