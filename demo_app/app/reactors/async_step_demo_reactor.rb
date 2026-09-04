# `async_step` dispatches ONE step's work to its own job while this reactor
# carries on with every other ready step.
#
# :send_email leaves the process immediately. :record_signup does not wait for
# it — it has no dependency on it. :confirm_delivery does wait, because it reads
# `result(:send_email)`.
#
# `fail_at: :send_email` makes the dispatched unit itself fail, so
# :confirm_delivery — the reader — turns that into this reactor's own
# Failure, which compensates :record_signup (see its `undo`).
class AsyncStepDemoReactor < RubyReactor::Reactor
  input :email
  input :fail_at, optional: true

  async_step :send_email do
    argument :to, input(:email)
    argument :fail_at, input(:fail_at)

    run do |args|
      if args[:fail_at]&.to_sym == :send_email
        Rails.logger.warn "AsyncStepDemoReactor: email delivery failed for #{args[:to]}"
        Failure("SMTP provider rejected the message")
      else
        Rails.logger.info "AsyncStepDemoReactor: sending welcome email to #{args[:to]} in its own job"
        Success({ delivered_to: args[:to], sent_at: Time.current.iso8601 })
      end
    end
  end

  # Runs immediately, in this process, while the email job is still queued.
  step :record_signup do
    argument :email, input(:email)

    run do |args|
      Rails.logger.info "AsyncStepDemoReactor: recording signup for #{args[:email]} right away"
      Success(:recorded)
    end

    undo do |_result, args, _ctx|
      Rails.logger.warn "AsyncStepDemoReactor: undoing signup record for #{args[:email]}"
      Success()
    end
  end

  # Reading the result is what makes a step wait. On success the value arrives
  # exactly as a same-process step would have produced it; on failure the
  # Failure OBJECT arrives instead, so this step can look at it and decide
  # whether the whole reactor should fail (which is the only thing that triggers
  # compensation — an async step's failure never does so on its own).
  step :confirm_delivery do
    argument :delivery, result(:send_email)

    run do |args|
      if args[:delivery].is_a?(RubyReactor::Failure)
        Rails.logger.warn "AsyncStepDemoReactor: email failed — #{args[:delivery].error}"
        Failure(args[:delivery].error)
      else
        Success("Confirmed delivery to #{args[:delivery][:delivered_to]}")
      end
    end
  end

  returns :confirm_delivery
end
