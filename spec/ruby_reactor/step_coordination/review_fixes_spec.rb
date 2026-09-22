# frozen_string_literal: true

require "spec_helper"

# A step whose key reads an input the CONTRACT supplies: every site that
# computes the key (forward, rollback, the async dispatch guard, the
# dashboard) has to apply the defaults first or it computes a different key
# than the one actually held.
class DefaultedKeyStep < RubyReactor::Step
  input :account_id
  input :region, :string, optional: true, default: "eu"

  with_lock(wait: 0) { |args| "acct:#{args[:account_id]}:#{args[:region]}" }

  def run
    Success(region: inputs[:region])
  end
end

class DefaultedKeyReactor < RubyReactor::Reactor
  input :account_id

  step :charge, DefaultedKeyStep do
    argument :account_id, input(:account_id)
  end

  returns :charge
end

RSpec.describe "step coordination review fixes", :step_coordination do
  def unique_account_id
    SecureRandom.random_number(10**9)
  end

  describe "the direct-invocation contract" do
    it "runs a coordinated step stand-alone, with no context argument" do
      result = DefaultedKeyStep.run(account_id: unique_account_id)

      expect(result).to be_a(RubyReactor::Success)
      expect(result.value).to eq(region: "eu")
    end

    it "releases the hold, so a second stand-alone call on the same key succeeds" do
      account_id = unique_account_id

      expect(DefaultedKeyStep.run(account_id: account_id)).to be_a(RubyReactor::Success)
      expect(DefaultedKeyStep.run(account_id: account_id)).to be_a(RubyReactor::Success)
    end
  end

  describe "RubyReactor::Web::CoordinationSerializer" do
    it "resolves the step's key from the contract-applied inputs, not the raw trace arguments" do
      account_id = unique_account_id
      context = RubyReactor::Context.new({ account_id: account_id }, DefaultedKeyReactor)
      expect(RubyReactor::Executor.new(DefaultedKeyReactor, {}, context).execute).to be_a(RubyReactor::Success)

      coordination = RubyReactor::Web::CoordinationSerializer.build(
        DefaultedKeyReactor, inputs: {}, context_id: context.context_id,
                             execution_trace: context.execution_trace, private_data: context.private_data
      )

      row = coordination[:steps].find { |s| s[:step] == "charge" }
      expect(row[:key]).to eq("acct:#{account_id}:eu")
    end

    it "renders a named step rate limit as its registered windows, keyed by the name" do
      RubyReactor.configuration.rate_limits.register(:step_coordination_named_limit, limit: 1, period: :minute)
      account_id = unique_account_id
      context = RubyReactor::Context.new({ account_id: account_id }, StepNamedRateLimitedReactor)
      expect(RubyReactor::Executor.new(StepNamedRateLimitedReactor, {}, context).execute)
        .to be_a(RubyReactor::Success)

      coordination = RubyReactor::Web::CoordinationSerializer.build(
        StepNamedRateLimitedReactor, inputs: {}, context_id: context.context_id,
                                     execution_trace: context.execution_trace, private_data: context.private_data
      )

      row = coordination[:steps].find { |s| s[:step] == "charge" }
      expect(row[:key]).to eq("step_coordination_named_limit")
      expect(row[:key_error]).to be_nil
      expect(row[:state].map { |w| w[:name].to_s }).to eq(["minute"])
    end
  end

  describe "synchronous contention" do
    it "records no park markers — there is no queue to park into, the step just fails" do
      account_id = unique_account_id
      key = "acct:#{account_id}"
      holder = RubyReactor::Lock.new(key, owner: "external-holder", ttl: 5, wait: 0, auto_extend: true)
      holder.acquire

      context = RubyReactor::Context.new(
        { run_id: step_coord_run_id, account_id: account_id }, WaitZeroLockedChargeReactor
      )
      result = RubyReactor::Executor.new(WaitZeroLockedChargeReactor, {}, context).execute

      expect(result).to be_a(RubyReactor::Failure)
      expect(context.execution_trace.map { |e| e[:type].to_s }).not_to include("contention_park")
      expect(context.private_data[:step_contention]).to be_nil
    ensure
      holder&.release
    end
  end
end
