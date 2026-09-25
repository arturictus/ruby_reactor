# frozen_string_literal: true

# Demonstrates step-scoped coordination (`with_lock` declared on a STEP
# class, not the reactor): only :charge serializes per account, :audit and
# :notify run unconstrained, and a failure after :charge succeeds rolls it
# back under its own lock (`undo`), never the whole reactor's.
class StepLockDemoLog
  class << self
    def reset!
      @entries = []
    end

    def record(entry)
      @entries ||= []
      @entries << entry
    end

    def entries
      @entries ||= []
    end
  end
end

# Unlocked — runs unconstrained even while another execution's :charge
# holds the lock on the same account.
class StepLockAuditStep < RubyReactor::Step
  input :account_id, :string

  def run
    StepLockDemoLog.record(step: :audit, account_id: inputs[:account_id], at: Time.current.iso8601(3))
    Success(audited: true)
  end
end

# The one locked position: at most one runner per account_id at a time.
class StepLockChargeStep < RubyReactor::Step
  input :account_id, :string

  with_lock(wait: 2) { |args| "demo:acct:#{args[:account_id]}" }

  def run
    StepLockDemoLog.record(step: :charge, phase: :run, account_id: inputs[:account_id],
                                                    at: Time.current.iso8601(3))
    Success(charged: true, account_id: inputs[:account_id])
  end

  # Exercised when :charge ITSELF fails (not used by the demo's
  # `fail_after_charge` scenario, which fails a LATER step instead — kept
  # here so the class demonstrates both rollback paths (contract §6)).
  def compensate
    StepLockDemoLog.record(step: :charge, phase: :compensate, account_id: inputs[:account_id],
                                                    at: Time.current.iso8601(3))
    Success()
  end

  # Exercised by the demo's `fail_after_charge` scenario: :charge succeeds,
  # :notify fails, and this runs to roll :charge back — under :charge's OWN
  # lock, re-acquired for the duration of the undo (contract §6).
  def undo
    StepLockDemoLog.record(step: :charge, phase: :undo, account_id: inputs[:account_id],
                                                    at: Time.current.iso8601(3))
    Success()
  end
end

# Unlocked — also the scenario's failure trigger.
class StepLockNotifyStep < RubyReactor::Step
  input :account_id, :string
  input :fail_after_charge, optional: true

  def run
    if inputs[:fail_after_charge]
      return Failure("forced failure after charge, to demonstrate compensation under the step's own lock")
    end

    StepLockDemoLog.record(step: :notify, account_id: inputs[:account_id], at: Time.current.iso8601(3))
    Success(notified: true)
  end
end

class StepLockDemoReactor < RubyReactor::Reactor
  background all: true

  input :account_id, :string
  input :fail_after_charge, optional: true

  step :audit, StepLockAuditStep do
    argument :account_id, input(:account_id)
  end

  step :charge, StepLockChargeStep do
    argument :account_id, input(:account_id)
    wait_for :audit
  end

  step :notify, StepLockNotifyStep do
    argument :account_id, input(:account_id)
    argument :fail_after_charge, input(:fail_after_charge)
    wait_for :charge
  end

  returns :notify
end
