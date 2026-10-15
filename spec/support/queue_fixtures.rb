# frozen_string_literal: true

require_relative "rollback_recorder"

# 011: reactors and steps declaring queues. Built on RollbackRecorder, so a
# spec can assert the whole forward/rollback sequence (`run:m.first`,
# `undo:s.one`, ...) next to where each entry ran.
#
#   QueueFixtures::Main.run({})           # main → stripe → main
#   QueueFixtures.queues_of_pending       # => ["main"]
module QueueFixtures
  module_function

  def queues_of_pending
    RubyReactor::RSpec::AsyncTestHelpers.pending_async_jobs.map(&:queue)
  end

  def jobs_on(queue)
    RubyReactor::RSpec::AsyncTestHelpers.pending_async_jobs.select { |job| job.queue == queue.to_s }
  end

  def run_log
    RollbackRecorder.log
  end

  def count(event)
    RollbackRecorder.log.count(event)
  end

  class EmailStep < RubyReactor::Step
    queue :emails

    def run
      RollbackRecorder.record("run:email")
      Success("sent")
    end
  end

  class AnotherStep < RubyReactor::Step
    queue :another_one

    class << self
      attr_writer :fail_times

      def fail_times = @fail_times.to_i
    end

    def run
      RollbackRecorder.record("run:another")
      if AnotherStep.fail_times.positive?
        AnotherStep.fail_times -= 1
        return Failure("another failed")
      end

      Success("another-value")
    end

    def undo
      RollbackRecorder.record("undo:another")
      Success()
    end
  end

  class LedgerStep < RubyReactor::Step
    queue :ledger

    def run
      RollbackRecorder.record("run:ledger")
      Success("ledger-value")
    end

    def undo
      RollbackRecorder.record("undo:ledger")
      Success()
    end
  end

  class Stripe < RollbackRecorder::Reactor
    tag "s"
    queue :stripe
    input :prev, optional: true
    recording_step :one
    recording_step :two, after: :one
  end

  class StripeWithLedger < RollbackRecorder::Reactor
    tag "s"
    queue :stripe
    input :prev, optional: true
    recording_step :one
    step(:two, LedgerStep) { wait_for :one }
    recording_step :three, after: :two
  end

  class Undeclared < RollbackRecorder::Reactor
    tag "u"
    input :prev, optional: true
    recording_step :u1
    recording_step :u2, after: :u1
  end

  class StripeApproval < RollbackRecorder::Reactor
    tag "s"
    queue :stripe
    input :prev, optional: true
    recording_step :one
    interrupt(:approve, resume: :background) { wait_for :one }
    recording_step :two, after: :approve
  end

  class RetryingStripe < RollbackRecorder::Reactor
    tag "s"
    queue :stripe
    input :prev, optional: true
    recording_step :one, fail: 1 do
      retries max_attempts: 2, backoff: :fixed, base_delay: 0
    end
  end

  # `queue :main`, `background after: :first`: first → second → compose
  # :bank_deposit (the child) → third. Linear, so the hop count is fixed.
  def self.build_main(name, child, third_fails: false, &extra)
    klass = Class.new(RollbackRecorder::Reactor) do
      tag "m"
      queue :main
      instance_eval(&extra) if extra
      recording_step :first
      recording_step :second, after: :first
      compose :bank_deposit, child do
        argument :prev, result(:second)
      end
      recording_step :third, after: :bank_deposit, fail: third_fails
      background after: :first
    end
    const_set(name, klass)
  end

  build_main(:Main, Stripe)
  build_main(:MainFailing, Stripe, third_fails: true)
  build_main(:MainNested, StripeWithLedger)
  build_main(:MainNestedFailing, StripeWithLedger, third_fails: true)
  build_main(:MainUndeclaredChild, Undeclared)
  build_main(:MainLocked, Stripe) { with_lock { |_inputs| "qfx:lock" } }
  build_main(:MainSemaphore, Stripe) { with_semaphore(limit: 1) { |_inputs| "qfx:sem" } }

  # `:pre` keeps the hand-off on :main, so `:another` hops out and back.
  def self.build_main_steps(name, after_fails: false)
    klass = Class.new(RollbackRecorder::Reactor) do
      tag "m"
      queue :main
      recording_step :first
      recording_step :pre, after: :first
      step(:another, AnotherStep) { wait_for :pre }
      recording_step :after_another, after: :another, fail: after_fails
      async_step(:email, EmailStep) { wait_for :first }
      async_step(:priority_email, EmailStep) do
        queue :priority_emails
        wait_for :first
      end
      async_step :plain_async do
        wait_for :first
        run do |_inputs, _ctx|
          RollbackRecorder.record("run:plain_async")
          RubyReactor.Success()
        end
      end
      background after: :first
    end
    const_set(name, klass)
  end

  build_main_steps(:MainSteps)
  build_main_steps(:MainStepsFailing, after_fails: true)

  class MainApproval < RollbackRecorder::Reactor
    tag "m"
    queue :main
    recording_step :first
    compose :deposit, StripeApproval do
      argument :prev, result(:first)
    end
    recording_step :last, after: :deposit
    background after: :first
  end

  class MainRetry < RollbackRecorder::Reactor
    tag "m"
    queue :main
    recording_step :first
    compose :deposit, RetryingStripe do
      argument :prev, result(:first)
    end
    background after: :first
  end

  class Deposit < RollbackRecorder::Reactor
    tag "d"
    queue :deposits
    input :i
    recording_step :d, idx: true
  end

  class UndeclaredDeposit < RollbackRecorder::Reactor
    tag "d"
    input :i
    recording_step :d, idx: true
  end

  def self.build_map_owner(name, element_class, fan: true, after_fails: false)
    klass = Class.new(RollbackRecorder::Reactor) do
      tag "o"
      queue :main
      input :items
      map :deposits, element_class do
        source input(:items)
        argument :i, element(:deposits)
        fan_out batch_size: 2 if fan
      end
      recording_step :after_map, after: :deposits, fail: after_fails
      background all: true
    end
    const_set(name, klass)
  end

  build_map_owner(:FanOutOwner, Deposit)
  build_map_owner(:FanOutOwnerFailing, Deposit, after_fails: true)
  build_map_owner(:FanOutUndeclaredOwner, UndeclaredDeposit)
  build_map_owner(:InlineMapOwner, Deposit, fan: false)

  class SoloMain < RollbackRecorder::Reactor
    tag "solo"
    queue :my_specific_queue
    recording_step :first
    recording_step :second, after: :first
    recording_step :third, after: :second
    background after: :first
  end

  class SoloUndeclared < RollbackRecorder::Reactor
    tag "solo"
    recording_step :first
    recording_step :second, after: :first
    recording_step :third, after: :second
    background after: :first
  end

  class SoloRetry < RollbackRecorder::Reactor
    tag "solo"
    queue :my_specific_queue
    recording_step :first
    recording_step :second, after: :first, fail: 1 do
      retries max_attempts: 2, backoff: :fixed, base_delay: 0
    end
    recording_step :third, after: :second
    background after: :first
  end

  class SoloAll < RollbackRecorder::Reactor
    tag "solo"
    queue :my_specific_queue
    background all: true
    input :x, :integer
    recording_step :a
  end

  class SoloNoBackground < RollbackRecorder::Reactor
    tag "solo"
    queue :my_specific_queue
    recording_step :a
    recording_step :b, after: :a
  end

  class SoloApproval < RollbackRecorder::Reactor
    tag "solo"
    queue :my_specific_queue
    recording_step :first
    interrupt(:approve, resume: :background) { wait_for :first }
    recording_step :after, after: :approve
  end
end

RSpec.configure do |config|
  config.before(file_path: %r{spec/ruby_reactor/queues/}) { RollbackRecorder.reset! }
end
