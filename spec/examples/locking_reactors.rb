# frozen_string_literal: true

class SimpleLockReactor < RubyReactor::Reactor
  with_lock(ttl: 10) { |inputs| "user_#{inputs[:user_id]}" }

  step :process do
    run do |_inputs|
      # Simulating work
      RubyReactor.Success(processed: true)
    end
  end
end

class NestedChildReactor < RubyReactor::Reactor
  with_lock(ttl: 10) { |_inputs| "shared_resource" }

  step :child do
    run do |_inputs|
      RubyReactor.Success(child_done: true)
    end
  end
end

class NestedLockReactor < RubyReactor::Reactor
  with_lock(ttl: 10) { |_inputs| "shared_resource" }

  compose :parent, NestedChildReactor do
    # Compose automatically links contexts and uses same root_context
  end
end

class SemaphoreReactor < RubyReactor::Reactor
  with_semaphore(limit: 2, wait: 0) { |_inputs| "api_limit" }

  step :call_api do
    run do |_inputs|
      # Simulating API call
      RubyReactor.Success(api_called: true)
    end
  end
end

class InheritedLockReactor < SimpleLockReactor
end

class InheritedSemaphoreReactor < SemaphoreReactor
end

module PeriodicCounters
  class << self
    attr_accessor :runs, :locked_runs

    def reset
      @runs = 0
      @locked_runs = 0
    end
  end
  reset
end

class PeriodicReactor < RubyReactor::Reactor
  with_period(every: :day) { |inputs| "daily_report:#{inputs[:org_id]}" }

  step :build_report do
    run do |_inputs|
      PeriodicCounters.runs += 1
      RubyReactor.Success(built: true)
    end
  end
end

class FailingPeriodicReactor < RubyReactor::Reactor
  with_period(every: :day) { |inputs| "failing_daily:#{inputs[:org_id]}" }

  step :always_fail do
    run do |_inputs|
      RubyReactor.Failure(StandardError.new("boom"))
    end
  end
end

class LockedPeriodicReactor < RubyReactor::Reactor
  with_lock(ttl: 10, auto_extend: false) { |inputs| "locked_periodic:#{inputs[:id]}" }
  with_period(every: :day) { |inputs| "locked_periodic:#{inputs[:id]}" }

  step :work do
    run do |_inputs|
      PeriodicCounters.locked_runs += 1
      RubyReactor.Success(ok: true)
    end
  end
end

module RateLimitCounters
  class << self
    attr_accessor :runs

    def reset
      @runs = 0
    end
  end
  reset
end

class RateLimitedReactor < RubyReactor::Reactor
  with_rate_limit(limit: 3, period: :second) { |inputs| "api:#{inputs[:account_id]}" }

  step :call_api do
    run do |_inputs|
      RateLimitCounters.runs += 1
      RubyReactor.Success(ok: true)
    end
  end
end

module SkippedStepCounters
  class << self
    attr_accessor :first_ran, :second_ran, :third_ran, :undo_count

    def reset
      @first_ran = 0
      @second_ran = 0
      @third_ran = 0
      @undo_count = 0
    end
  end
  reset
end

class StepSkipReactor < RubyReactor::Reactor
  input :should_skip

  step :first do
    run do |_inputs|
      SkippedStepCounters.first_ran += 1
      RubyReactor.Success(:first_done)
    end

    undo do |_error, _args, _ctx|
      SkippedStepCounters.undo_count += 1
      RubyReactor.Success(:undone)
    end
  end

  step :second do
    argument :should_skip, input(:should_skip)
    wait_for :first

    run do |args|
      SkippedStepCounters.second_ran += 1
      if args[:should_skip]
        RubyReactor.Skipped(reason: "no work to do")
      else
        RubyReactor.Success(:second_done)
      end
    end
  end

  step :third do
    wait_for :second

    run do |_inputs|
      SkippedStepCounters.third_ran += 1
      RubyReactor.Success(:third_done)
    end
  end
end

module OrderedLockCounters
  class << self
    attr_accessor :runs

    def reset
      @runs = []
    end
  end
  reset
end

class OrderedReactor < RubyReactor::Reactor
  async
  with_ordered_lock(poison_pill_timeout: 60) { |inputs| "orders:#{inputs[:account_id]}" }

  input :account_id
  input :thing

  step :process do
    argument :thing, input(:thing)
    run do |args|
      OrderedLockCounters.runs << args[:thing]
      RubyReactor.Success(thing: args[:thing])
    end
  end
end

# Non-async ordered-lock reactor. Runs inline via `Reactor.run` -> sync
# `Executor#execute`, exercising the path that must still advance the cursor
# (and pop the thread-local active key) in its `ensure`.
class SyncOrderedReactor < RubyReactor::Reactor
  with_ordered_lock(poison_pill_timeout: 60) { |inputs| "sync_orders:#{inputs[:account_id]}" }

  input :account_id
  input :thing

  step :process do
    argument :thing, input(:thing)
    run do |args|
      OrderedLockCounters.runs << args[:thing]
      RubyReactor.Success(thing: args[:thing])
    end
  end
end

class StrictOrderedReactor < RubyReactor::Reactor
  async
  with_ordered_lock(poison_pill_timeout: 60) { |inputs| "strict:#{inputs[:account_id]}" }

  input :account_id
  input :thing
  input :fail, optional: true

  step :process do
    argument :thing, input(:thing)
    argument :fail, input(:fail)
    run do |args|
      OrderedLockCounters.runs << args[:thing]
      if args[:fail]
        # Non-retryable so the Failure is terminal on the first attempt and the
        # ordered-lock cursor advances (with `failed: true`) right away.
        RubyReactor.Failure(StandardError.new("boom on #{args[:thing]}"), retryable: false)
      else
        RubyReactor.Success(thing: args[:thing])
      end
    end
  end
end

class NonStrictOrderedReactor < RubyReactor::Reactor
  async
  with_ordered_lock(poison_pill_timeout: 60, strict: false) { |inputs| "lenient:#{inputs[:account_id]}" }

  input :account_id
  input :thing
  input :fail, optional: true

  step :process do
    argument :thing, input(:thing)
    argument :fail, input(:fail)
    run do |args|
      OrderedLockCounters.runs << args[:thing]
      if args[:fail]
        RubyReactor.Failure(StandardError.new("boom on #{args[:thing]}"), retryable: false)
      else
        RubyReactor.Success(thing: args[:thing])
      end
    end
  end
end

class OrderedLockWithLockReactor < RubyReactor::Reactor
  async
  with_ordered_lock(poison_pill_timeout: 60) { |inputs| "combo:#{inputs[:account_id]}" }
  with_lock(ttl: 10) { |inputs| "combo:#{inputs[:account_id]}" }

  input :account_id
  input :thing

  step :process do
    argument :thing, input(:thing)
    run { |args| RubyReactor.Success(thing: args[:thing]) }
  end
end

class MultiWindowRateLimitedReactor < RubyReactor::Reactor
  with_rate_limit(
    limits: { second: 2, minute: 5 }
  ) { |inputs| "multi_api:#{inputs[:account_id]}" }

  step :call_api do
    run do |_inputs|
      RateLimitCounters.runs += 1
      RubyReactor.Success(ok: true)
    end
  end
end

# References a named limit registered in the global config. Two reactors point
# at the same `:stripe` name to exercise the shared global bucket.
class NamedRateLimitedReactor < RubyReactor::Reactor
  input :account_id, optional: true

  with_rate_limit(:stripe)

  step :call_api do
    run do |_inputs|
      RateLimitCounters.runs += 1
      RubyReactor.Success(ok: true)
    end
  end
end

class OtherNamedRateLimitedReactor < RubyReactor::Reactor
  input :account_id, optional: true

  with_rate_limit(:stripe)

  step :call_api do
    run do |_inputs|
      RateLimitCounters.runs += 1
      RubyReactor.Success(ok: true)
    end
  end
end
