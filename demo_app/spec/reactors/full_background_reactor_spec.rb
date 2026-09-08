require "rails_helper"

RSpec.describe FullBackgroundReactor, type: :reactor do
  subject(:reactor) { test_reactor(described_class, { param: 42 }) }

  it "runs all async steps end-to-end via Sidekiq fake mode" do
    expect(reactor).to be_success
    expect(reactor.result.value).to eq("Step 2 done after Step 1 done")
  end

  it "runs step 2 after step 1" do
    expect(reactor).to have_run_step(:background_task_1)
    expect(reactor).to have_run_step(:background_task_2).after(:background_task_1)
  end

  context "when forced to run synchronously" do
    subject(:reactor) { test_reactor(described_class, { param: 1 }, async: false) }

    it "still completes successfully" do
      expect(reactor).to be_success
    end
  end
end
