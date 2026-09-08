# frozen_string_literal: true

require "spec_helper"
require "sidekiq/testing"
require "ruby_reactor/adapters/sidekiq/sweeper_worker"

# Module-level sweeper entrypoints: the host kick (start_sweeper!) and the
# synchronous escape hatch (sweep_once).
RSpec.describe "RubyReactor sweeper entrypoints" do
  let(:worker) { RubyReactor::Adapters::Sidekiq::SweeperWorker }

  before do
    worker.clear
    allow(RubyReactor::Sweeper).to receive(:run_once).and_return(2)
    allow(RubyReactor::Map::Sweeper).to receive(:run_once).and_return(3)
    allow(RubyReactor::StepSweeper).to receive(:run_once).and_return(4)
  end

  describe ".start_sweeper!" do
    it "kicks the chain when enabled" do
      RubyReactor.start_sweeper!
      expect(worker.jobs.size).to eq(1)
    end

    it "is idempotent across repeated boots (same window claimed once)" do
      RubyReactor.start_sweeper!
      RubyReactor.start_sweeper!
      expect(worker.jobs.size).to eq(1)
    end

    context "when disabled" do
      around do |example|
        original = RubyReactor.configuration.sweeper_enabled
        RubyReactor.configuration.sweeper_enabled = false
        example.run
        RubyReactor.configuration.sweeper_enabled = original
      end

      it "is a no-op returning nil" do
        expect(RubyReactor.start_sweeper!).to be_nil
        expect(worker.jobs).to be_empty
      end
    end
  end

  describe ".sweep_once" do
    it "runs every sweeper once and returns their counts" do
      expect(RubyReactor.sweep_once).to eq(reactors: 2, maps: 3, async_steps: 4)
    end
  end
end
