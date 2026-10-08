# frozen_string_literal: true

require_relative "rollback_recorder"
require_relative "map_rollback_fixtures"

# Shared reactors and thread helpers for the 010 resume and liveness specs
# (specs/010-rollback-follow-ups). Every reactor records through
# RollbackRecorder, so an example asserts a whole sequence at once.
module ResumeFixtures
  # Blocks a step body until the spec opens it. `wait` raises after `timeout`
  # so a broken example fails instead of hanging the suite.
  class Latch
    def initialize
      @mutex = Mutex.new
      @cond = ConditionVariable.new
      @open = false
      @waiting = 0
    end

    def wait(timeout = 5)
      @mutex.synchronize do
        @waiting += 1
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
        until @open
          left = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          raise "ResumeFixtures latch not opened within #{timeout}s" unless left.positive?

          @cond.wait(@mutex, left)
        end
      end
    end

    def open!
      @mutex.synchronize do
        @open = true
        @cond.broadcast
      end
    end

    def waiting?
      @mutex.synchronize { @waiting.positive? }
    end
  end

  # Releases `n` threads together.
  class Barrier
    def initialize(count)
      @count = count
      @arrived = 0
      @mutex = Mutex.new
      @cond = ConditionVariable.new
    end

    def wait(timeout = 5)
      @mutex.synchronize do
        @arrived += 1
        if @arrived >= @count
          @cond.broadcast
        else
          @cond.wait(@mutex, timeout) while @arrived < @count
        end
      end
    end
  end

  class << self
    def latches
      @latches ||= {}
    end

    # A latch is created on first use; a step only waits on one a spec created.
    def latch(name)
      latches[name] ||= Latch.new
    end

    def barrier(count)
      Barrier.new(count)
    end

    def counters
      @counters ||= Hash.new(0)
    end

    def counter(name)
      counters[name]
    end

    def bump(name)
      counters[name] += 1
    end

    def reset!
      latches.each_value(&:open!)
      latches.clear
      counters.clear
      RollbackRecorder.reset!
    end

    # `n` ready interrupts `:i0..` after `:prep`, and a final step on all of them.
    def many_approvals(count)
      const = :"ManyApprovals#{count}"
      return const_get(const) if const_defined?(const, false)

      names = (0...count).map { |k| :"i#{k}" }
      klass = Class.new(RollbackRecorder::Reactor) do
        recording_step :prep
        names.each { |n| interrupt(n) { wait_for :prep } }
        step :done do
          names.each { |n| argument n, result(n) }
          run do |inputs, _ctx|
            RollbackRecorder.record("run:done")
            RubyReactor.Success(names.map { |n| inputs.public_send(n) })
          end
        end
      end
      const_set(const, klass)
    end
  end

  class PlainApproval < RollbackRecorder::Reactor
    recording_step :a
    interrupt(:approval) do
      wait_for :a
      validate_payload { required(:ok).filled(:bool) }
      max_attempts 3
    end
    recording_step :c, after: :approval
  end

  class LockedApproval < RollbackRecorder::Reactor
    with_lock { |_inputs| "resume-fx:locked" }
    recording_step :a
    interrupt(:approval) do
      wait_for :a
      validate_payload { required(:ok).filled(:bool) }
      max_attempts 3
    end
    recording_step :c, after: :approval
  end

  class SemaphoredApproval < RollbackRecorder::Reactor
    with_semaphore(limit: 1) { |_inputs| "resume-fx:sem" }
    recording_step :a
    interrupt(:approval) do
      wait_for :a
      validate_payload { required(:ok).filled(:bool) }
      max_attempts 3
    end
    recording_step :c, after: :approval
  end

  class BackgroundApproval < RollbackRecorder::Reactor
    recording_step :a
    interrupt :approval, resume: :background do
      wait_for :a
      validate_payload { required(:ok).filled(:bool) }
      max_attempts 3
    end
    recording_step :c, after: :approval
  end

  # Two ready interrupts. `after_a` waits on `latch(:after_a)` when a spec
  # created one, and fails when `fail_after_a` is set. It is declared before
  # `b`, so a resume of `a` runs it before the run reaches (and pauses at) `b`.
  class DualApproval < RollbackRecorder::Reactor
    input :fail_after_a, optional: true

    recording_step :prep
    interrupt(:a) { wait_for :prep }
    step :after_a do
      argument :value, result(:a)
      argument :fail_after_a, input(:fail_after_a)
      run do |inputs, _ctx|
        RollbackRecorder.record("run:after_a")
        ResumeFixtures.latches[:after_a]&.wait
        next RubyReactor.Failure("after_a failed") if inputs.fail_after_a

        RubyReactor.Success(inputs.value)
      end
      undo do |_value, _inputs, _ctx|
        RollbackRecorder.record("undo:after_a")
        RubyReactor.Success()
      end
    end
    interrupt(:b) do
      wait_for :prep
      validate_payload { required(:ok).filled(:bool) }
      max_attempts 3
    end
    step :done do
      argument :x, result(:after_a)
      argument :y, result(:b)
      run do |inputs, _ctx|
        RollbackRecorder.record("run:done")
        RubyReactor.Success([inputs.x, inputs.y])
      end
    end
  end

  # A background reactor whose `b` is ready from the start: a resume for it can
  # arrive before the worker has even begun the first run.
  class DualApprovalAsync < RollbackRecorder::Reactor
    background all: true

    recording_step :prep
    interrupt(:a) { wait_for :prep }
    interrupt(:b)
    recording_step :done, after: %i[a b]
  end

  # One step that waits on `latch(:slow)` and counts its runs.
  class SlowSync < RollbackRecorder::Reactor
    step :slow do
      run do |_inputs, _ctx|
        ResumeFixtures.bump(:slow)
        ResumeFixtures.latches[:slow]&.wait(30)
        RubyReactor.Success(:slow_done)
      end
    end
  end

  # `a` → fan-out map `m` (batch 2) → `b` → `c`, run synchronously.
  class SyncFanOut < RollbackRecorder::Reactor
    input :items
    recording_step :a
    map :m, MapRollbackFixtures::ElemOk do
      source input(:items)
      argument :i, element(:m)
      fan_out(batch_size: 2)
    end
    recording_step :b, after: :m
    recording_step :c, after: :b
  end
end

RSpec.configure do |config|
  owned = %r{spec/ruby_reactor/(interrupts/|caller_process|worker_|executor/caller_save|interrupt_claims)}
  config.before(file_path: owned) do
    ResumeFixtures.reset!
  end
  config.after { ResumeFixtures.latches.each_value(&:open!) }
end
