# frozen_string_literal: true

# Demonstrates an `async_step` compensating itself. :notify is dispatched to
# its own job and nothing reads its result. Its body always fails; after its
# second (last) attempt, its `compensate` runs ONCE, in the unit's own job,
# and the outcome is recorded on the unit's Step Result Record as
# `compensation`. The parent is unaffected: it already completed.
#
# Log helpers live on the reactor: Zeitwerk only autoloads the constant
# matching this file's name.
class AsyncStepCompensateActivateStep < RubyReactor::Step
  input :user_id, :string

  def run
    Success(activated: inputs.user_id)
  end
end

class AsyncStepCompensateNotifyStep < RubyReactor::Step
  input :user_id, :string

  def run
    AsyncStepCompensateDemoReactor.log << "notify #{inputs.user_id}"
    Failure("push gateway unavailable")
  end

  def compensate
    AsyncStepCompensateDemoReactor.log << "compensate notify #{inputs.user_id}: #{reason}"
    Success()
  end
end

class AsyncStepCompensateDemoReactor < RubyReactor::Reactor
  def self.log
    @log ||= []
  end

  def self.reset!
    @log = []
  end

  input :user_id, :string

  step :activate, AsyncStepCompensateActivateStep do
    argument :user_id, input(:user_id)
  end

  async_step :notify, AsyncStepCompensateNotifyStep do
    argument :user_id, input(:user_id)
    wait_for :activate
    retries max_attempts: 2, base_delay: 0
  end
end
