# The child of a fire-and-forget dispatch. Nothing in the parent reads its
# result, so its failure never reaches the parent.
#
# One class per file: the worker resolves children by constantizing the class
# NAME, so a child hidden inside another reactor's file is invisible to
# Zeitwerk there and the job dies with a NameError.
class ProfileBackfillReactor < RubyReactor::Reactor
  input :user_id

  step :backfill do
    argument :user_id, input(:user_id)
    run do |args|
      Rails.logger.info "ProfileBackfillReactor: backfilling profile for #{args[:user_id]}"
      Success({ backfilled: args[:user_id] })
    end
  end

  returns :backfill
end
