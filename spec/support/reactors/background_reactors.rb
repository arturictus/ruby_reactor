# frozen_string_literal: true

# Fixtures for the reactor-level `background` hand-off (US1). Every reactor
# records where each step actually ran, so a spec can assert the boundary
# directly instead of inferring it from job counts.
module BackgroundFixtures
  # Where each step ran, keyed by reactor label. Steps append :here when they
  # execute in the calling process and :worker when they execute inside a
  # drained job — the one thing these fixtures exist to observe.
  def self.trace
    @trace ||= Hash.new { |h, k| h[k] = [] }
  end

  def self.reset!
    @trace = nil
  end

  def self.record(label, step, context)
    trace[label] << [step, context.inline_async_execution ? :worker : :here]
    step
  end
end

# `after: :second` — :second is the last step to run in the calling process.
class BackgroundAfterReactor < RubyReactor::Reactor
  step :first do
    run { |_a, ctx| RubyReactor.Success(BackgroundFixtures.record(:after, :first, ctx)) }
  end

  step :second do
    argument :first, result(:first)
    run { |_a, ctx| RubyReactor.Success(BackgroundFixtures.record(:after, :second, ctx)) }
  end

  step :third do
    argument :second, result(:second)
    run { |_a, ctx| RubyReactor.Success(BackgroundFixtures.record(:after, :third, ctx)) }
  end

  background after: :second

  returns :third
end

# The same linear flow cut from the other side. In a linear chain this is
# equivalent to BackgroundAfterReactor.
class BackgroundBeforeReactor < RubyReactor::Reactor
  step :first do
    run { |_a, ctx| RubyReactor.Success(BackgroundFixtures.record(:before, :first, ctx)) }
  end

  step :second do
    argument :first, result(:first)
    run { |_a, ctx| RubyReactor.Success(BackgroundFixtures.record(:before, :second, ctx)) }
  end

  step :third do
    argument :second, result(:second)
    run { |_a, ctx| RubyReactor.Success(BackgroundFixtures.record(:before, :third, ctx)) }
  end

  background before: :third

  returns :third
end

# A step failing in the worker must compensate exactly as a same-process
# failure does — `background` relocates code, it does not change the saga.
class BackgroundCompensationReactor < RubyReactor::Reactor
  def self.compensated
    @compensated ||= []
  end

  def self.reset!
    @compensated = []
  end

  step :reserve do
    run { RubyReactor.Success(:reserved) }
    compensate do |_reason, _args, _ctx|
      BackgroundCompensationReactor.compensated << :reserve
      RubyReactor.Success()
    end
    undo do |_result, _args, _ctx|
      BackgroundCompensationReactor.compensated << :reserve
      RubyReactor.Success()
    end
  end

  step :charge do
    argument :reserved, result(:reserve)
    run { RubyReactor.Failure("charge declined") }
  end

  background after: :reserve
end

# Branching: :audit and :ship are independent of each other. `after: :audit`
# and `before: :ship` therefore pin DIFFERENT steps — the whole reason both
# forms exist.
class BackgroundBranchingAfterReactor < RubyReactor::Reactor
  step :prepare do
    run { |_a, ctx| RubyReactor.Success(BackgroundFixtures.record(:branch_after, :prepare, ctx)) }
  end

  step :audit do
    argument :prepare, result(:prepare)
    run { |_a, ctx| RubyReactor.Success(BackgroundFixtures.record(:branch_after, :audit, ctx)) }
  end

  step :ship do
    argument :prepare, result(:prepare)
    run { |_a, ctx| RubyReactor.Success(BackgroundFixtures.record(:branch_after, :ship, ctx)) }
  end

  background after: :audit
end

class BackgroundBranchingBeforeReactor < RubyReactor::Reactor
  step :prepare do
    run { |_a, ctx| RubyReactor.Success(BackgroundFixtures.record(:branch_before, :prepare, ctx)) }
  end

  step :audit do
    argument :prepare, result(:prepare)
    run { |_a, ctx| RubyReactor.Success(BackgroundFixtures.record(:branch_before, :audit, ctx)) }
  end

  step :ship do
    argument :prepare, result(:prepare)
    run { |_a, ctx| RubyReactor.Success(BackgroundFixtures.record(:branch_before, :ship, ctx)) }
  end

  background before: :ship
end

# The declaration sits FIRST in the class body — hand-off is keyed to reaching
# the named step, not to lexical position.
class BackgroundDeclaredFirstReactor < RubyReactor::Reactor
  step :only_first do
    run { |_a, ctx| RubyReactor.Success(BackgroundFixtures.record(:declared_first, :only_first, ctx)) }
  end

  background after: :only_first

  step :then_this do
    argument :first, result(:only_first)
    run { |_a, ctx| RubyReactor.Success(BackgroundFixtures.record(:declared_first, :then_this, ctx)) }
  end
end

# The named step is guarded off, so the hand-off never fires and the whole run
# finishes in the calling process.
class BackgroundSkippedTriggerReactor < RubyReactor::Reactor
  input :hand_off

  step :first do
    run { |_a, ctx| RubyReactor.Success(BackgroundFixtures.record(:skipped_trigger, :first, ctx)) }
  end

  step :maybe do
    argument :hand_off, input(:hand_off)
    where { |ctx| ctx.get_input(:hand_off) }
    run { |_a, ctx| RubyReactor.Success(BackgroundFixtures.record(:skipped_trigger, :maybe, ctx)) }
  end

  step :last do
    argument :maybe, result(:maybe)
    run { |_a, ctx| RubyReactor.Success(BackgroundFixtures.record(:skipped_trigger, :last, ctx)) }
  end

  background after: :maybe
end
