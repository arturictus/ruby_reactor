# frozen_string_literal: true

require "spec_helper"
require "active_job"
require "ruby_reactor/adapters/active_job/sweeper_worker"

RSpec.describe RubyReactor::Adapters::ActiveJob::SweeperWorker do
  around do |example|
    original = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    example.run
  ensure
    ActiveJob::Base.queue_adapter = original
  end

  before do
    described_class.queue_adapter.enqueued_jobs.clear
    allow(RubyReactor::Sweeper).to receive(:run_once).and_return(0)
    allow(RubyReactor::Map::Sweeper).to receive(:run_once).and_return(0)
  end

  describe ".schedule_next" do
    it "enqueues exactly one tick for the upcoming window" do
      described_class.schedule_next
      expect(described_class.queue_adapter.enqueued_jobs.size).to eq(1)
    end

    it "is single-flight: a duplicate call for the same window enqueues nothing more" do
      described_class.schedule_next
      described_class.schedule_next

      expect(described_class.queue_adapter.enqueued_jobs.size).to eq(1)
    end
  end

  describe "#perform" do
    it "runs both sweepers and schedules the next tick" do
      described_class.new.perform

      expect(RubyReactor::Sweeper).to have_received(:run_once)
      expect(RubyReactor::Map::Sweeper).to have_received(:run_once)
      expect(described_class.queue_adapter.enqueued_jobs.size).to eq(1)
    end

    it "still chains forward when a sweep raises (recovery must not die on one bad sweep)" do
      allow(RubyReactor::Sweeper).to receive(:run_once).and_raise(StandardError, "boom")

      expect { described_class.new.perform }.not_to raise_error
      expect(described_class.queue_adapter.enqueued_jobs.size).to eq(1)
    end

    context "when the sweeper is disabled" do
      around do |example|
        original = RubyReactor.configuration.sweeper_enabled
        RubyReactor.configuration.sweeper_enabled = false
        example.run
        RubyReactor.configuration.sweeper_enabled = original
      end

      it "does not sweep and does not chain" do
        described_class.new.perform

        expect(RubyReactor::Sweeper).not_to have_received(:run_once)
        expect(described_class.queue_adapter.enqueued_jobs).to be_empty
      end
    end
  end
end
