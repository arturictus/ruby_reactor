# frozen_string_literal: true

# Evidence harness for specs/007-execution-flow-analysis. Research artifact,
# NOT library or test-suite code. It runs throwaway reactors against the real
# test Redis through the real worker bodies (Sidekiq fake mode + drain) and
# prints the observed forward/rollback event order next to the order the
# report claims.

require "bundler/setup"
require "logger"
require "ruby_reactor"
require "sidekiq/testing"

Sidekiq::Testing.fake!
Sidekiq.configure_client do |config|
  config.redis = { url: ENV.fetch("RUBY_REACTOR_TEST_REDIS_URL", "redis://localhost:6780") }
  config.logger = Logger.new(IO::NULL)
end

module Probe
  REDIS_URL = ENV.fetch("RUBY_REACTOR_TEST_REDIS_URL", "redis://localhost:6780")

  # Drained in this order until quiet. Delayed jobs (perform_in) run at once.
  WORKERS = [
    RubyReactor::Adapters::Sidekiq::Worker,
    RubyReactor::Adapters::Sidekiq::MapElementWorker,
    RubyReactor::Adapters::Sidekiq::MapCollectorWorker,
    # 009 R-04: a fan-out map rolls back one element per job.
    RubyReactor::Adapters::Sidekiq::MapElementRollbackWorker,
    RubyReactor::Adapters::Sidekiq::StepWorker
  ].freeze

  @events = []
  @notes = []
  @counters = Hash.new(0)
  @tally = { match: 0, mismatch: 0 }

  class << self
    attr_reader :events, :notes, :counters, :tally

    def rec(event) = @events << event
    def note(text) = @notes << text

    # Uniform step labels: "run:a", "undo:child.c1", "run:e1[2]".
    def label(prefix, name, index = nil)
      base = [prefix, name].compact.join(".")
      index.nil? ? base : "#{base}[#{index}]"
    end

    # The value a probe `compensate` / `undo` body returns.
    def rollback_result(mode, what)
      case mode
      when :fail then RubyReactor.Failure("#{what} failed")
      when :raise then raise "#{what} raised"
      else RubyReactor.Success()
      end
    end

    # Same loop as RubyReactor::RSpec::SidekiqHelpers.drain_async_jobs, inlined
    # because requiring that file pulls in the RSpec matchers.
    def drain(max_iterations: 100)
      max_iterations.times do
        busy = false
        WORKERS.each do |worker|
          while (job = worker.jobs.shift)
            worker.new.perform(*job["args"])
            busy = true
          end
        end
        return unless busy
      end
    end

    def pending_jobs = WORKERS.sum { |w| w.jobs.size }

    # Jobs run synchronously at enqueue (Sidekiq::Testing.inline!). Used only
    # where a same-process reader must see a unit finish; labelled in the mode.
    def inline_jobs(&block) = Sidekiq::Testing.inline!(&block)

    # Run, drain every worker job, then reload the execution's terminal state.
    def run_async(reactor_class, inputs = {})
      dispatched = reactor_class.run(inputs)
      drain
      reactor_class.find(dispatched.execution_id)
    end

    # Prints Failure#rollback_failures as step/kind/reason; returns the result.
    def rollback_note(result)
      list = result.respond_to?(:rollback_failures) ? Array(result.rollback_failures) : []
      note("rollback_failures=#{list.map { |f| "#{f[:step]}/#{f[:kind]}/#{f[:reason]}" }}")
      result
    end

    def outcome(result)
      result = result.result if result.is_a?(RubyReactor::Reactor)
      case result
      when String then result
      when RubyReactor::Halt then "halt"
      when RubyReactor::Success then "success"
      when RubyReactor::Failure then "failure(#{result.step_name || "?"})"
      when RubyReactor::InterruptResult then "paused"
      when RubyReactor::DispatchResult then "dispatched"
      when :unexecuted then "running"
      else result.inspect
      end
    end

    def reset!
      RubyReactor.configuration.storage_adapter.instance_variable_get(:@redis).flushdb
      WORKERS.each { |w| w.jobs.clear }
      [@events, @notes].each(&:clear)
      @counters.clear
    end

    # Runs one scenario and prints expected vs observed. The block returns the
    # final result (a Result, a reloaded Reactor, or a String).
    def scenario(id, title, mode:, expected:, &block)
      return if ENV["PROBE"] && !id.include?(ENV["PROBE"])

      reset!
      observed = @events + ["=>", outcome(run_block(&block))]
      report(id, title, mode, expected, observed)
    end

    private

    def run_block(&block)
      block.call
    rescue StandardError => e
      "raised(#{e.class}: #{e.message.lines.first&.strip})"
    end

    def report(id, title, mode, expected, observed)
      ok = observed == expected
      @tally[ok ? :match : :mismatch] += 1
      puts "== #{id}  #{title}   [#{mode}]"
      puts "expected: #{expected.join(" ")}"
      puts "observed: #{observed.join(" ")}"
      @notes.each { |n| puts "note: #{n}" }
      puts ok ? "MATCH" : "MISMATCH"
      puts
    end
  end

  # Recording middleware: the shipped hook surface, no patching. Only events
  # that say something about ordering relative to rollback are kept.
  class Recorder < RubyReactor::Middleware
    def on(event, *args)
      case event
      when :lock_acquired, :lock_released, :semaphore_acquired, :semaphore_released
        Probe.rec("#{event}:#{args[0]}")
      when :retry_attempt
        Probe.rec("retry:#{args[0]}##{args[1]}")
      end
    end
  end

  # Reactor-class DSL sugar so a probe step is one line:
  #
  #   pstep :b, after: :a, fail: true
  #   pstep :e1, idx: true, fail: ->(inputs) { inputs.i == 2 }
  #   pstep :c, fail: :raise, compensate: :fail, undo: :raise
  #   pstep :d, fail_times: 1, retries: { max_attempts: 2, base_delay: 0 }
  module Steps
    def tag(value = nil)
      value ? @probe_tag = value : @probe_tag
    end

    # opts: fail:, fail_times:, retries: {…}, compensate: :ok|:fail|:raise, undo: (same),
    #       kind: :step (default) | :async_step
    def pstep(name, after: nil, idx: false, **opts, &extra)
      body = Steps.body(tag, name, idx, opts)
      on_compensate = Steps.rollback(tag, name, idx, "compensate", opts[:compensate])
      on_undo = Steps.rollback(tag, name, idx, "undo", opts[:undo])
      public_send(opts.fetch(:kind, :step), name) do
        wait_for(*Array(after)) if after
        argument :i, input(:i) if idx
        retries(**opts[:retries]) if opts[:retries]
        run(&body)
        compensate(&on_compensate)
        # 008 R-09: an async_step is never undone, so `undo` on one is rejected.
        undo(&on_undo) unless opts[:kind] == :async_step
        instance_eval(&extra) if extra
      end
    end

    # `failure`: `fail: true | :raise | ->(inputs) {}` or `fail_times: n`.
    def self.body(prefix, name, idx, failure)
      lambda do |inputs, _ctx|
        lbl = Probe.label(prefix, name, idx ? inputs.i : nil)
        Probe.rec("run:#{lbl}")
        failing = failing?(lbl, inputs, failure)
        raise "boom #{lbl}" if failing && failure[:fail] == :raise

        failing ? RubyReactor.Failure("boom #{lbl}") : RubyReactor.Success("#{lbl}-value")
      end
    end

    def self.failing?(lbl, inputs, failure)
      return (Probe.counters[lbl] += 1) <= failure[:fail_times] if failure[:fail_times]

      fail = failure[:fail]
      fail.respond_to?(:call) ? fail.call(inputs) : fail
    end

    def self.rollback(prefix, name, idx, kind, mode)
      lambda do |_error_or_result, inputs, _ctx|
        lbl = Probe.label(prefix, name, idx ? inputs.i : nil)
        Probe.rec("#{kind}:#{lbl}")
        Probe.rollback_result(mode, "#{kind} #{lbl}")
      end
    end
  end
end

RubyReactor.configure do |config|
  config.storage.adapter = :redis
  config.storage.redis_url = Probe::REDIS_URL
  config.async_router = RubyReactor::Adapters::Sidekiq::Router
  config.logger = Logger.new(IO::NULL)
  config.middlewares = [Probe::Recorder]
  config.lock_snooze_jitter = 0
  config.async_wait_timeout = 2
end

# Probe reactors live under P so workers can resolve them by constant name.
module P
  class Base < RubyReactor::Reactor
    extend Probe::Steps
  end
end
