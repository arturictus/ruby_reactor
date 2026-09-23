# frozen_string_literal: true

# Demonstrates rollback under contention for a step-level `with_lock`:
# :charge succeeds, then :contend takes the SAME key as an outside owner and
# fails. :charge's undo must re-take a key that is busy right now:
#
#   - the holder releases within `rollback_wait:` -> the undo waits, then runs;
#   - the holder keeps it longer -> the undo does not run, and the failure
#     reports it on `result.rollback_failures` instead of dropping it silently.
#
# Self-contained (its own undo log) rather than reusing StepLockDemoLog: Zeitwerk
# only autoloads the constant matching each file name, so this file must not
# depend on classes defined inside step_lock_demo_reactor.rb.
class StepLockRollbackChargeStep < RubyReactor::Step
  input :account_id, :string

  # Forward: wait up to 2 s for the key. Rollback: wait up to 1 s (the default
  # would be the lock's `ttl`, 60 s — shortened so the demo's "exceeded" case
  # is quick).
  with_lock(wait: 2, rollback_wait: 1) { |args| "demo:acct:#{args[:account_id]}" }

  def self.undone
    @undone ||= []
  end

  def run
    Success(charged: true, account_id: inputs[:account_id])
  end

  def undo
    self.class.undone << inputs[:account_id]
    Success(refunded: true)
  end
end

# Takes :charge's key as "demo-external", releases it from a thread after
# `rollback_hold_seconds`, then fails — so the rollback finds the key busy.
class StepLockRollbackContenderStep < RubyReactor::Step
  input :account_id, :string
  input :rollback_hold_seconds, :float

  def run
    key = "demo:acct:#{inputs[:account_id]}"
    holder = RubyReactor::Lock.new(key, owner: "demo-external", ttl: 30, auto_extend: false)
    holder.acquire
    Thread.new do
      sleep inputs[:rollback_hold_seconds]
      holder.release
    end
    Failure("contender holds #{key} for #{inputs[:rollback_hold_seconds]}s, then fails")
  end
end

class StepLockRollbackDemoReactor < RubyReactor::Reactor
  input :account_id, :string
  input :rollback_hold_seconds, :float

  step :charge, StepLockRollbackChargeStep do
    argument :account_id, input(:account_id)
  end

  step :contend, StepLockRollbackContenderStep do
    argument :account_id, input(:account_id)
    argument :rollback_hold_seconds, input(:rollback_hold_seconds)
    wait_for :charge
  end
end
