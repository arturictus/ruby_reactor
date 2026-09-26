# frozen_string_literal: true

# Demonstrates retries declared on a STEP class, not the reactor: the
# reactor below has no `retries` line anywhere, yet :charge retries under
# FlakyChargeStep's own policy, and :notify (which declares none) runs once.
class StepRetryDemoLog
  class << self
    attr_accessor :charge_attempts, :notify_attempts, :compensated

    def reset!
      @charge_attempts = 0
      @notify_attempts = 0
      @compensated = false
    end
  end

  reset!
end

class ReserveStockStep < RubyReactor::Step
  def run = Success(reserved: true)

  # A later step failed for good: give the stock back.
  def undo
    StepRetryDemoLog.compensated = true
    Success()
  end
end

# The policy lives here, next to the call it protects. Any reactor using this
# step gets it, with no wiring.
class FlakyChargeStep < RubyReactor::Step
  input :fail_times, :integer

  retries max_attempts: 3, backoff: :fixed, base_delay: 0.05

  def run
    attempt = StepRetryDemoLog.charge_attempts += 1
    return Failure("card declined (attempt #{attempt})") if attempt <= inputs.fail_times

    Success(charged: true)
  end
end

# No `retries`: a failure here is final on the first attempt.
class NotifyStep < RubyReactor::Step
  input :fail_notify, optional: true

  def run
    StepRetryDemoLog.notify_attempts += 1
    return Failure("notification service down") if inputs.fail_notify

    Success(notified: true)
  end
end

class StepRetryDemoReactor < RubyReactor::Reactor
  input :fail_times, :integer
  input :fail_notify, optional: true

  step :reserve_stock, ReserveStockStep

  step :charge, FlakyChargeStep do
    argument :fail_times, input(:fail_times)
    wait_for :reserve_stock
  end

  step :notify, NotifyStep do
    argument :fail_notify, input(:fail_notify)
    wait_for :charge
  end

  returns :notify
end
