# frozen_string_literal: true

class SimpleLockReactor < RubyReactor::Reactor
  with_lock(ttl: 10) { |inputs| "user_#{inputs[:user_id]}" }

  step :process do
    run do |inputs|
      # Simulating work
      RubyReactor.Success(processed: true)
    end
  end
end

class NestedChildReactor < RubyReactor::Reactor
  with_lock(ttl: 10) { |inputs| "shared_resource" }

  step :child do
    run do |inputs|
      RubyReactor.Success(child_done: true)
    end
  end
end

class NestedLockReactor < RubyReactor::Reactor
  with_lock(ttl: 10) { |inputs| "shared_resource" }

  compose :parent, NestedChildReactor do
    # Compose automatically links contexts and uses same root_context
  end
end

class SemaphoreReactor < RubyReactor::Reactor
  with_semaphore(limit: 2, wait: 0) { |inputs| "api_limit" }

  step :call_api do
    run do |inputs|
      # Simulating API call
      RubyReactor.Success(api_called: true)
    end
  end
end

class InheritedLockReactor < SimpleLockReactor
end

class InheritedSemaphoreReactor < SemaphoreReactor
end
