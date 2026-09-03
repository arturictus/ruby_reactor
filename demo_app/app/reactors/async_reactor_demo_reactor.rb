# `async_reactor` dispatches a WHOLE nested reactor to run independently. It is
# linked to this one by execution id (visible in the dashboard, drillable) but
# deliberately outside this reactor's compensation graph.
#
# Contrast with `compose`, which runs the child inline, synchronously, and fully
# wired into rollback. Reach for `async_reactor` when the child genuinely should
# outlive this reactor; reach for `compose` when you need its result anyway —
# waiting for it means the work is sequential regardless.
class AsyncReactorDemoReactor < RubyReactor::Reactor
  input :user_id

  # Fire-and-forget: no step reads this, so if the backfill fails, this reactor
  # neither fails nor compensates. The failure is still recorded on the child's
  # own execution and logged with both execution ids.
  async_reactor :backfill_profile, ProfileBackfillReactor do
    argument :user_id, input(:user_id)
  end

  # Awaited: :verify below reads this, so it blocks (bounded by
  # `async_wait_timeout`) until the child reaches a terminal state.
  async_reactor :provision_account, AccountProvisioningReactor do
    argument :user_id, input(:user_id)
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
