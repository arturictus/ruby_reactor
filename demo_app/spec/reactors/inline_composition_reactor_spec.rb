require "rails_helper"

RSpec.describe InlineCompositionReactor, type: :reactor do
  subject(:reactor) { test_reactor(described_class, { numbers: [1, 2, 3, 4] }) }

  it "runs the inline composed block and the final step" do
    expect(reactor).to be_success
    # An inline `compose do ... end` exposes the full sub-result hash to the
    # consuming step, so :final_output stringifies the whole map.
    expect(reactor.result.value).to eq("Average is #{ { sum: 10, average: 2.5 }.inspect }")
  end

  it "runs the composed step and final_output in order" do
    expect(reactor).to have_run_step(:process_numbers)
    expect(reactor).to have_run_step(:final_output).after(:process_numbers)
  end

  it "stores the composed sub-results under :process_numbers" do
    reactor.ensure_executed!
    expect(reactor.step_result(:process_numbers)).to eq(sum: 10, average: 2.5)
  end
end
