# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Retry Re-execution Regression" do
  # Use a named class for Sidekiq compatibility
  let(:reactor_class) { Support::RetryRegressionReactor }

  before do
    reactor_class.reset_counts
  end

  it "does not re-execute completed steps during retries" do
    Sidekiq::Testing.inline! do
      reactor_class.call({})
    end

    expect(reactor_class.step_counts[:step1]).to eq(1)
    expect(reactor_class.step_counts[:step2]).to eq(1)
    expect(reactor_class.step_counts[:step3]).to eq(3) # Initial + 2 retries
  end
end
