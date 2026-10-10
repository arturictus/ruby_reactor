# frozen_string_literal: true

# A resume that meets the reactor's held lock (010 US3). `with_lock` serializes
# runs of the same request. A webhook resuming :approve while another run
# holds that lock is accepted anyway: `continue` validates the payload, stores
# it, and returns a DispatchResult; a worker waits for the lock and finishes
# the run. An invalid payload is still answered with its validation failure.
class ContendedApprovalDemoReactor < RubyReactor::Reactor
  class SubmitStep < RubyReactor::Step
    input :request_id, :integer

    def run
      Success(request_id: inputs.request_id, submitted_at: Time.now.to_i)
    end
  end

  class RecordStep < RubyReactor::Step
    input :decision

    def run
      Success(approved: inputs.decision[:approved])
    end
  end

  input :request_id, :integer

  with_lock { |inputs| "demo:approval:#{inputs[:request_id]}" }

  step :submit, SubmitStep do
    argument :request_id, input(:request_id)
  end

  interrupt :approve do
    wait_for :submit
    validate_payload { required(:approved).filled(:bool) }
    max_attempts 3
  end

  step :record, RecordStep do
    argument :decision, result(:approve)
  end

  returns :record
end
