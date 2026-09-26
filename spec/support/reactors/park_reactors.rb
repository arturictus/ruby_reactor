# frozen_string_literal: true

# Fixtures for spec/ruby_reactor/step_coordination/park_spec.rb (US2, 005
# quickstart R2, R4, R6): a park at any nesting depth keeps every level's own
# lock and semaphore, charges reactor-level quotas once, and a background-result
# wait inside a composed child parks instead of failing the parent.

# The step that contends: hold "park:acct:<id>" externally and it parks.
class ParkChildStep < RubyReactor::Step
  input :account_id

  with_lock { |a| "park:acct:#{a[:account_id]}" }

  def run
    Success(inputs.account_id)
  end
end

class ParkChildReactor < RubyReactor::Reactor
  input :account_id

  step :charge, ParkChildStep do
    argument :account_id, input(:account_id)
  end

  returns :charge
end

# The composed child is the parent's FIRST step, so a park there happens
# before the parent has any step result — the shape that used to make a
# redelivery look like a fresh execution.
class ParkRateParentReactor < RubyReactor::Reactor
  background all: true

  with_rate_limit(limits: { hour: 100 }) { |i| "park:rl:#{i[:run_id]}" }

  input :run_id
  input :account_id

  compose :child, ParkChildReactor do
    argument :account_id, input(:account_id)
  end

  returns :child
end

class ParkLockParentReactor < RubyReactor::Reactor
  background all: true

  with_lock { |i| "park:parent:#{i[:run_id]}" }

  input :run_id
  input :account_id

  compose :child, ParkChildReactor do
    argument :account_id, input(:account_id)
  end

  returns :child
end

# A lock that lapses during the park gap: the redelivery re-acquires it fresh.
class ParkShortTtlParentReactor < RubyReactor::Reactor
  background all: true

  with_lock(ttl: 1) { |i| "park:short:#{i[:run_id]}" }
  with_rate_limit(limits: { hour: 100 }) { |i| "park:short_rl:#{i[:run_id]}" }

  input :run_id
  input :account_id

  compose :child, ParkChildReactor do
    argument :account_id, input(:account_id)
  end

  returns :child
end

# Depth 2: grand-parent -> middle (its own lock and rate limit) -> child.
class ParkMiddleReactor < RubyReactor::Reactor
  with_lock { |i| "park:middle:#{i[:run_id]}" }
  with_rate_limit(limits: { hour: 100 }) { |i| "park:middle_rl:#{i[:run_id]}" }

  input :run_id
  input :account_id

  compose :child, ParkChildReactor do
    argument :account_id, input(:account_id)
  end

  returns :child
end

class ParkGrandParentReactor < RubyReactor::Reactor
  background all: true

  input :run_id
  input :account_id

  compose :middle, ParkMiddleReactor do
    argument :run_id, input(:run_id)
    argument :account_id, input(:account_id)
  end

  returns :middle
end

# F10: a composed child waits on an `async_step`'s result inside a worker.
class ParkFetchStep < RubyReactor::Step
  input :run_id

  def run
    Success("fetched:#{inputs.run_id}")
  end
end

class ParkAsyncReaderChild < RubyReactor::Reactor
  with_lock { |i| "park:reader:#{i[:run_id]}" }

  input :run_id

  async_step :fetch, ParkFetchStep do
    argument :run_id, input(:run_id)
  end

  step :read do
    argument :fetched, result(:fetch)
    run { |args| RubyReactor.Success(args.fetched) }
  end

  returns :read
end

class ParkAsyncReaderParent < RubyReactor::Reactor
  background all: true

  input :run_id

  compose :child, ParkAsyncReaderChild do
    argument :run_id, input(:run_id)
  end

  returns :child
end

# A map element whose first step contends.
class ParkMapReactor < RubyReactor::Reactor
  input :account_ids

  map :charges, ParkChildReactor do
    source input(:account_ids)
    argument :account_id, element(:charges)
    fan_out batch_size: 1
  end
end

# A reactor-level lock contended BEFORE admission snoozes the job (the
# execution has not started, so it is not a park): the rate limit charged just
# before the lock must not be charged again by the redelivery.
class ParkSnoozedRootReactor < RubyReactor::Reactor
  background all: true

  with_rate_limit(limits: { hour: 100 }) { |i| "park:root_rl:#{i[:run_id]}" }
  with_lock { |i| "park:root:#{i[:run_id]}" }

  input :run_id

  step :work do
    run { RubyReactor.Success(:done) }
  end
end

module ParkSupport
  def self.redis
    @redis ||= Redis.new(url: RubyReactor.configuration.storage.redis_url)
  end

  def self.undo_log_key(run_id)
    "park:undo:#{run_id}"
  end
end

# A composed child that declares its OWN reactor-level lock and rate limit.
# Holding the child's key in a worker parks the parent's job instead of
# failing the parent.
class ParkLockedChildReactor < RubyReactor::Reactor
  with_rate_limit(limits: { hour: 100 }) { |i| "park:locked_child_rl:#{i[:run_id]}" }
  with_lock { |i| "park:locked_child:#{i[:run_id]}" }

  input :run_id

  step :work do
    argument :run_id, input(:run_id)
    run { |args| RubyReactor.Success("child:#{args.run_id}") }
  end

  returns :work
end

class ParkLockedChildParentReactor < RubyReactor::Reactor
  background all: true

  with_lock { |i| "park:locked_parent:#{i[:run_id]}" }

  input :run_id

  # Completes before the child contends, so a terminal failure has something
  # to roll back. Its undo records itself in a Redis list.
  step :reserve do
    argument :run_id, input(:run_id)
    run { |args| RubyReactor.Success(args.run_id) }
    undo do |run_id, _args, _context|
      ParkSupport.redis.rpush(ParkSupport.undo_log_key(run_id), "reserve")
      RubyReactor.Success()
    end
  end

  compose :child, ParkLockedChildReactor do
    argument :run_id, result(:reserve)
  end

  returns :child
end

# A fan-out map, then a locked step: the map collector resumes the parent in
# its own worker, so a park AFTER the map surfaces there, not in `Worker`.
class ParkMapElementReactor < RubyReactor::Reactor
  input :n

  step :double do
    argument :n, input(:n)
    run { |args| RubyReactor.Success(args.n * 2) }
  end

  returns :double
end

class ParkAfterMapReactor < RubyReactor::Reactor
  input :account_id
  input :numbers

  map :doubled, ParkMapElementReactor do
    source input(:numbers)
    argument :n, element(:doubled)
    fan_out batch_size: 1
  end

  step :charge, ParkChildStep do
    argument :account_id, input(:account_id)
    wait_for :doubled
  end

  returns :charge
end
