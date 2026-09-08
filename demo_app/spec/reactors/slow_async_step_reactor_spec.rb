require "rails_helper"

RSpec.describe SlowAsyncStepReactor, type: :reactor do
  let(:inputs) { { job_id: "job_1", sleep_seconds: 0.1 } }
  subject(:reactor) { test_reactor(described_class, inputs) }

  it "returns immediately — nothing ever reads the slow task's result" do
    expect(reactor).to be_success
    expect(reactor).to have_run_step(:acknowledge)
  end

  it "records the dispatch, whether or not the slow task has finished yet" do
    expect(reactor.async_step(:slow_task)).not_to be_nil
  end
end
