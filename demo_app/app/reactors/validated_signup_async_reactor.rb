# frozen_string_literal: true

# The same ValidatedUserStep, dispatched with `async_step`: its contract is
# enforced inside the worker, and the failure it produces there has the same
# `validation_errors` as the in-process run.
#
# :welcome reads `result(:profile)`, so it waits for the worker. On failure it
# receives the Failure object and propagates it as this reactor's own.
class ValidatedSignupAsyncReactor < RubyReactor::Reactor
  input :name
  input :email
  input :age
  input :marketing_opt_in

  async_step :profile, ValidatedUserStep

  step :welcome do
    argument :profile, result(:profile)

    run do |args|
      profile = args[:profile]
      if profile.is_a?(RubyReactor::Failure)
        Rails.logger.warn "ValidatedSignupAsyncReactor: profile rejected in the worker — #{profile.validation_errors}"
        profile
      else
        Success(profile)
      end
    end
  end

  returns :welcome
end
