# frozen_string_literal: true

require "rails_helper"

RSpec.describe RateLimitDemoReactor, type: :reactor do
  let(:inputs) { { account_id: "acct_1", hold_seconds: 0 } }

  subject(:reactor) { test_reactor(described_class, inputs) }

  def run_sync(**overrides)
    test_reactor(described_class, inputs.merge(overrides), async: false).result
  end

  context "within the rate limit window" do
    it "allows up to three calls per second" do
      3.times do
        expect(run_sync).to be_success
      end

      expect("api:acct_1").to have_rate_limit_count(3).for(:second)
    end
  end

  context "when the rate limit window is full" do
    before do
      3.times { run_sync }
    end

    it "raises RateLimit::ExceededError on the fourth call" do
      expect { run_sync }
        .to raise_error(RubyReactor::RateLimit::ExceededError)
    end

    it "does not increment the counter when the limit is exceeded" do
      bucket_key = "rate:api:acct_1:second:#{Time.now.to_i / 1}"
      before_count = redis.get(bucket_key).to_i

      begin
        run_sync
      rescue RubyReactor::RateLimit::ExceededError
        nil
      end

      after_count = redis.get(bucket_key).to_i
      expect(after_count).to eq(before_count)
    end
  end

  it "completes a single call successfully" do
    expect(reactor).to be_success
    expect(reactor).to have_run_step(:call_external_api)
  end
end
