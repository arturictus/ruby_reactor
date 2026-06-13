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

  context "when the async worker hits a full window on its first pass" do
    it "snoozes with the retry_after hint instead of running or failing" do
      3.times { run_sync }

      RubyReactor.configuration.lock_snooze_jitter = 0
      allow(RubyReactor::SidekiqWorkers::Worker).to receive(:perform_in)

      context = RubyReactor::Context.new(inputs, described_class)
      serialized_context = RubyReactor::ContextSerializer.serialize(context)

      worker = RubyReactor::SidekiqWorkers::Worker.new
      worker.perform(serialized_context, described_class.name)

      # The step never ran (window full) and the job re-enqueued itself for
      # when the bucket rolls — it did not burn Sidekiq retry budget.
      expect("api:acct_1").to have_rate_limit_count(3).for(:second)
      expect(RubyReactor::SidekiqWorkers::Worker).to have_received(:perform_in)
        .with(a_value >= 0.1, instance_of(String), described_class.name, 1)
    end
  end
end
