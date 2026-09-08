# `async_reactor` dispatches a WHOLE nested reactor to run independently. It is
# linked to this one by execution id (visible in the dashboard, drillable) but
# deliberately outside this reactor's compensation graph.
#
# Contrast with `compose`, which runs the child inline, synchronously, and fully
# wired into rollback. Reach for `async_reactor` when the child genuinely should
# outlive this reactor; reach for `compose` when you need its result anyway —
# waiting for it means the work is sequential regardless.
#
# `fail_at: :backfill` fails the fire-and-forget child — nothing reads it, so
# this reactor still succeeds. `fail_at: :provision` fails the awaited child —
# :verify turns that into this reactor's own Failure, which compensates
# :reserve_seat (see its `undo`).
class AsyncReactorDemoReactor < RubyReactor::Reactor
  input :user_id
  input :fail_at, optional: true

  # An ordinary local step, so a `fail_at: :provision` failure below has
  # something to undo.
  step :reserve_seat do
    argument :user_id, input(:user_id)

    run do |args|
      Rails.logger.info "AsyncReactorDemoReactor: reserved a provisioning seat for #{args[:user_id]}"
      Success(:reserved)
    end

    undo do |_result, args, _ctx|
      Rails.logger.warn "AsyncReactorDemoReactor: releasing provisioning seat for #{args[:user_id]}"
      Success()
    end
  end

  # Fire-and-forget: no step reads this, so if the backfill fails, this reactor
  # neither fails nor compensates. The failure is still recorded on the child's
  # own execution and logged with both execution ids.
  async_reactor :backfill_profile, ProfileBackfillReactor do
    argument :user_id, input(:user_id)
    argument :fail_at, input(:fail_at)
  end

  # Awaited: :verify below reads this, so it blocks (bounded by
  # `async_wait_timeout`) until the child reaches a terminal state.
  async_reactor :provision_account, AccountProvisioningReactor do
    argument :user_id, input(:user_id)
    argument :fail_at, input(:fail_at)
  end

  step :verify do
    argument :account, result(:provision_account)

    run do |args|
      if args[:account].success?
        Success("Provisioned #{args[:account].value[:account_id]}")
      else
        # Opting in: turning the child's failure into this reactor's failure is
        # what triggers compensation of the steps above.
        Failure(args[:account].error)
      end
    end
  end

  returns :verify
end
