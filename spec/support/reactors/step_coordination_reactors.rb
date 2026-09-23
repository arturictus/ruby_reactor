# frozen_string_literal: true

require_relative "../step_coordination_helpers"

# Fixture step classes and reactors for spec/ruby_reactor/step_coordination/.
# Loaded by the spec process AND the live Sidekiq worker
# (spec/support/sidekiq_boot.rb requires reactors/*.rb), so these stay free of
# any RSpec dependency. Every step body calls OverlapRecorder (required above,
# not from spec_helper, so the worker process has it too), keyed by a
# `run_id` argument threaded through from the reactor's inputs so a worker
# process observes the same trace the spec asserts against.
module StepCoordinationRecording
  def recorder
    OverlapRecorder.new(inputs[:run_id])
  end

  def record_around(tag = inputs[:tag])
    return (yield if block_given?) unless inputs[:run_id]

    recorder.enter(tag)
    yield if block_given?
  ensure
    recorder.leave(tag) if inputs[:run_id]
  end
end

# A step with no coordination at all — filler for scope/reentrancy fixtures
# that need to prove a locked step's neighbors keep overlapping (US2).
class RecordingStep < RubyReactor::Step
  include StepCoordinationRecording

  input :run_id, optional: true
  input :tag
  input :sleep_for, :float, optional: true, default: 0.0

  def run
    record_around { sleep(inputs[:sleep_for]) if inputs[:sleep_for].to_f.positive? }
    Success(inputs[:tag])
  end
end

# Same body, plus an exclusive lock on a fixed key — used as the one locked
# position inside an otherwise-unlocked run of RecordingSteps (US2 scope_spec).
class LockedRecordingStep < RecordingStep
  with_lock(wait: 10) { "shared" }
end

# The MVP fixture (US1): a class step whose `with_lock` key is the resolved
# account id. Also carries a rollback body (used from US6 onward).
class LockedChargeStep < RubyReactor::Step
  include StepCoordinationRecording

  input :run_id, optional: true
  input :account_id
  input :sleep_for, :float, optional: true, default: 0.0
  input :fail_after, :bool, optional: true, default: false
  input :raise_after, :bool, optional: true, default: false

  with_lock(wait: 5) { |args| "acct:#{args[:account_id]}" }

  def run
    record_around(:charge) { sleep(inputs[:sleep_for]) if inputs[:sleep_for].to_f.positive? }
    raise "LockedChargeStep exploded on purpose" if inputs[:raise_after]
    return Failure("charge declined for acct:#{inputs[:account_id]}") if inputs[:fail_after]

    Success(account_id: inputs[:account_id])
  end

  def compensate
    record_around(:charge_compensate) { sleep(inputs[:sleep_for]) if inputs[:sleep_for].to_f.positive? }
    Success()
  end

  def undo
    record_around(:charge_undo) { sleep(inputs[:sleep_for]) if inputs[:sleep_for].to_f.positive? }
    Success()
  end
end

# Exercises ttl + auto_extend (US1 scenario 9): a short ttl that would expire
# mid-body without the keep-alive thread, and wait: 0 so a contending caller
# fails immediately instead of blocking — used from both threads in the spec
# so the contender sees the SAME (short) wait config.
class SleepyStep < RubyReactor::Step
  include StepCoordinationRecording

  input :run_id, optional: true
  input :account_id
  input :sleep_for, :float, optional: true, default: 0.0

  # ttl: 2, not 1 — `Lock::MIN_EXTEND_INTERVAL` floors the auto-extend cadence
  # at 1s regardless of ttl, so ttl: 1 would extend exactly at its own
  # expiry boundary. ttl: 2 keeps a real safety margin while staying much
  # shorter than the 2.5s body it protects, so the claim (auto_extend, not
  # a generous ttl, is what keeps the hold alive) still stands.
  with_lock(ttl: 2, wait: 0, auto_extend: true) { |args| "acct:#{args[:account_id]}" }

  def run
    record_around(:sleepy) { sleep(inputs[:sleep_for]) if inputs[:sleep_for].to_f.positive? }
    Success(inputs[:account_id])
  end
end

# US1 scenario 6b: the key proc sees the same `inputs` as the instance,
# including a default applied by the step's own contract.
class RegionLockedStep < RubyReactor::Step
  include StepCoordinationRecording

  input :run_id, optional: true
  input :region, :string, optional: true, default: "eu"

  with_lock(wait: 0) { |args| "r:#{args[:region]}" }

  def run
    record_around(:region)
    Success(inputs[:region])
  end
end

# US1 scenario 6c: a required, typed input whose contract can be made to
# fail — coordination must never be taken when that happens (Finding 8).
class AmountContractStep < RubyReactor::Step
  include StepCoordinationRecording

  input :run_id, optional: true
  input :amount, :integer

  with_lock(wait: 0) { |args| "amount:#{args[:amount]}" }

  def run
    record_around(:amount)
    Success(inputs[:amount])
  end
end

# US1 scenario 7: the key proc itself misbehaves. `mode` selects raise / nil /
# empty so one class covers all three error shapes.
class BadKeyStep < RubyReactor::Step
  include StepCoordinationRecording

  input :run_id, optional: true
  input :mode, :string

  with_lock(wait: 0) do |args|
    case args[:mode]
    when "raise" then raise "key proc exploded on purpose"
    when "nil" then nil
    when "empty" then ""
    else "bad_key:#{args[:mode]}"
    end
  end

  def run
    record_around(:bad_key_body)
    Success(:ran)
  end
end

# --- Reactors -----------------------------------------------------------

class LockedChargeReactor < RubyReactor::Reactor
  input :run_id, optional: true
  input :account_id
  input :sleep_for, optional: true
  input :fail_after, optional: true
  input :raise_after, optional: true

  step :charge, LockedChargeStep do
    argument :run_id, input(:run_id)
    argument :account_id, input(:account_id)
    argument :sleep_for, input(:sleep_for)
    argument :fail_after, input(:fail_after)
    argument :raise_after, input(:raise_after)
  end

  returns :charge
end

# US1 scenario 6: transform is applied by the reactor's `argument` wiring
# before the resolved value ever reaches the step or its key proc.
class TransformLockedChargeReactor < RubyReactor::Reactor
  input :run_id, optional: true
  input :account_id
  input :sleep_for, optional: true

  step :charge, LockedChargeStep do
    argument :run_id, input(:run_id)
    argument :account_id, input(:account_id), transform: ->(v) { v + 100 }
    argument :sleep_for, input(:sleep_for)
  end

  returns :charge
end

class SleepyLockReactor < RubyReactor::Reactor
  input :run_id, optional: true
  input :account_id
  input :sleep_for, optional: true

  step :charge, SleepyStep do
    argument :run_id, input(:run_id)
    argument :account_id, input(:account_id)
    argument :sleep_for, input(:sleep_for)
  end

  returns :charge
end

# US1 scenario 6b: `region` is intentionally left unwired — RegionLockedStep's
# own contract default ("eu") is what the key proc sees.
class RegionLockedReactor < RubyReactor::Reactor
  input :run_id, optional: true

  step :region, RegionLockedStep do
    argument :run_id, input(:run_id)
  end

  returns :region
end

class AmountContractReactor < RubyReactor::Reactor
  input :run_id, optional: true
  input :amount

  step :charge_amount, AmountContractStep do
    argument :run_id, input(:run_id)
    argument :amount, input(:amount)
  end

  returns :charge_amount
end

class BadKeyReactor < RubyReactor::Reactor
  input :run_id, optional: true
  input :mode

  step :bad_key, BadKeyStep do
    argument :run_id, input(:run_id)
    argument :mode, input(:mode)
  end

  returns :bad_key
end

# US1 scenario 8: the step is suppressed entirely — no lock, no :lock_acquired.
class GuardedLockedChargeReactor < RubyReactor::Reactor
  input :run_id, optional: true
  input :account_id

  step :charge, LockedChargeStep do
    argument :run_id, input(:run_id)
    argument :account_id, input(:account_id)
    where { false }
  end

  returns :charge
end

# US2 scope_spec: eight steps, only the third one locked. Proves the hold does
# not leak into its neighbors.
class ScopedLockReactor < RubyReactor::Reactor
  input :run_id, optional: true

  step :step1, RecordingStep do
    argument :run_id, input(:run_id)
    argument :tag, value(:step1)
    argument :sleep_for, value(0.1)
  end

  step :step2, RecordingStep do
    argument :run_id, input(:run_id)
    argument :tag, value(:step2)
    argument :sleep_for, value(0.1)
  end

  step :step3, LockedRecordingStep do
    argument :run_id, input(:run_id)
    argument :tag, value(:step3)
    argument :sleep_for, value(0.1)
  end

  step :step4, RecordingStep do
    argument :run_id, input(:run_id)
    argument :tag, value(:step4)
    argument :sleep_for, value(0.4)
  end

  step :step5, RecordingStep do
    argument :run_id, input(:run_id)
    argument :tag, value(:step5)
    argument :sleep_for, value(0.4)
  end

  step :step6, RecordingStep do
    argument :run_id, input(:run_id)
    argument :tag, value(:step6)
    argument :sleep_for, value(0.4)
  end

  step :step7, RecordingStep do
    argument :run_id, input(:run_id)
    argument :tag, value(:step7)
    argument :sleep_for, value(0.4)
  end

  step :step8, RecordingStep do
    argument :run_id, input(:run_id)
    argument :tag, value(:step8)
    argument :sleep_for, value(0.4)
  end

  returns :step8
end

# --- US3 (contention) fixtures -------------------------------------------

# `background all: true` puts the whole reactor, including :charge, on a
# worker — the lane where contention parks instead of failing.
class BackgroundLockedChargeReactor < RubyReactor::Reactor
  background all: true

  input :run_id, optional: true
  input :account_id
  input :sleep_for, optional: true

  step :charge, LockedChargeStep do
    argument :run_id, input(:run_id)
    argument :account_id, input(:account_id)
    argument :sleep_for, input(:sleep_for)
  end

  returns :charge
end

# Always fails once it actually runs — used to prove a contention park gives
# back the failure-retry attempt it would otherwise have consumed
# (Finding 2): 3 contention rounds must not leave only 0 real attempts.
class AlwaysFailingLockedStep < RubyReactor::Step
  include StepCoordinationRecording

  input :run_id, optional: true
  input :account_id

  with_lock(wait: 0) { |args| "acct:#{args[:account_id]}" }

  def run
    record_around(:flaky)
    Failure("AlwaysFailingLockedStep always fails once it runs")
  end
end

class FlakyLockedReactor < RubyReactor::Reactor
  background all: true

  input :run_id, optional: true
  input :account_id

  step :charge, AlwaysFailingLockedStep do
    argument :run_id, input(:run_id)
    argument :account_id, input(:account_id)
    retries max_attempts: 2
  end

  returns :charge
end

# wait: 1 (not LockedChargeStep's wait: 5) so the sync wait-then-fail
# scenario (US3-5) resolves quickly.
class WaitOneLockedChargeStep < LockedChargeStep
  with_lock(wait: 1) { |args| "acct:#{args[:account_id]}" }
end

class CompensatingSetupStep < RubyReactor::Step
  include StepCoordinationRecording

  input :run_id, optional: true

  def run
    record_around(:setup)
    Success(:ready)
  end

  # `:setup` always SUCCEEDS, so a later failure rolls it back via `undo`
  # (`CompensationManager#rollback_completed_steps`), not `compensate`
  # (which is called on the step that actually failed).
  def undo
    record_around(:setup_compensate)
    Success()
  end
end

# Two steps: an unlocked one with a compensate block, then a locked one — so
# a synchronous contention failure at :charge exercises compensation of the
# already-completed :setup (US3-4, FR-016).
class TwoStepLockedReactor < RubyReactor::Reactor
  input :run_id, optional: true
  input :account_id

  step :setup, CompensatingSetupStep do
    argument :run_id, input(:run_id)
  end

  step :charge, WaitOneLockedChargeStep do
    argument :run_id, input(:run_id)
    argument :account_id, input(:account_id)
    wait_for :setup
  end

  returns :charge
end

# US3 scenario 6: a reactor-level lock (K1) alongside a step-level lock (K2)
# on a different key, dispatched to a worker — proves the reactor-level hold
# survives a step-level contention park.
class ReactorAndStepLockedReactor < RubyReactor::Reactor
  background all: true
  with_lock(wait: 5) { |inputs| "reactor:#{inputs[:reactor_key]}" }

  input :run_id, optional: true
  input :reactor_key
  input :account_id
  input :sleep_for, optional: true

  step :charge, LockedChargeStep do
    argument :run_id, input(:run_id)
    argument :account_id, input(:account_id)
    argument :sleep_for, input(:sleep_for)
  end

  returns :charge
end

# US3 scenario 7 (Finding 4): the contended step is the reactor's FIRST step,
# and the reactor also rate-limits — a contention park must not consume the
# rate-limit slot a second time on redelivery.
class RateLimitedFirstStepLockedReactor < RubyReactor::Reactor
  background all: true
  with_rate_limit(limit: 100, period: :minute) { |inputs| "rl:finding4:#{inputs[:account_id]}" }

  input :run_id, optional: true
  input :account_id
  input :sleep_for, optional: true

  step :charge, LockedChargeStep do
    argument :run_id, input(:run_id)
    argument :account_id, input(:account_id)
    argument :sleep_for, input(:sleep_for)
  end

  returns :charge
end

# --- US4 (re-entrancy) fixtures ------------------------------------------

# Records the live lock state under the SAME key a preceding step locked —
# used to observe "step released, reactor still holds" (US4-3, Finding 1).
class ReentrancyObserverStep < RubyReactor::Step
  include StepCoordinationRecording

  input :run_id, optional: true
  input :account_id

  def run
    record_around(:observe)
    key = "acct:#{inputs[:account_id]}"
    root = context.root_context || context
    info = RubyReactor.configuration.storage_adapter.lock_info("lock:#{key}")
    Success(locked: !info.nil?, held_count: root.private_data[:held_lock_keys].to_a.count(key))
  end
end

# US4 scenarios 1, 3, 4: a reactor-level lock, two steps locking the SAME
# key, then an observer step — all on one key, one execution.
class ReentrancyChainReactor < RubyReactor::Reactor
  with_lock(wait: 5) { |inputs| "acct:#{inputs[:account_id]}" }

  input :run_id, optional: true
  input :account_id

  step :charge, LockedChargeStep do
    argument :run_id, input(:run_id)
    argument :account_id, input(:account_id)
  end

  step :charge2, LockedChargeStep do
    argument :run_id, input(:run_id)
    argument :account_id, input(:account_id)
    wait_for :charge
  end

  step :observe, ReentrancyObserverStep do
    argument :run_id, input(:run_id)
    argument :account_id, input(:account_id)
    wait_for :charge2
  end

  returns :observe
end

# US4 scenario 2 (SC-006): a locked step whose body drives a CHILD reactor
# execution directly, the same way `compose` links contexts internally
# (lib/ruby_reactor/step/compose_step.rb#link_contexts) — the child's
# `root_context` is the parent's, so its `with_lock` on the same key is
# re-entrant rather than contended.
class ComposeStyleChildReactor < RubyReactor::Reactor
  with_lock(wait: 0) { |inputs| "acct:#{inputs[:account_id]}" }

  input :run_id, optional: true
  input :account_id

  step :inner, RecordingStep do
    argument :run_id, input(:run_id)
    argument :tag, value(:compose_style_child)
  end

  returns :inner
end

class ComposeStyleLockedStep < RubyReactor::Step
  include StepCoordinationRecording

  input :run_id, optional: true
  input :account_id

  with_lock(wait: 0) { |args| "acct:#{args[:account_id]}" }

  def run
    record_around(:compose_style)
    child_context = RubyReactor::Context.new(
      { run_id: inputs[:run_id], account_id: inputs[:account_id] }, ComposeStyleChildReactor
    )
    child_context.root_context = context.root_context || context if context
    child_context.inline_async_execution = context.inline_async_execution if context
    executor = RubyReactor::Executor.new(ComposeStyleChildReactor, {}, child_context)
    executor.execute
    Success(executor.result.class.name)
  end
end

class ComposeStyleReactor < RubyReactor::Reactor
  input :run_id, optional: true
  input :account_id

  step :charge, ComposeStyleLockedStep do
    argument :run_id, input(:run_id)
    argument :account_id, input(:account_id)
  end

  returns :charge
end

# US4 scenario 6 (FR-022): a reactor-level lock, then an `async_step` whose
# step class declares the SAME key — refused at dispatch (T034).
class AsyncStepDeadlockChildStep < RubyReactor::Step
  input :account_id

  with_lock(wait: 0) { |args| "acct:#{args[:account_id]}" }

  def run
    Success(:ran)
  end
end

class AsyncStepDeadlockReactor < RubyReactor::Reactor
  with_lock(wait: 0) { |inputs| "acct:#{inputs[:account_id]}" }

  input :account_id

  async_step :charge, AsyncStepDeadlockChildStep do
    argument :account_id, input(:account_id)
  end
end

# US4 scenario 7: a live-Sidekiq `async_step` whose step class locks K.
class AsyncStepLockedChildStep < RubyReactor::Step
  include StepCoordinationRecording

  input :run_id, optional: true
  input :account_id

  with_lock(wait: 5) { |args| "acct:#{args[:account_id]}" }

  def run
    record_around(:async_step_charge) { sleep(0.3) }
    Success(inputs[:account_id])
  end
end

class AsyncStepLockedReactor < RubyReactor::Reactor
  input :run_id, optional: true
  input :account_id

  async_step :charge, AsyncStepLockedChildStep do
    argument :run_id, input(:run_id)
    argument :account_id, input(:account_id)
  end
end

# wait: 0 — the fast-fail fixture for direct-invocation re-entrancy checks
# (US4 scenarios 8, 10-14), where the point is exactly how a contended call
# behaves, not how long it waits first.
class WaitZeroLockedChargeStep < LockedChargeStep
  with_lock(wait: 0) { |args| "acct:#{args[:account_id]}" }
end

# US4 scenario 10a: the hold is REACTOR-level, spanning an unrelated step —
# a stand-alone direct call on the same key must still contend.
class ReactorLevelOnlyLockedReactor < RubyReactor::Reactor
  with_lock(wait: 5) { |inputs| "acct:#{inputs[:account_id]}" }

  input :run_id, optional: true
  input :account_id
  input :sleep_for, optional: true

  step :sleepy, RecordingStep do
    argument :run_id, input(:run_id)
    argument :tag, value(:reactor_lock_sleep)
    argument :sleep_for, input(:sleep_for)
  end

  returns :sleepy
end

# US4 scenarios 12-14: a locked step whose body calls another class step
# directly. `inner_account_id` (defaults to the same key) and `pass_context`
# (defaults true) parametrize the three cases from one fixture:
#   - same key + context passed  -> re-entrant, proceeds (12)
#   - different key + context    -> contends on the inner key alone (13)
#   - same key + no context      -> a fresh, unrelated execution: contends
#     with the OUTER hold (14)
class ReentrantInnerCallStep < RubyReactor::Step
  include StepCoordinationRecording

  input :run_id, optional: true
  input :account_id
  input :inner_account_id, optional: true
  input :pass_context, optional: true, default: true

  with_lock(wait: 5) { |args| "acct:#{args[:account_id]}" }

  def run
    record_around(:outer)
    inner_id = inputs[:inner_account_id] || inputs[:account_id]
    inner_ctx = inputs[:pass_context] ? context : nil
    begin
      inner_result = WaitZeroLockedChargeStep.run({ run_id: inputs[:run_id], account_id: inner_id }, inner_ctx)
      Success(
        inner_class: inner_result.class.name,
        inner_message: (inner_result.message if inner_result.respond_to?(:message))
      )
    rescue StandardError => e
      # A direct `Step.run` call has no StepExecutor around it to convert a
      # contention raise into a Failure (dsl-surface.md: "wait-then-fail" on
      # this entry point is a raised error, matching how `enforce_contract!`
      # already raises directly from `Step.run`). Capture it the same shape
      # as a Failure so the outer step's own result can report either.
      Success(inner_class: e.class.name, inner_message: e.message)
    end
  end
end

class ReentrantInnerCallReactor < RubyReactor::Reactor
  input :run_id, optional: true
  input :account_id
  input :inner_account_id, optional: true
  input :pass_context, optional: true

  step :charge, ReentrantInnerCallStep do
    argument :run_id, input(:run_id)
    argument :account_id, input(:account_id)
    argument :inner_account_id, input(:inner_account_id)
    argument :pass_context, input(:pass_context)
  end

  returns :charge
end

# --- US8 (inline steps) fixtures ------------------------------------------

# The inline equivalent of LockedChargeReactor/LockedChargeStep — same key
# proc, same recorder tags, same fail_after/raise_after/sleep_for knobs — so
# lock_spec's core scenarios and rollback_spec's compensate-overlap scenario
# both run identically against a class step and an inline step (T056/T057).
class InlineLockedChargeReactor < RubyReactor::Reactor
  input :run_id, optional: true
  input :account_id
  input :sleep_for, optional: true
  input :fail_after, optional: true
  input :raise_after, optional: true

  step :charge do
    with_lock(wait: 5) { |args| "acct:#{args[:account_id]}" }

    argument :run_id, input(:run_id)
    argument :account_id, input(:account_id)
    argument :sleep_for, input(:sleep_for)
    argument :fail_after, input(:fail_after)
    argument :raise_after, input(:raise_after)

    run do |args, _ctx|
      recorder = args[:run_id] && OverlapRecorder.new(args[:run_id])
      recorder&.enter(:charge)
      sleep(args[:sleep_for].to_f) if args[:sleep_for].to_f.positive?
      raise "InlineLockedChargeStep exploded on purpose" if args[:raise_after]
      next RubyReactor.Failure("charge declined for acct:#{args[:account_id]}") if args[:fail_after]

      RubyReactor.Success(account_id: args[:account_id])
    ensure
      recorder&.leave(:charge)
    end

    compensate do |_error, args, _ctx|
      recorder = args[:run_id] && OverlapRecorder.new(args[:run_id])
      recorder&.enter(:charge_compensate)
      sleep(args[:sleep_for].to_f) if args[:sleep_for].to_f.positive?
      RubyReactor.Success()
    ensure
      recorder&.leave(:charge_compensate)
    end
  end

  returns :charge
end

# --- Phase 11 (US5 cont.): step-level ordered lock fixtures --------------

# Item 1/2/5/7: the ordered FIRST step, plus a second, unordered step whose
# body is free to overlap a neighboring run's :seq (US2-style scope proof,
# applied to the ordered lock).
class OrderedLockFirstStep < RubyReactor::Step
  include StepCoordinationRecording

  input :run_id, optional: true
  input :position, optional: true
  input :sleep_for, :float, optional: true, default: 0.0

  with_ordered_lock { |args| "seq:#{args[:run_id]}" }

  def run
    record_around(:seq) { sleep(inputs[:sleep_for]) if inputs[:sleep_for].to_f.positive? }
    Success(inputs[:position])
  end
end

class OrderedLockThenUnorderedStep < RubyReactor::Step
  include StepCoordinationRecording

  input :run_id, optional: true
  input :sleep_for, :float, optional: true, default: 0.0

  def run
    record_around(:after_seq) { sleep(inputs[:sleep_for]) if inputs[:sleep_for].to_f.positive? }
    Success(:ran)
  end
end

class OrderedLockFirstReactor < RubyReactor::Reactor
  background all: true

  input :run_id, optional: true
  input :position, optional: true
  input :sleep_for, optional: true

  step :seq, OrderedLockFirstStep do
    argument :run_id, input(:run_id)
    argument :position, input(:position)
    argument :sleep_for, input(:sleep_for)
  end

  step :after, OrderedLockThenUnorderedStep do
    argument :run_id, input(:run_id)
    # Wide window relative to :seq's own (short) body: gives a following
    # run's ordered :seq plenty of opportunity to fall inside a PRECEDING
    # run's unordered :after window, even under full-suite Redis/worker
    # load, so the "surrounding steps overlap normally" scenario isn't a
    # coin flip on scheduling jitter.
    argument :sleep_for, value(1.5)
    wait_for :seq
  end

  returns :after
end

# Item 3: a DIFFERENT step class sharing the SAME key string as
# OrderedLockFirstStep — same sequence, since the ordered lock's identity is
# the key, not the step class — that always fails, to poison the chain.
class OrderedLockFailingStep < RubyReactor::Step
  include StepCoordinationRecording

  input :run_id, optional: true
  input :position, optional: true

  with_ordered_lock { |args| "seq:#{args[:run_id]}" }

  def run
    record_around(:seq)
    Failure("OrderedLockFailingStep fails on purpose")
  end
end

class OrderedLockFailingReactor < RubyReactor::Reactor
  background all: true

  input :run_id, optional: true
  input :position, optional: true

  step :seq, OrderedLockFailingStep do
    argument :run_id, input(:run_id)
    argument :position, input(:position)
  end

  returns :seq
end

# Item 4: strict: false — the chain keeps executing every position
# regardless of a prior failure.
class OrderedLockLenientStep < RubyReactor::Step
  include StepCoordinationRecording

  input :run_id, optional: true
  input :position, optional: true
  input :fail_at, optional: true

  with_ordered_lock(strict: false) { |args| "lenient:#{args[:run_id]}" }

  def run
    record_around(:lenient_seq)
    return Failure("OrderedLockLenientStep fails on purpose") if inputs[:fail_at]

    Success(inputs[:position])
  end
end

class OrderedLockLenientReactor < RubyReactor::Reactor
  background all: true

  input :run_id, optional: true
  input :position, optional: true
  input :fail_at, optional: true

  step :seq, OrderedLockLenientStep do
    argument :run_id, input(:run_id)
    argument :position, input(:position)
    argument :fail_at, input(:fail_at)
  end

  returns :seq
end

# Item 6: a short poison_pill_timeout — a position that INCRed but never
# arrives must not stall the chain forever.
class OrderedLockPoisonStep < RubyReactor::Step
  include StepCoordinationRecording

  input :run_id, optional: true
  input :position, optional: true

  with_ordered_lock(poison_pill_timeout: 1) { |args| "poison:#{args[:run_id]}" }

  def run
    record_around(:poison_seq)
    Success(inputs[:position])
  end
end

class OrderedLockPoisonReactor < RubyReactor::Reactor
  background all: true

  input :run_id, optional: true
  input :position, optional: true

  step :seq, OrderedLockPoisonStep do
    argument :run_id, input(:run_id)
    argument :position, input(:position)
  end

  returns :seq
end

# Item 8: the ordered lock is never re-taken for rollback. :seq always fails
# forward (triggering `compensate`, not `undo`) so a passing run proves
# `around_rollback` never calls into the ordered-lock gate at all —
# checked by the spec via the sequence's `next` counter staying at 1.
class OrderedLockFailStep < RubyReactor::Step
  include StepCoordinationRecording

  input :run_id, optional: true
  input :position, optional: true

  with_ordered_lock { |args| "rollback_seq:#{args[:run_id]}" }

  def run
    record_around(:ordered_rollback_run)
    Failure("OrderedLockFailStep fails on purpose")
  end

  def compensate
    record_around(:ordered_rollback_compensate)
    Success()
  end
end

class OrderedLockRollbackReactor < RubyReactor::Reactor
  input :run_id, optional: true
  input :position, optional: true

  step :seq, OrderedLockFailStep do
    argument :run_id, input(:run_id)
    argument :position, input(:position)
  end

  returns :seq
end

# --- US7 (observability) fixtures ----------------------------------------

# wait: 0 — fails fast on contention, for observability specs that only need
# a deterministic `:lock_failed` event, not a real wait.
class WaitZeroLockedChargeReactor < RubyReactor::Reactor
  input :run_id, optional: true
  input :account_id
  input :sleep_for, optional: true

  step :charge, WaitZeroLockedChargeStep do
    argument :run_id, input(:run_id)
    argument :account_id, input(:account_id)
    argument :sleep_for, input(:sleep_for)
  end

  returns :charge
end

# --- US5 (semaphore, rate limit, period) fixtures ------------------------

class SemaphoreStep < RubyReactor::Step
  include StepCoordinationRecording

  input :run_id, optional: true
  input :resource_id
  input :sleep_for, :float, optional: true, default: 0.15

  # wait: 0, not a blocking wait — the storage adapter is one shared Redis
  # connection process-wide (no pool), and a `BLPOP` blocking wait from one
  # thread holds that shared connection's dispatch lock for its whole
  # timeout, starving every OTHER thread's redis calls (including the
  # releases the blocked thread is itself waiting on). The spec retries on
  # contention client-side instead, the same safe pattern `with_lock`'s
  # polling loop already uses.
  with_semaphore(limit: 2, wait: 0) { |args| "sem:#{args[:resource_id]}" }

  def run
    record_around(:sem) { sleep(inputs[:sleep_for]) }
    Success(inputs[:resource_id])
  end
end

class StepSemaphoreReactor < RubyReactor::Reactor
  input :run_id, optional: true
  input :resource_id
  input :sleep_for, optional: true

  step :charge, SemaphoreStep do
    argument :run_id, input(:run_id)
    argument :resource_id, input(:resource_id)
    argument :sleep_for, input(:sleep_for)
  end

  returns :charge
end

# US5 scenario 2: a limit:1 semaphore key registers in the held-keys
# registry, matching a limit:1 semaphore's circular-wait shape.
class SemaphoreLimitOneStep < RubyReactor::Step
  input :run_id, optional: true
  input :resource_id

  with_semaphore(limit: 1, wait: 5) { |args| "sem1:#{args[:resource_id]}" }

  def run
    root = context.root_context || context
    Success(held: root.private_data[:held_lock_keys].to_a.include?("sem1:#{inputs[:resource_id]}"))
  end
end

class SemaphoreLimitOneReactor < RubyReactor::Reactor
  input :run_id, optional: true
  input :resource_id

  step :charge, SemaphoreLimitOneStep do
    argument :run_id, input(:run_id)
    argument :resource_id, input(:resource_id)
  end

  returns :charge
end

class RateLimitedStep < RubyReactor::Step
  input :account_id

  with_rate_limit(limit: 2, period: :minute) { |args| "rl:#{args[:account_id]}" }

  def run
    Success(:ran)
  end
end

class StepRateLimitedReactor < RubyReactor::Reactor
  input :account_id

  step :charge, RateLimitedStep do
    argument :account_id, input(:account_id)
  end

  returns :charge
end

# US5 scenario 4: named rate limits reference `config.rate_limits`.
class NamedRateLimitedStep < RubyReactor::Step
  input :account_id

  with_rate_limit(:step_coordination_named_limit)

  def run
    Success(:ran)
  end
end

class StepNamedRateLimitedReactor < RubyReactor::Reactor
  input :account_id

  step :charge, NamedRateLimitedStep do
    argument :account_id, input(:account_id)
  end

  returns :charge
end

class UnknownRateLimitedStep < RubyReactor::Step
  input :account_id

  with_rate_limit(:step_coordination_never_registered)

  def run
    Success(:ran)
  end
end

class UnknownRateLimitedReactor < RubyReactor::Reactor
  input :account_id

  step :charge, UnknownRateLimitedStep do
    argument :account_id, input(:account_id)
  end

  returns :charge
end

class PeriodStep < RubyReactor::Step
  include StepCoordinationRecording

  input :run_id, optional: true
  input :bucket_key
  input :fail_body, optional: true, default: false

  with_period(every: :hour) { |args| "period:#{args[:bucket_key]}" }

  def run
    record_around(:period_body)
    return Failure("boom, deliberately") if inputs[:fail_body]

    Success(:ran)
  end
end

class AfterPeriodStep < RubyReactor::Step
  include StepCoordinationRecording

  input :run_id, optional: true

  def run
    record_around(:after_period)
    Success(:ran)
  end
end

# US5 scenarios 5, 6: a skipped step does not halt the reactor, and a failed
# body never marks the bucket.
class PeriodReactor < RubyReactor::Reactor
  input :run_id, optional: true
  input :bucket_key
  input :fail_body, optional: true

  step :period_step, PeriodStep do
    argument :run_id, input(:run_id)
    argument :bucket_key, input(:bucket_key)
    argument :fail_body, input(:fail_body)
  end

  step :after, AfterPeriodStep do
    argument :run_id, input(:run_id)
    wait_for :period_step
  end

  returns :after
end

# US5 scenario 7: period + lock together — the re-check under the lock
# closes the race between two threads hitting the same fresh bucket.
class PeriodPlusLockStep < RubyReactor::Step
  include StepCoordinationRecording

  input :run_id, optional: true
  input :bucket_key

  with_lock(wait: 5) { |args| "periodlock:#{args[:bucket_key]}" }
  with_period(every: :hour) { |args| "period:#{args[:bucket_key]}" }

  def run
    record_around(:period_lock_body)
    Success(:ran)
  end
end

class PeriodPlusLockReactor < RubyReactor::Reactor
  input :run_id, optional: true
  input :bucket_key

  step :charge, PeriodPlusLockStep do
    argument :run_id, input(:run_id)
    argument :bucket_key, input(:bucket_key)
  end

  returns :charge
end

# US5 scenario 8: lock AND semaphore on one step — proves no deadlock and
# (via the spec's middleware capture) that release order is semaphore then
# lock (FR-008).
class LockAndSemaphoreStep < RubyReactor::Step
  include StepCoordinationRecording

  input :run_id, optional: true
  input :key_id

  with_lock(wait: 5) { |args| "combo_lock:#{args[:key_id]}" }
  with_semaphore(limit: 2, wait: 5) { |args| "combo_sem:#{args[:key_id]}" }

  def run
    record_around(:combo)
    Success(:ran)
  end
end

class LockAndSemaphoreReactor < RubyReactor::Reactor
  input :run_id, optional: true
  input :key_id

  step :charge, LockAndSemaphoreStep do
    argument :run_id, input(:run_id)
    argument :key_id, input(:key_id)
  end

  returns :charge
end

# --- US6 (rollback) fixtures ----------------------------------------------

# Always fails — the trigger that puts a reactor into rollback.
class AlwaysFailStep < RubyReactor::Step
  input :run_id, optional: true

  def run
    Failure("AlwaysFailStep fails on purpose")
  end
end

# US6: a step whose :charge (LockedChargeStep) succeeds, then a later step
# fails, triggering undo of :charge under its own lock.
class RollbackReactor < RubyReactor::Reactor
  input :run_id, optional: true
  input :account_id
  input :sleep_for, optional: true

  step :charge, LockedChargeStep do
    argument :run_id, input(:run_id)
    argument :account_id, input(:account_id)
    argument :sleep_for, input(:sleep_for)
  end

  step :boom, AlwaysFailStep do
    argument :run_id, input(:run_id)
    wait_for :charge
  end

  returns :boom
end

# US6 scenario 3: :charge ITSELF fails, exercising `compensate` (not `undo`).
class CompensateReactor < RubyReactor::Reactor
  input :run_id, optional: true
  input :account_id
  input :sleep_for, optional: true

  step :charge, LockedChargeStep do
    argument :run_id, input(:run_id)
    argument :account_id, input(:account_id)
    argument :sleep_for, input(:sleep_for)
    argument :fail_after, value(true)
  end

  returns :charge
end

# US6 scenario 4: a limit:1 semaphore re-taken for undo.
class SemaphoreRollbackStep < RubyReactor::Step
  include StepCoordinationRecording

  input :run_id, optional: true
  input :resource_id

  with_semaphore(limit: 1, wait: 5) { |args| "semrb:#{args[:resource_id]}" }

  def run
    record_around(:semrb_run)
    Success(:ran)
  end

  def undo
    record_around(:semrb_undo)
    Success()
  end
end

class SemaphoreRollbackReactor < RubyReactor::Reactor
  input :run_id, optional: true
  input :resource_id

  step :charge, SemaphoreRollbackStep do
    argument :run_id, input(:run_id)
    argument :resource_id, input(:resource_id)
  end

  step :boom, AlwaysFailStep do
    argument :run_id, input(:run_id)
    wait_for :charge
  end

  returns :boom
end

# US6 scenario 5 (US6-3, FR-025): lock + rate_limit + period all declared;
# rate limit and period are exhausted by the time rollback runs, but undo
# must still run (only lock/semaphore gate rollback).
class QuotaGatedRollbackStep < RubyReactor::Step
  include StepCoordinationRecording

  input :run_id, optional: true
  input :account_id

  with_lock(wait: 5) { |args| "quota_lock:#{args[:account_id]}" }
  with_rate_limit(limit: 1, period: :minute) { |args| "quota_rl:#{args[:account_id]}" }
  with_period(every: :hour) { |args| "quota_period:#{args[:account_id]}" }

  def run
    record_around(:quota_run)
    Success(:ran)
  end

  def undo
    record_around(:quota_undo)
    Success()
  end
end

class QuotaGatedRollbackReactor < RubyReactor::Reactor
  input :run_id, optional: true
  input :account_id

  step :charge, QuotaGatedRollbackStep do
    argument :run_id, input(:run_id)
    argument :account_id, input(:account_id)
  end

  step :boom, AlwaysFailStep do
    argument :run_id, input(:run_id)
    wait_for :charge
  end

  returns :boom
end

# --- Regression fixtures folded in from the review-round spec files (005 US7).
# Class names kept; the examples now live in the behavior-named spec files.

# A step whose key reads an input the CONTRACT supplies: every site that
# computes the key (forward, rollback, the async dispatch guard, the
# dashboard) has to apply the defaults first or it computes a different key
# than the one actually held.
class DefaultedKeyStep < RubyReactor::Step
  input :account_id
  input :region, :string, optional: true, default: "eu"

  with_lock(wait: 0) { |args| "acct:#{args[:account_id]}:#{args[:region]}" }

  def run
    Success(region: inputs[:region])
  end
end

class DefaultedKeyReactor < RubyReactor::Reactor
  input :account_id

  step :charge, DefaultedKeyStep do
    argument :account_id, input(:account_id)
  end

  returns :charge
end

# Ordered lock plus a lock that will contend, run SYNCHRONOUSLY: there is no
# queue to park into, so the position must be handed back rather than left in
# flight for the poison_pill_timeout.
class SyncOrderedContendedStep < RubyReactor::Step
  input :run_id
  input :account_id

  with_ordered_lock { |args| "sync_seq:#{args[:run_id]}" }
  with_lock(wait: 0) { |args| "sync_seq_lock:#{args[:account_id]}" }

  def run
    Success(:charged)
  end
end

class SyncOrderedContendedReactor < RubyReactor::Reactor
  input :run_id
  input :account_id

  step :charge, SyncOrderedContendedStep do
    argument :run_id, input(:run_id)
    argument :account_id, input(:account_id)
  end

  returns :charge
end

# An `async_step` that parks on a semaphore held elsewhere — the shape
# StepSweeper must not mistake for a lost unit.
class SweepParkStep < RubyReactor::Step
  input :account_id

  with_semaphore(limit: 1, wait: 0) { |args| "sweep_park_sem:#{args[:account_id]}" }

  def run
    Success(:charged)
  end
end

class SweepParkReactor < RubyReactor::Reactor
  input :account_id

  async_step :charge, SweepParkStep do
    argument :account_id, input(:account_id)
  end

  step :ack do
    run { RubyReactor.Success(:dispatched) }
  end

  returns :ack
end

# Two primitives on ONE step: the dashboard has to show both gates, not just
# whichever `coordination_declarations` happens to yield first.
class TwoPrimitiveStep < RubyReactor::Step
  input :account_id

  with_lock(wait: 0) { |args| "two_prim_lock:#{args[:account_id]}" }
  with_semaphore(limit: 2, wait: 0) { |args| "two_prim_sem:#{args[:account_id]}" }

  def run
    Success(:charged)
  end
end

class TwoPrimitiveReactor < RubyReactor::Reactor
  input :account_id

  step :charge, TwoPrimitiveStep do
    argument :account_id, input(:account_id)
  end

  returns :charge
end

# An INLINE step with no `argument` wiring: its body (and its lock key) read
# the reactor's inputs, and so must its rollback — the undo stack only stores
# the empty resolved-arguments hash.
class InlineNoArgsRollbackReactor < RubyReactor::Reactor
  input :account_id

  step :charge do
    with_lock(wait: 0) { |args| "inline_rollback:#{args[:account_id]}" }
    run { RubyReactor.Success(:charged) }
    undo { RubyReactor.Success(:undone) }
  end

  step :boom do
    run { RubyReactor.Failure("boom") }
  end

  returns :boom
end

# A step-level `with_ordered_lock` whose body runs a nested `Reactor.run`
# ordered on the SAME key: a second nonce could never come up.
class NestedOrderedInnerStep < RubyReactor::Step
  input :run_id

  with_ordered_lock(poison_pill_timeout: 2) { |args| "nested_step_seq:#{args[:run_id]}" }

  def run
    Success(:inner)
  end
end

class NestedOrderedInnerReactor < RubyReactor::Reactor
  input :run_id

  step :inner, NestedOrderedInnerStep do
    argument :run_id, input(:run_id)
  end

  returns :inner
end

class NestedOrderedOuterReactor < RubyReactor::Reactor
  input :run_id

  step :outer do
    with_ordered_lock(poison_pill_timeout: 2) { |args| "nested_step_seq:#{args[:run_id]}" }
    run { |args| NestedOrderedInnerReactor.run(run_id: args[:run_id]) }
  end

  returns :outer
end

# The dispatch-time deadlock guard fires on :charge — an earlier step has
# already run its side effect, so the reactor must unwind it.
class DeadlockGuardChildStep < RubyReactor::Step
  input :account_id

  with_lock(wait: 0) { |args| "guard_acct:#{args[:account_id]}" }

  def run
    Success(:never)
  end
end

DEADLOCK_GUARD_UNDONE = [] # rubocop:disable Style/MutableConstant

class DeadlockGuardRollbackReactor < RubyReactor::Reactor
  with_lock(wait: 0) { |inputs| "guard_acct:#{inputs[:account_id]}" }

  input :account_id

  step :side_effect do
    run { RubyReactor.Success(:done) }
    undo do |_value, _args, _ctx|
      DEADLOCK_GUARD_UNDONE << :side_effect
      RubyReactor.Success(:undone)
    end
  end

  async_step :charge, DeadlockGuardChildStep do
    argument :account_id, input(:account_id)
    wait_for :side_effect
  end
end

# A locked class step dispatched to the worker: the hooks it fires there must
# be the configured middlewares, attributed to the step.
class WorkerHookStep < RubyReactor::Step
  input :account_id

  with_lock(wait: 0) { |args| "worker_hook:#{args[:account_id]}" }

  def run
    Success(:charged)
  end
end

class WorkerHookReactor < RubyReactor::Reactor
  input :account_id

  async_step :charge, WorkerHookStep do
    argument :account_id, input(:account_id)
  end

  step :ack do
    run { RubyReactor.Success(:dispatched) }
  end

  returns :ack
end

# A class-backed step whose coordination is declared INLINE, on the reactor's
# step block: `Step.run` can only see the step class's own config, so the
# executor/worker is the only place this declaration can be acquired.
class InlineOverrideImplStep < RubyReactor::Step
  input :account_id

  def run
    Success(:charged)
  end
end

class InlineOverrideReactor < RubyReactor::Reactor
  input :account_id

  step :charge, InlineOverrideImplStep do
    argument :account_id, input(:account_id)
    with_lock(wait: 0) { |args| "inline_override:#{args[:account_id]}" }
  end

  returns :charge
end

class InlineOverrideAsyncReactor < RubyReactor::Reactor
  input :account_id

  async_step :charge, InlineOverrideImplStep do
    argument :account_id, input(:account_id)
    with_lock(wait: 0) { |args| "inline_override_async:#{args[:account_id]}" }
  end

  step :ack do
    run { RubyReactor.Success(:dispatched) }
  end

  returns :ack
end

# Flipped between dispatch and delivery, so the worker is the one deciding
# the guard — the executor already decided it the other way.
ASYNC_GUARD_FLAG = { run: true } # rubocop:disable Style/MutableConstant

class GuardedAsyncStep < RubyReactor::Step
  input :account_id

  with_lock(wait: 0) { |args| "guarded_async:#{args[:account_id]}" }

  def run
    Success(:charged)
  end
end

class GuardedAsyncReactor < RubyReactor::Reactor
  input :account_id

  async_step :charge, GuardedAsyncStep do
    argument :account_id, input(:account_id)
    where { ASYNC_GUARD_FLAG[:run] }
  end

  step :ack do
    run { RubyReactor.Success(:dispatched) }
  end

  returns :ack
end

# Reactor-level lock PLUS a step-level lock that will contend: the park hands
# the reactor's hold to a redelivery, and the contention ceiling then cancels
# that redelivery.
class CeilingStep < RubyReactor::Step
  input :account_id

  with_lock(wait: 0) { |args| "ceiling_step:#{args[:account_id]}" }

  def run
    Success(:charged)
  end
end

class CeilingReactor < RubyReactor::Reactor
  with_lock(ttl: 60, wait: 0) { |inputs| "ceiling_reactor:#{inputs[:account_id]}" }

  input :account_id

  step :charge, CeilingStep do
    argument :account_id, input(:account_id)
  end

  returns :charge
end

# An `async_step` inside a COMPOSED child: its Step Result Record belongs to
# the child's namespace, which is what the reader looks under.
class ComposedAsyncChildStep < RubyReactor::Step
  input :account_id

  def run
    Success(:child_charged)
  end
end

class ComposedAsyncChildReactor < RubyReactor::Reactor
  input :account_id

  async_step :charge, ComposedAsyncChildStep do
    argument :account_id, input(:account_id)
  end

  step :ack do
    run { RubyReactor.Success(:dispatched) }
  end

  returns :ack
end

class ComposedAsyncParentReactor < RubyReactor::Reactor
  input :account_id

  compose :child, ComposedAsyncChildReactor do
    argument :account_id, input(:account_id)
  end

  returns :child
end

# A direct `InnerStep.run(args, context)` nested inside a coordinated outer
# step, contending AFTER the outer body has already had a side effect.
class NestedMarkerInnerStep < RubyReactor::Step
  input :account_id

  with_lock(wait: 0) { |args| "nested_marker_inner:#{args[:account_id]}" }
  with_semaphore(limit: 1, wait: 0) { |args| "nested_marker_sem:#{args[:account_id]}" }

  def run
    Success(:inner)
  end
end

class NestedMarkerReactor < RubyReactor::Reactor
  input :account_id

  def self.side_effects
    @side_effects ||= []
  end

  step :outer do
    argument :account_id, input(:account_id)
    with_lock(wait: 0) { |args| "nested_marker_outer:#{args[:account_id]}" }
    run do |args, ctx|
      NestedMarkerReactor.side_effects << :outer_ran
      NestedMarkerInnerStep.run({ account_id: args[:account_id] }, ctx)
    end
    compensate do |_error, _args, _ctx|
      NestedMarkerReactor.side_effects << :outer_compensated
      RubyReactor.Success()
    end
  end

  returns :outer
end

# Counters the fixture bodies below bump, so a spec can tell how many times a
# step's work actually ran.
ROUND4_COUNTS = Hash.new(0)

# An `async_step` whose key proc raises: the dispatch-time deadlock guard
# computes that key while the parent holds one of its own, so the failure must
# arrive as a normal step failure (rolling the earlier step back), not as a
# generic execution error.
class Round4RaisingKeyStep < RubyReactor::Step
  input :account_id

  with_lock(wait: 0) { |_args| raise "key proc blew up" }

  def run
    Success(:charged)
  end
end

class Round4GuardKeyReactor < RubyReactor::Reactor
  with_lock(ttl: 60, wait: 0) { |inputs| "round4_guard:#{inputs[:account_id]}" }

  input :account_id

  step :setup do
    argument :account_id, input(:account_id)
    run { |args| RubyReactor.Success(args[:account_id]) }
    undo { ROUND4_COUNTS[:setup_undo] += 1 }
  end

  async_step :charge, Round4RaisingKeyStep do
    argument :account_id, result(:setup)
  end

  step :ack do
    run { RubyReactor.Success(:dispatched) }
  end

  returns :ack
end

# A step deduped by a window whose body returns a value its own output
# contract rejects: the bucket must NOT be marked, or the next run is deduped
# away on behalf of a step that failed.
class Round4PeriodReactor < RubyReactor::Reactor
  input :account_id

  step :charge do
    argument :account_id, input(:account_id)
    with_period(every: :hour) { |args| "round4_period:#{args[:account_id]}" }
    validate_output :integer
    run do |args|
      ROUND4_COUNTS[:period_body] += 1
      RubyReactor.Success("not an integer: #{args[:account_id]}")
    end
  end

  returns :charge
end

class Round4DuplicateStep < RubyReactor::Step
  input :account_id

  def run
    ROUND4_COUNTS[:duplicate_body] += 1
    Success(:charged)
  end
end

class Round4DuplicateReactor < RubyReactor::Reactor
  input :account_id

  async_step :charge, Round4DuplicateStep do
    argument :account_id, input(:account_id)
  end

  step :ack do
    run { RubyReactor.Success(:dispatched) }
  end

  returns :ack
end
