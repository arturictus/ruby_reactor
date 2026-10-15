# frozen_string_literal: true

require "rails_helper"

# 011 US5: once per year; the claim names the run that made it.
RSpec.describe YearlyReportReactor, type: :reactor do
  let(:name) { "sales_#{SecureRandom.hex(3)}" }

  it "runs once a year and records which run claimed the year" do
    first = test_reactor(described_class, { report_name: name })
    second = test_reactor(described_class, { report_name: name })

    expect(first).to be_success
    expect(second).to be_halted
    expect("annual:#{name}").to be_period_marked.for(:year).by(first.reactor_instance.context.context_id)
  end

  it "does not claim the year when the report fails, so the next run executes" do
    failed = test_reactor(described_class, { report_name: name, fail: true })
    expect(failed).to be_failure
    expect("annual:#{name}").not_to be_period_marked.for(:year)

    retried = test_reactor(described_class, { report_name: name })
    expect(retried).to be_success
    expect("annual:#{name}").to be_period_marked.for(:year).by(retried.reactor_instance.context.context_id)
  end
end
