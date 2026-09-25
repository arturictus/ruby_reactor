# frozen_string_literal: true

# Fixtures for spec/ruby_reactor/step_coordination/attribution_spec.rb (US5,
# 005 quickstart R5, P5): coordination events and contention messages name the
# step that actually coordinates.
class AttrChargeStep < RubyReactor::Step
  input :account_id

  with_lock { |a| "attr:s:#{a[:account_id]}" }

  def run
    Success(:charged)
  end
end

class AttrReactor < RubyReactor::Reactor
  background all: true

  with_lock { |i| "attr:r:#{i[:run_id]}" }

  input :run_id
  input :account_id

  step :charge, AttrChargeStep do
    argument :account_id, input(:account_id)
  end

  returns :charge
end

# :outer's body invokes the step class DIRECTLY — its own unit of work.
class AttrDirectOuterReactor < RubyReactor::Reactor
  input :account_id

  step :outer do
    argument :account_id, input(:account_id)
    run { |args, context| AttrChargeStep.run({ account_id: args[:account_id] }, context) }
  end

  returns :outer
end
