# frozen_string_literal: true

require "rails_helper"

RSpec.describe PeriodDemoReactor, type: :reactor do
  let(:inputs) { { org_id: "org_7" } }

  subject(:reactor) { test_reactor(described_class, inputs) }

  context "first run in a bucket" do
    it "completes successfully and runs all steps" do
      expect(reactor).to be_success
      expect(reactor).to have_run_step(:build_report)
      expect(reactor).to have_run_step(:publish_report).after(:build_report)
    end

    it "marks the period bucket" do
      expect(reactor).to be_success
      expect("daily_report:org_7").to be_period_marked.for(:day)
    end
  end

  context "second run in the same bucket" do
    before { described_class.run(org_id: "org_7") }

    it "returns a Skipped result without re-running steps" do
      result = described_class.run(org_id: "org_7")

      expect(result).to be_skipped.because(:period)
      expect(result.skipped?).to be true
      expect(result.success?).to be true
    end
  end
end
