# Contrast with `AsyncReactorDemoReactor`, which mixes an awaited child with a
# fire-and-forget one. Here NOTHING ever reads `result(:backfill_profile)` —
# :acknowledge has no dependency on it either — so this reactor returns as
# soon as its own step finishes, regardless of whether the child is still
# running, still succeeds, or (with `fail_at: :backfill`) fails outright.
class FireAndForgetAsyncReactorDemo < RubyReactor::Reactor
  input :user_id
  input :fail_at, optional: true

  async_reactor :backfill_profile, ProfileBackfillReactor do
    argument :user_id, input(:user_id)
    argument :fail_at, input(:fail_at)
  end

  step :acknowledge do
    argument :user_id, input(:user_id)

    run do |args|
      Rails.logger.info "FireAndForgetAsyncReactorDemo: acknowledged #{args[:user_id]}, not waiting on the backfill"
      Success("Acknowledged #{args[:user_id]}")
    end
  end

  returns :acknowledge
end
