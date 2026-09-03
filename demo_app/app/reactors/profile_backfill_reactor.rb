# The child of a fire-and-forget dispatch. Nothing in the parent reads its
# result, so its failure never reaches the parent.
#
# One class per file: the worker resolves children by constantizing the class
# NAME, so a child hidden inside another reactor's file is invisible to
# Zeitwerk there and the job dies with a NameError.
class ProfileBackfillReactor < RubyReactor::Reactor
  input :user_id
  input :fail_at, optional: true

  step :backfill do
    argument :user_id, input(:user_id)
    argument :fail_at, input(:fail_at)

    run do |args|
      if args[:fail_at]&.to_sym == :backfill
        Rails.logger.warn "ProfileBackfillReactor: backfill failed for #{args[:user_id]}"
        Failure("Backfill service unavailable")
      else
        Rails.logger.info "ProfileBackfillReactor: backfilling profile for #{args[:user_id]}"
        Success({ backfilled: args[:user_id] })
      end
    end
  end

  returns :backfill
end
