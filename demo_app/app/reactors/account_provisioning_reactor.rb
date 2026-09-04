# The child of an awaited dispatch — the parent inspects its real outcome.
#
# One class per file: the worker resolves children by constantizing the class
# NAME, so a child hidden inside another reactor's file is invisible to
# Zeitwerk there and the job dies with a NameError.
class AccountProvisioningReactor < RubyReactor::Reactor
  input :user_id
  input :fail_at, optional: true

  step :provision do
    argument :user_id, input(:user_id)
    argument :fail_at, input(:fail_at)

    run do |args|
      if args[:fail_at]&.to_sym == :provision
        Rails.logger.warn "AccountProvisioningReactor: provisioning declined for #{args[:user_id]}"
        Failure("Provisioning service declined the request")
      else
        Rails.logger.info "AccountProvisioningReactor: provisioning account for #{args[:user_id]}"
        Success({ account_id: "acct-#{args[:user_id]}" })
      end
    end
  end

  returns :provision
end
