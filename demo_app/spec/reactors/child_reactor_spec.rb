require "rails_helper"

RSpec.describe ChildReactor, type: :reactor do
  subject(:reactor) { test_reactor(described_class, inputs) }

  context "happy path" do
    let(:inputs) { { x: 2, y: 3 } }

    it "returns the :add result" do
      expect(reactor).to be_success
      expect(reactor.result.value).to eq(5)
    end

    it "runs every step in dependency order" do
      expect(reactor).to have_run_step(:add)
      expect(reactor).to have_run_step(:do_something).after(:add)
      expect(reactor).to have_run_step(:do_other_thing).after(:add)
      expect(reactor).to have_run_step(:wait_for).after(:do_other_thing)
    end
  end

  context "when add fails" do
    let(:inputs) { { x: 1, y: 1, fail_at_reactor: :child_reactor, fail_at_step: :add } }

    it "fails and does not run downstream steps" do
      expect(reactor).to be_failure
      expect(reactor).not_to have_run_step(:do_something)
    end
  end

  context "when mocking a step" do
    let(:inputs) { { x: 10, y: 20 } }

    it "uses the mocked implementation" do
      reactor.mock_step(:add) { |_, _, _| RubyReactor::Success(999) }

      expect(reactor).to be_success
      expect(reactor.step_result(:add)).to eq(999)
    end
  end
end
