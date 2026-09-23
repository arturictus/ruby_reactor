# frozen_string_literal: true

# Fixtures for spec/ruby_reactor/step_coordination/ordering_parity_spec.rb
# (US3, 005 quickstart R3, P1–P3): step-level strict ordering must follow the
# same gate rules as the reactor level. Every body records its `tag` in a
# Redis list, so a spec can tell whether it ran.
module OspSupport
  def self.redis
    @redis ||= Redis.new(url: RubyReactor.configuration.storage.redis_url)
  end

  def self.log_key(run_id)
    "osp:log:#{run_id}"
  end

  def self.record(run_id, tag)
    redis.rpush(log_key(run_id), tag)
  end

  def self.log(run_id)
    redis.lrange(log_key(run_id), 0, -1)
  end
end

class OspStrictStep < RubyReactor::Step
  input :run_id
  input :tag
  input :sleep_seconds, :float

  with_ordered_lock(strict: true, poison_pill_timeout: 30) { |a| "osp:#{a[:run_id]}" }

  def run
    OspSupport.record(inputs[:run_id], inputs[:tag])
    sleep inputs[:sleep_seconds] if inputs[:sleep_seconds].positive?
    Success(inputs[:tag])
  end
end

class OspSyncReactor < RubyReactor::Reactor
  input :run_id
  input :tag
  input :sleep_seconds

  step :ordered, OspStrictStep do
    argument :run_id, input(:run_id)
    argument :tag, input(:tag)
    argument :sleep_seconds, input(:sleep_seconds)
  end

  returns :ordered
end

# Fails retryably on its first attempt only, so a retry is pending with the
# position kept.
class OspRetryStep < RubyReactor::Step
  input :run_id

  with_ordered_lock(strict: true, poison_pill_timeout: 30) { |a| "osp:retry:#{a[:run_id]}" }

  def run
    count = OspSupport.redis.incr("osp:count:#{inputs[:run_id]}")
    count == 1 ? Failure("transient") : Success(count)
  end
end

class OspRetryReactor < RubyReactor::Reactor
  input :run_id

  step :ordered, OspRetryStep do
    argument :run_id, input(:run_id)
    retries max_attempts: 2, backoff: :fixed, base_delay: 0
  end

  returns :ordered
end

# An abnormal (non-StandardError) exit from inside the ordered position.
class OspAbortStep < RubyReactor::Step
  input :run_id
  input :abort, optional: true

  with_ordered_lock(strict: true, poison_pill_timeout: 30) { |a| "osp:abort:#{a[:run_id]}" }

  def run
    raise NoMemoryError, "simulated abnormal exit" if inputs[:abort]

    Success(:done)
  end
end

class OspAbortReactor < RubyReactor::Reactor
  input :run_id
  input :abort, optional: true

  step :ordered, OspAbortStep do
    argument :run_id, input(:run_id)
    argument :abort, input(:abort)
  end

  returns :ordered
end

# The reactor-level counterpart, for the parity table.
class OspReactorLevel < RubyReactor::Reactor
  background all: true

  with_ordered_lock(strict: true, poison_pill_timeout: 30) { |i| "osp:r:#{i[:run_id]}" }

  input :run_id
  input :tag

  step :work do
    argument :run_id, input(:run_id)
    argument :tag, input(:tag)
    run do |args|
      OspSupport.record(args[:run_id], args[:tag])
      RubyReactor.Success(args[:tag])
    end
  end

  returns :work
end
