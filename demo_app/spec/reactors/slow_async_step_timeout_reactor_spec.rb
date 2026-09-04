require "rails_helper"

RSpec.describe SlowAsyncStepTimeoutReactor, type: :reactor do
  let(:inputs) { { job_id: "job_2", sleep_seconds: 1 } }
  subject(:reactor) { test_reactor(described_class, inputs) }

  around do |example|
    original = RubyReactor.configuration.async_wait_timeout
    RubyReactor.configuration.async_wait_timeout = 0.2
    example.run
  ensure
    RubyReactor.configuration.async_wait_timeout = original
  end

  it "fails the reactor with an async wait timeout once the work outlives the bound" do
    expect(reactor).to be_failure
    expect(reactor.result.error.to_s).to match(/timeout/i)
  end

  it "compensates :acknowledge, which already ran" do
    allow(Rails.logger).to receive(:warn).and_call_original

    expect(reactor).to be_failure
    expect(Rails.logger).to have_received(:warn).with(/undoing acknowledgement/)
  end
end
