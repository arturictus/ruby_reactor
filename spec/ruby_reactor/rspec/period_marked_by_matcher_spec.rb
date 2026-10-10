# frozen_string_literal: true

require "spec_helper"

class PeriodMarkedByMatcherReactor < RubyReactor::Reactor
  input :name
  with_period(every: :year) { |inputs| "annual:#{inputs[:name]}" }

  step :build do
    run { RubyReactor.Success(:built) }
  end
end

# 011 US5: `be_period_marked.for(every).by(execution_id)` names the claiming run.
RSpec.describe "be_period_marked.by", type: :reactor do
  it "matches the run that claimed the bucket, and no other" do
    first = test_reactor(PeriodMarkedByMatcherReactor, { name: "sales" })
    expect(first).to be_success
    second = test_reactor(PeriodMarkedByMatcherReactor, { name: "sales" })
    expect(second).to be_halted

    first_id = first.reactor_instance.context.context_id
    expect("annual:sales").to be_period_marked.for(:year).by(first_id)
    expect("annual:sales").not_to be_period_marked.for(:year).by(second.reactor_instance.context.context_id)
  end
end
