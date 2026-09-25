# frozen_string_literal: true

# Concurrency-observation helper shared by every step-scoped-coordination spec
# (spec/ruby_reactor/step_coordination/). Two or more executions — spec
# threads, or a live Sidekiq worker process — call `enter`/`leave` around the
# section being observed; `max_concurrency`/`overlapped?` replay the trace to
# answer "did these overlap" from the recorded timestamps rather than by
# polling in-process state, which is what makes it safe to use across threads
# AND across the live-Sidekiq process boundary.
#
# `enter` and `leave` push the identical wire format (`OverlapRecorder`
# carries no in-memory open/close state of its own — that would not survive a
# process boundary). Pairing is reconstructed on read: group entries by
# (tag, pid, thread id), sort by timestamp, and take them in enter/leave
# pairs — safe because a single (tag, pid, thread) triple never has two
# overlapping intervals open at once (that would be the same body re-entering
# itself on the same thread, which none of these fixtures do).
class OverlapRecorder
  def self.list_key(run_id)
    "step_coord:trace:#{run_id}"
  end

  attr_reader :run_id

  def initialize(run_id)
    @run_id = run_id
  end

  def enter(tag)
    record(tag)
  end

  def leave(tag)
    record(tag)
  end

  # Highest number of simultaneously-open enter/leave intervals recorded for
  # `tag`.
  def max_concurrency(tag)
    points = intervals(tag).flat_map { |s, e| [[s, 1], [e, -1]] }.sort_by(&:first)

    current = 0
    max = 0
    points.each do |(_time, delta)|
      current += delta
      max = current if current > max
    end
    max
  end

  # True when any recorded interval for tag_a overlaps any recorded interval
  # for tag_b in wall-clock time. When tag_a == tag_b (the common case of one
  # tag shared by many concurrent executions of the same step body), a plain
  # start/negative comparison. When they are the same tag, an interval must
  # never be compared against itself — every interval trivially "overlaps"
  # itself — so only distinct pairs are compared.
  def overlapped?(tag_a, tag_b)
    a = intervals(tag_a)
    if tag_a.to_s == tag_b.to_s
      a.combination(2).any? { |(s1, e1), (s2, e2)| s1 < e2 && s2 < e1 }
    else
      b = intervals(tag_b)
      a.any? { |a_start, a_end| b.any? { |b_start, b_end| a_start < b_end && b_start < a_end } }
    end
  end

  def entries(tag = nil)
    raw = redis.lrange(self.class.list_key(run_id), 0, -1).map { |v| decode(v) }
    tag ? raw.select { |e| e[:tag] == tag.to_s } : raw
  end

  def clear!
    redis.del(self.class.list_key(run_id))
  end

  private

  def record(tag)
    redis.rpush(
      self.class.list_key(run_id),
      "#{tag}:#{Process.pid}:#{Thread.current.object_id}:#{Process.clock_gettime(Process::CLOCK_REALTIME)}"
    )
  end

  # Reconstruct [start, end] pairs for `tag`: group by (pid, thread), sort by
  # timestamp within the group (== list order for a single body's own
  # enter/leave calls), then pair consecutively.
  def intervals(tag)
    entries(tag).group_by { |e| [e[:pid], e[:thread_id]] }.flat_map do |_key, group|
      group.sort_by { |e| e[:timestamp] }.each_slice(2).filter_map do |pair|
        [pair[0][:timestamp], pair[1][:timestamp]] if pair.size == 2
      end
    end
  end

  def decode(value)
    parts = value.split(":")
    timestamp = parts.pop.to_f
    thread_id = parts.pop.to_i
    pid = parts.pop.to_i
    { tag: parts.join(":"), pid: pid, thread_id: thread_id, timestamp: timestamp }
  end

  # Reads the URL from `RubyReactor.configuration` rather than the spec-only
  # `REDIS_TEST_URL` constant: this class is loaded by the live Sidekiq
  # worker process too (spec/support/sidekiq_boot.rb), which never loads
  # spec_helper and so never defines `REDIS_TEST_URL`. Both processes
  # configure `storage.redis_url` identically, so this resolves to the same
  # Redis either way.
  def redis
    @redis ||= Redis.new(url: RubyReactor.configuration.storage.redis_url)
  end
end

# Included into every example group under spec/ruby_reactor/step_coordination/
# (tagged below). Gives each example its own run id so fixture step bodies —
# which may execute in a different process, the live Sidekiq worker — can
# build their own OverlapRecorder pointed at the same Redis list by
# reconstructing it from the `run_id` carried through reactor inputs/step
# arguments.
module StepCoordinationHelpers
  def step_coord_run_id
    @step_coord_run_id ||= SecureRandom.uuid
  end

  def overlap_recorder(run_id = step_coord_run_id)
    OverlapRecorder.new(run_id)
  end

  def unique_account_id
    SecureRandom.random_number(10**9)
  end

  # `context` is mutable and its `current_step` reverts once `with_step`'s
  # `ensure` runs, so it is snapshotted WHEN the event fires. Each captured
  # row is `[event, first_arg, current_step]`.
  def capture_step_events
    events = []
    mw = Class.new do
      define_method(:on) do |event, *args|
        context = args.last
        current_step = context.respond_to?(:current_step) ? context.current_step : nil
        events << [event, args[0], current_step]
      end
    end.new
    [mw, events]
  end

  # Performs the last enqueued `async_step` job exactly once.
  def perform_last_step_job
    job = RubyReactor::Adapters::Sidekiq::StepWorker.jobs.last
    RubyReactor::Adapters::Sidekiq::StepWorker.jobs.clear
    RubyReactor::Adapters::Sidekiq::StepWorker.new.perform(*job["args"])
  end
end

# Fixture reactors (spec/support/reactors/step_coordination_reactors.rb) are
# loaded by BOTH the spec process and the standalone live-Sidekiq worker
# process (spec/support/sidekiq_boot.rb, which deliberately never loads
# RSpec). Guard the RSpec.configure call so requiring this file from the
# worker process is a no-op instead of a boot-time NameError.
if defined?(RSpec)
  RSpec.configure do |config|
    config.include StepCoordinationHelpers, :step_coordination
    config.define_derived_metadata(file_path: %r{/step_coordination/}) { |m| m[:step_coordination] = true }
  end
end
