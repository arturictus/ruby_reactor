# frozen_string_literal: true

# Demonstrates the four step outcomes and their one-line helpers:
# `halt!` (clean stop, no rollback), `skip!` (per-step no-op, workflow
# continues, value passed through like a success), `fail!` (with the
# `retry:` veto), and the default-Skipped compensation/undo for steps that
# never wrote one (see `:notify` below, which has no `compensate`/`undo`
# block at all).
class SignalDemoReactor < RubyReactor::Reactor
  input :order_id, :string
  input :halt_at, :symbol, optional: true
  input :skip_notify, :bool, optional: true
  input :skip_finalize, :bool, optional: true
  input :fail_at, :symbol, optional: true
  # A symbol, not a bool: `Context#get_input` currently drops an explicit
  # `false` boolean input back to `nil` (see project memory
  # bug_context_get_input_false.md), so a `retry_allowed: false` input would
  # silently read back as `nil`/"allowed". `:veto` sidesteps that bug.
  input :retry_veto, :symbol, optional: true
  input :success_at_retry, :integer, optional: true, gt?: 0

  step :gate do
    argument :halt_at, input(:halt_at)
    run do |args|
      halt!(reason: "gate closed") if args[:halt_at]&.to_sym == :gate

      success!(true)
    end
  end

  step :charge do
    argument :order_id, input(:order_id)
    argument :fail_at, input(:fail_at)
    argument :retry_veto, input(:retry_veto)
    argument :success_at_retry, input(:success_at_retry)
    wait_for :gate
    retries max_attempts: 3, backoff: :fixed, base_delay: 0.05
    run do |args, context|
      attempt = context.retry_context.attempts_for_step(:charge)
      still_failing = args[:success_at_retry].nil? || attempt < args[:success_at_retry]

      if args[:fail_at]&.to_sym == :charge && still_failing
        fail!("charge declined", retry: args[:retry_veto]&.to_sym != :veto)
      end

      success!(charged: true, order_id: args[:order_id])
    end

    # Explicit compensation: this one really runs, distinguishable from
    # :notify's default Skipped compensation below.
    compensate do |reason, args, _context|
      success!("refunded #{args[:order_id]} (#{reason})")
    end
  end

  # No compensate/undo defined here on purpose: if a later step fails and
  # rollback reaches this step, it reports Skipped rather than a fabricated
  # success, since a skipped step performed no side effect to undo.
  step :notify do
    argument :charge, result(:charge)
    argument :skip_notify, input(:skip_notify)
    wait_for :charge
    run do |args|
      skip!(args[:charge]) if args[:skip_notify]

      success!(notified: true, charge: args[:charge])
    end
  end

  step :finalize do
    argument :notify, result(:notify)
    argument :fail_at, input(:fail_at)
    argument :skip_finalize, input(:skip_finalize)
    wait_for :notify
    run do |args|
      fail!("finalize failed") if args[:fail_at]&.to_sym == :finalize
      skip!(args[:notify]) if args[:skip_finalize]

      success!(args[:notify])
    end
  end

  returns :finalize
end
