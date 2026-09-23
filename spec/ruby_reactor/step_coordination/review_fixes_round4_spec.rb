# frozen_string_literal: true

require "spec_helper"

# Counters the fixture bodies below bump, so a spec can tell how many times a
# step's work actually ran.
ROUND4_COUNTS = Hash.new(0)

# An `async_step` whose key proc raises: the dispatch-time deadlock guard
# computes that key while the parent holds one of its own, so the failure must
# arrive as a normal step failure (rolling the earlier step back), not as a
# generic execution error.
class Round4RaisingKeyStep < RubyReactor::Step
  input :account_id

  with_lock(wait: 0) { |_args| raise "key proc blew up" }

  def run
    Success(:charged)
  end
end

class Round4GuardKeyReactor < RubyReactor::Reactor
  with_lock(ttl: 60, wait: 0) { |inputs| "round4_guard:#{inputs[:account_id]}" }

  input :account_id

  step :setup do
    argument :account_id, input(:account_id)
    run { |args| RubyReactor.Success(args[:account_id]) }
    undo { ROUND4_COUNTS[:setup_undo] += 1 }
  end

  async_step :charge, Round4RaisingKeyStep do
    argument :account_id, result(:setup)
  end

  step :ack do
    run { RubyReactor.Success(:dispatched) }
  end

  returns :ack
end

# A step deduped by a window whose body returns a value its own output
# contract rejects: the bucket must NOT be marked, or the next run is deduped
# away on behalf of a step that failed.
class Round4PeriodReactor < RubyReactor::Reactor
  input :account_id

  step :charge do
    argument :account_id, input(:account_id)
    with_period(every: :hour) { |args| "round4_period:#{args[:account_id]}" }
    validate_output :integer
    run do |args|
      ROUND4_COUNTS[:period_body] += 1
      RubyReactor.Success("not an integer: #{args[:account_id]}")
    end
  end

  returns :charge
end

class Round4DuplicateStep < RubyReactor::Step
  input :account_id

  def run
    ROUND4_COUNTS[:duplicate_body] += 1
    Success(:charged)
  end
end

class Round4DuplicateReactor < RubyReactor::Reactor
  input :account_id

  async_step :charge, Round4DuplicateStep do
    argument :account_id, input(:account_id)
  end

  step :ack do
    run { RubyReactor.Success(:dispatched) }
  end

  returns :ack
end

RSpec.describe "step coordination review fixes (round 4)", :step_coordination do
  def unique_account_id
    SecureRandom.random_number(10**9)
  end

  before { ROUND4_COUNTS.clear }

  describe "an async_step deadlock guard whose key proc raises" do
    it "fails the step with a KeyError and still rolls the earlier step back" do
      result = Round4GuardKeyReactor.run(account_id: unique_account_id)

      expect(result).to be_a(RubyReactor::Failure)
      expect(result.error.to_s).to match(/key proc raised RuntimeError/)
      expect(result.to_h[:exception_class]).to eq("RubyReactor::Executor::StepCoordination::KeyError")
      expect(ROUND4_COUNTS[:setup_undo]).to eq(1)
    end
  end

  describe "a once-per-window step whose output contract rejects its value" do
    it "leaves the bucket unmarked, so the next execution runs the step again" do
      account_id = unique_account_id

      2.times { expect(Round4PeriodReactor.run(account_id: account_id)).to be_a(RubyReactor::Failure) }

      expect(ROUND4_COUNTS[:period_body]).to eq(2)
    end
  end

  describe "a redelivery of an async_step unit that already finished" do
    it "is dropped instead of running the body a second time" do
      Round4DuplicateReactor.run(account_id: unique_account_id)
      job = RubyReactor::Adapters::Sidekiq::StepWorker.jobs.last
      RubyReactor::Adapters::Sidekiq::StepWorker.jobs.clear

      2.times { RubyReactor::Adapters::Sidekiq::StepWorker.new.perform(*job["args"]) }

      expect(ROUND4_COUNTS[:duplicate_body]).to eq(1)
    end
  end
end
