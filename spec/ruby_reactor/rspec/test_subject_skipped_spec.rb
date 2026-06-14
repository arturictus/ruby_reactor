# frozen_string_literal: true

require "spec_helper"
require_relative "../../examples/locking_reactors"

# `test_reactor` must surface a `Skipped` result (so `be_skipped` works on the
# subject) for both kinds of clean halt: a `with_period` gate and a step that
# returns `RubyReactor.Skipped(...)`.
RSpec.describe "TestSubject skipped support", type: :reactor do
  it "surfaces a period-gate skip via the subject" do
    PeriodicReactor.run(org_id: 7) # claim the bucket

    subject = test_reactor(PeriodicReactor, { org_id: 7 })

    expect(subject).to be_skipped
    expect(subject).to be_skipped.because(:period)
  end

  it "surfaces a step-returned skip via the subject" do
    subject = test_reactor(StepSkipReactor, { should_skip: true })

    expect(subject).to be_skipped
    expect(subject).to be_skipped.at_step(:second)
  end

  it "does not report a plain success as skipped" do
    subject = test_reactor(StepSkipReactor, { should_skip: false })

    expect(subject).to be_success
    expect(subject).not_to be_skipped
  end
end
