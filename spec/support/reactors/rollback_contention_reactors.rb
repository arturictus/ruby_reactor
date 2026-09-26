# frozen_string_literal: true

# Fixtures for spec/ruby_reactor/step_coordination/rollback_under_contention_spec.rb
# (US1, 005 quickstart R1). A locked `:charge` succeeds, then `:contend` holds
# the same key as an EXTERNAL owner, releases it from a thread after
# `hold_seconds`, and fails — so `:charge`'s undo has to re-take a key that is
# busy right now. The undo records itself in a Redis list, so the spec can tell
# whether it ran.
module RbcSupport
  def self.redis
    @redis ||= Redis.new(url: RubyReactor.configuration.storage.redis_url)
  end

  def self.log_key(run_id)
    "rbc:log:#{run_id}"
  end

  def self.record(run_id, entry)
    redis.rpush(log_key(run_id), entry)
  end

  # Holds `key` as "external" for `seconds` (released from a thread), so the
  # rollback that follows finds it busy. `seconds <= 0` holds nothing.
  def self.hold(primitive, key, seconds)
    return unless seconds.to_f.positive?

    holder = if primitive == :semaphore
               RubyReactor::Semaphore.new(key, limit: 1)
             else
               RubyReactor::Lock.new(key, owner: "external", ttl: 10, auto_extend: false)
             end
    holder.acquire
    Thread.new do
      sleep seconds.to_f
      holder.release
    end
  end
end

module RbcRecordingCharge
  def self.included(base)
    base.input :run_id
    base.input :account_id
  end

  def run
    Success(:charged)
  end

  def undo
    RbcSupport.record(inputs.run_id, "undo:#{inputs.account_id}")
    Success(:refunded)
  end
end

class RbcChargeStep < RubyReactor::Step
  include RbcRecordingCharge

  # Default forward `wait: 0` — before 005 the rollback re-took the key with
  # that same zero wait and dropped the undo.
  with_lock(ttl: 1) { |a| "rbc:acct:#{a[:account_id]}" }
end

class RbcShortRollbackChargeStep < RbcChargeStep
  with_lock(ttl: 5, rollback_wait: 0.2) { |a| "rbc:acct:#{a[:account_id]}" }
end

class RbcSemaphoreChargeStep < RubyReactor::Step
  include RbcRecordingCharge

  with_semaphore(limit: 1) { |a| "rbc:acct:#{a[:account_id]}" }
end

class RbcRaisingUndoStep < RbcChargeStep
  def undo
    raise "boom"
  end
end

class RbcFailureUndoStep < RbcChargeStep
  def undo
    Failure("nope")
  end
end

class RbcFailingCompensateStep < RubyReactor::Step
  input :run_id

  def run
    Failure("charge declined")
  end

  def compensate
    Failure("comp-fail")
  end
end

# `charge_step` / `primitive` are the only things the variants change.
module RbcReactorShape
  def self.define(reactor, charge_step, primitive: :lock)
    reactor.class_eval do
      input :run_id
      input :account_id
      input :hold_seconds, optional: true

      step :charge, charge_step do
        argument :run_id, input(:run_id)
        argument :account_id, input(:account_id)
      end

      step :contend do
        argument :account_id, input(:account_id)
        argument :hold_seconds, input(:hold_seconds)
        wait_for :charge
        run do |args|
          RbcSupport.hold(primitive, "rbc:acct:#{args.account_id}", args.hold_seconds)
          raise "contend failed after taking the key"
        end
      end
    end
  end
end

class RbcReactor < RubyReactor::Reactor
  RbcReactorShape.define(self, RbcChargeStep)
end

class RbcShortWaitReactor < RubyReactor::Reactor
  RbcReactorShape.define(self, RbcShortRollbackChargeStep)
end

class RbcSemaphoreReactor < RubyReactor::Reactor
  RbcReactorShape.define(self, RbcSemaphoreChargeStep, primitive: :semaphore)
end

class RbcRaisingUndoReactor < RubyReactor::Reactor
  RbcReactorShape.define(self, RbcRaisingUndoStep)
end

class RbcFailureUndoReactor < RubyReactor::Reactor
  RbcReactorShape.define(self, RbcFailureUndoStep)
end

class RbcCompensateReactor < RubyReactor::Reactor
  input :run_id
  input :account_id

  step :charge, RbcChargeStep do
    argument :run_id, input(:run_id)
    argument :account_id, input(:account_id)
  end

  step :settle, RbcFailingCompensateStep do
    argument :run_id, input(:run_id)
    wait_for :charge
  end
end

class RbcChildReactor < RubyReactor::Reactor
  input :run_id
  input :account_id

  step :charge, RbcShortRollbackChargeStep do
    argument :run_id, input(:run_id)
    argument :account_id, input(:account_id)
  end

  returns :charge
end

class RbcComposedParentReactor < RubyReactor::Reactor
  input :run_id
  input :account_id

  compose :child, RbcChildReactor do
    argument :run_id, input(:run_id)
    argument :account_id, input(:account_id)
  end

  step :contend do
    argument :account_id, input(:account_id)
    wait_for :child
    run do |args|
      RbcSupport.hold(:lock, "rbc:acct:#{args.account_id}", 3)
      raise "contend failed after taking the key"
    end
  end
end
