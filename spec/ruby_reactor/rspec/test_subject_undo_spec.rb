# frozen_string_literal: true

require "spec_helper"

# 011: `TestSubject#undo` undoes the run, drains what it handed off, and leaves
# the subject on the reloaded run.
RSpec.describe "TestSubject#undo", type: :reactor do
  it "follows a handed-off undo to its end, or stops before the jobs with process_jobs: false" do
    subject = test_reactor(QueueFixtures::SoloMain, {}, process_jobs: false).tap(&:run)
    drain_async_jobs
    expect(subject).to be_success

    subject.undo(process_jobs: false)
    expect(subject).to be_rolling_back
    expect(pending_async_jobs.map(&:queue)).to eq(["my_specific_queue"])

    drain_async_jobs
    expect(subject).to have_undone_step(:third).on_queue(:my_specific_queue)
    expect(subject.reactor_instance.context.status.to_s).to eq("cancelled")
  end

  it "undoes a run without queues in the caller" do
    subject = test_reactor(QueueFixtures::SoloUndeclared, {})
    expect(subject).to be_success

    subject.undo
    expect(subject.reactor_instance.context.status.to_s).to eq("cancelled")
    expect(subject).to have_undone_step(:first)
  end
end
