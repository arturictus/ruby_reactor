# frozen_string_literal: true

# Fixtures for the "async_step park state (US4)" examples in
# spec/ruby_reactor/step_coordination/park_spec.rb (005 quickstart P4): a parked
# `async_step` keeps its park state on its own Step Result Record, and its
# worker never writes the parent's root blob on a park.
module AspSupport
  def self.redis
    @redis ||= Redis.new(url: RubyReactor.configuration.storage.redis_url)
  end

  def self.log_key(run_id)
    "asp:log:#{run_id}"
  end
end

class AspOrderedStep < RubyReactor::Step
  input :run_id

  with_ordered_lock { |a| "asp:seq:#{a[:run_id]}" }
  with_lock { |a| "asp:lock:#{a[:run_id]}" }

  def run
    AspSupport.redis.rpush(AspSupport.log_key(inputs[:run_id]), "ordered")
    Success(:ordered)
  end
end

class AspReactor < RubyReactor::Reactor
  background all: true

  input :run_id

  async_step :ordered, AspOrderedStep do
    argument :run_id, input(:run_id)
  end

  step :progress do
    argument :run_id, input(:run_id)
    run do |args|
      AspSupport.redis.rpush(AspSupport.log_key(args[:run_id]), "progress")
      RubyReactor.Success(:progressed)
    end
  end

  returns :progress
end
