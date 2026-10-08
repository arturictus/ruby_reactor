# frozen_string_literal: true

# Two approvals answered at the same time (010 US5). :finance resumes in the
# background, so its resume returns at once with the run `running`; :legal's
# resume, arriving while the run is busy, is accepted too (not rejected as
# "running") and applied once the run is free. Each approval is applied once.
class DualApprovalDemoReactor < RubyReactor::Reactor
  class PrepareStep < RubyReactor::Step
    input :request_id, :integer

    def run
      Success(request_id: inputs.request_id)
    end
  end

  class ApproveAllStep < RubyReactor::Step
    input :finance
    input :legal

    def run
      Success(finance: inputs.finance[:approved], legal: inputs.legal[:approved])
    end
  end

  input :request_id, :integer

  step :prepare, PrepareStep do
    argument :request_id, input(:request_id)
  end

  interrupt :finance, resume: :background do
    wait_for :prepare
    validate_payload { required(:approved).filled(:bool) }
  end

  interrupt :legal do
    wait_for :prepare
    validate_payload { required(:approved).filled(:bool) }
  end

  step :approve_all, ApproveAllStep do
    argument :finance, result(:finance)
    argument :legal, result(:legal)
  end

  returns :approve_all
end
