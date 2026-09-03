# The child of an awaited dispatch — the parent inspects its real outcome.
#
# One class per file: the worker resolves children by constantizing the class
# NAME, so a child hidden inside another reactor's file is invisible to
# Zeitwerk there and the job dies with a NameError.
class AccountProvisioningReactor < RubyReactor::Reactor
  input :user_id

  step :provision do
    argument :user_id, input(:user_id)
    run do |args|
      Rails.logger.info "AccountProvisioningReactor: provisioning account for #{args[:user_id]}"
      Success({ account_id: "acct-#{args[:user_id]}" })
    end
  end

  returns :provision
end
