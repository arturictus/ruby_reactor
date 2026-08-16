# frozen_string_literal: true

require "spec_helper"
require "sidekiq/testing"
require "ruby_reactor/adapters/sidekiq/sweeper_worker"

RSpec.describe RubyReactor::Adapters::Sidekiq::SweeperWorker do
  before do
    described_class.clear
    # The sweep itself is exercised by the Sweeper specs; here we only care about
    # the scheduling/chaining behavior, so stub the actual recovery work out.
    allow(RubyReactor::Sweeper).to receive(:run_once).and_return(0)
    allow(RubyReactor::Map::Sweeper).to receive(:run_once).and_return(0)
  end

  describe ".schedule_next" do
    it "enqueues exactly one tick for the upcoming window" do
      described_class.schedule_next
      expect(described_class.jobs.size).to eq(1)
    end

    it "is single-flight: a duplicate call for the same window enqueues nothing more" do
      described_class.schedule_next
      described_class.schedule_next # same time window -> claim already held

      # The window lock collapses the duplicate, so no fork — exactly the property
      # that keeps a super_fetch-recovered tick from doubling the chain.
      expect(described_class.jobs.size).to eq(1)
    end
  end

  describe "#perform" do
    it "runs both sweepers and schedules the next tick" do
      described_class.new.perform

      expect(RubyReactor::Sweeper).to have_received(:run_once)
      expect(RubyReactor::Map::Sweeper).to have_received(:run_once)
      expect(described_class.jobs.size).to eq(1) # chained forward
    end

    it "still chains forward when a sweep raises (recovery must not die on one bad sweep)" do
      allow(RubyReactor::Sweeper).to receive(:run_once).and_raise(StandardError, "boom")

      expect { described_class.new.perform }.not_to raise_error
      expect(described_class.jobs.size).to eq(1)
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
        expect(described_class.jobs).to be_empty
      end
    end
  end
end
