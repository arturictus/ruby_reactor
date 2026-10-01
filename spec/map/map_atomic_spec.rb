# frozen_string_literal: true

require "spec_helper"

# 009 US4, FR-020–FR-022, SC-006: `atomic` names the map failure policy.
# `fail_fast` stays as a warned alias; declaring both is an error. This file
# keeps the one example that uses the deprecated alias.
module MapAtomicSpec
  def self.define(policy = nil, both: false)
    Class.new(RollbackRecorder::Reactor) do
      input :items
      input :fail_at, optional: true
      map :m, MapRollbackFixtures::Elem do
        source input(:items)
        argument :i, element(:m)
        argument :fail_at, input(:fail_at)
        atomic(policy != :atomic_false) if both || policy == :atomic_false
        fail_fast false if policy == :fail_fast_false
        fail_fast true if both # its own call site, so the warn-once example never depends on order
      end
    end
  end

  Default = define
  Partial = define(:atomic_false)
end

RSpec.describe "map atomic" do
  let(:items) { { items: [0, 1, 2, 3], fail_at: 2 } }

  before { RollbackRecorder.reset! }

  it "fails the map on one element failure and rolls back the completed elements by default" do
    result = MapAtomicSpec::Default.run(items)

    expect(result).to be_failure
    expect(RollbackRecorder.log).to include("undo:e.e2[1]", "undo:e.e1[1]", "undo:e.e2[0]", "undo:e.e1[0]")
  end

  it "completes with every element's outcome with atomic false" do
    result = MapAtomicSpec::Partial.run(items)

    expect(result).to be_success
    expect(result.value[:m].count(&:failure?)).to eq(1)
  end

  it "keeps fail_fast as a deprecated alias that warns once per declaration site" do
    reactor = nil
    expect { reactor = MapAtomicSpec.define(:fail_fast_false) }
      .to output(/\[RubyReactor\] DEPRECATION: .* fail_fast.*atomic/).to_stderr
    expect { MapAtomicSpec.define(:fail_fast_false) }.not_to output.to_stderr

    result = reactor.run(items)
    expect(result).to be_success
    expect(result.value[:m].count(&:failure?)).to eq(1)
  end

  it "rejects fail_fast and atomic on one map" do
    expect { MapAtomicSpec.define(both: true) }
      .to raise_error(RubyReactor::Error::ValidationError, /declares both fail_fast and atomic/)
  end
end
