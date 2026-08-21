# One reactor, one hand-off point. Everything up to and including
# :validate_user runs in the caller's process (so a bad user_id fails
# immediately, synchronously); everything after it runs in a worker.
#
# Replaces the old per-step `async true`, which was ambiguous: only the first
# flagged step in a reactor ever took effect and the rest were silently ignored.
class BackgroundDemoReactor < RubyReactor::Reactor
  input :user_id

  step :validate_user do
    argument :user_id, input(:user_id)
    run do |args|
      Rails.logger.info "BackgroundDemoReactor: validating user #{args[:user_id]} in the calling process"
      args[:user_id].present? ? Success(args[:user_id]) : Failure("Invalid user")
    end
  end

  # `after: :validate_user` and `before: :heavy_processing` mean the same thing
  # in this linear chain. They differ in a branching workflow, where each pins
  # the step it names — pick whichever step you actually need pinned.
  background after: :validate_user

  step :heavy_processing do
    argument :user_id, result(:validate_user)

    run do |args|
      Rails.logger.info "BackgroundDemoReactor: processing user #{args[:user_id]} in the worker"
      Success("Heavy processing complete")
    end
  end

  step :notify_completion do
    argument :result, result(:heavy_processing)

    run do |args|
      Rails.logger.info "BackgroundDemoReactor: notification sent. Result: #{args[:result]}"
      Success("Done")
    end
  end

  returns :notify_completion
end
