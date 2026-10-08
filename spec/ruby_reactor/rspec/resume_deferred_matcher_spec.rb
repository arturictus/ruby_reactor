# frozen_string_literal: true

require "spec_helper"

# 010 API §7: `resume(process_jobs: false)` leaves a hand-off pending, and
# `be_resume_deferred` matches a resume handed to a worker.
RSpec.describe "be_resume_deferred", type: :reactor do
  for_each_async_backend do
    it "matches a resume deferred on the reactor's lock, and not once it has run" do
      subject = test_reactor(ResumeFixtures::LockedApproval, {}, process_jobs: false)
      subject.run
      expect(subject).to be_paused_at(:approval)

      hold_lock("resume-fx:locked", owner: "another-run") do
        subject.resume(payload: { ok: true }, process_jobs: false)
      end

      expect(subject).to be_resume_deferred
      drain_async_jobs
      expect(subject).to be_success
      expect(subject).not_to be_resume_deferred
    end

    it "does not match a resume that ran inline" do
      subject = test_reactor(ResumeFixtures::PlainApproval, {}, process_jobs: false)
      subject.run

      subject.resume(payload: { ok: true })

      expect(subject).not_to be_resume_deferred
      expect(subject).to be_success
    end
  end
end
