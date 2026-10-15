# frozen_string_literal: true

require "spec_helper"

# 011 R-12, API §8: asserting where a step ran.
RSpec.describe "queue matchers", type: :reactor do
  describe "have_run_step(...).on_queue" do
    it "matches the queue the step's run was written on" do
      subject = test_reactor(QueueFixtures::SoloMain, {})

      expect(subject).to be_success
      expect(subject).to have_run_step(:second).on_queue(:my_specific_queue)
      expect(subject).to have_run_step(:third).after(:second).on_queue("my_specific_queue")
      expect(subject).not_to have_run_step(:second).on_queue(:other)
      expect(subject).not_to have_run_step(:first).on_queue(:my_specific_queue)
    end

    it "says where the step actually ran" do
      subject = test_reactor(QueueFixtures::SoloMain, {})

      expect { expect(subject).to have_run_step(:second).on_queue(:other) }
        .to raise_error(RSpec::Expectations::ExpectationNotMetError,
                        /run step :second on queue :other, but it ran on :my_specific_queue/)
      expect { expect(subject).to have_run_step(:first).on_queue(:other) }
        .to raise_error(RSpec::Expectations::ExpectationNotMetError, /but it ran in the calling process/)
    end

    it "reads an async_step's queue from its record" do
      subject = test_reactor(QueueFixtures::MainSteps, {})

      expect(subject).to be_success
      expect(subject).to have_run_step(:email).on_queue(:emails)
      expect(subject).to have_run_step(:priority_email).on_queue(:priority_emails)
    end
  end

  describe "have_hopped_queues" do
    it "matches the run's forward hops in order, and its rollback hops with during_rollback" do
      subject = test_reactor(QueueFixtures::MainFailing, {})

      expect(subject).to be_failure
      expect(subject).to have_hopped_queues(:stripe, :main)
      expect(subject).to have_hopped_queues(:stripe, :main).during_rollback
      expect(subject).not_to have_hopped_queues(:stripe)
      expect { expect(subject).to have_hopped_queues(:main) }
        .to raise_error(RSpec::Expectations::ExpectationNotMetError,
                        /hops to be \["main"\], got \["stripe", "main"\]/)
    end

    it "matches no hop with no arguments" do
      expect(test_reactor(QueueFixtures::SoloMain, {})).to have_hopped_queues
    end
  end

  describe "have_undone_step" do
    it "matches an undone step, optionally on a queue" do
      subject = test_reactor(QueueFixtures::MainFailing, {})

      expect(subject).to have_undone_step(:second)
      expect(subject).to have_undone_step(:second).on_queue(:main)
      expect(subject).not_to have_undone_step(:third)
      expect(subject).not_to have_undone_step(:second).on_queue(:stripe)
      expect { expect(subject).to have_undone_step(:second).on_queue(:stripe) }
        .to raise_error(RSpec::Expectations::ExpectationNotMetError,
                        /undone step :second on queue :stripe, but it was undone on :main/)
    end
  end
end
