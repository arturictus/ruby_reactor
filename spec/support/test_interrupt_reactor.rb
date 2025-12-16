# frozen_string_literal: true

class TestInterruptReactor < RubyReactor::Reactor
  input :user_id

  step :prepare do
    argument :user_id, input(:user_id)
    run do |args|
      Success("prepared-#{args[:user_id]}")
    end
  end

  interrupt :wait_for_approval do
    wait_for :prepare

    correlation_id do |context|
      "approval-#{context.result(:prepare)}"
    end

    validate do
      required(:status).filled(:string)
      required(:approver).filled(:string)
    end
  end

  step :finalize do
    argument :approval_data, result(:wait_for_approval)
    run do |args|
      Success("finalized-#{args[:approval_data][:status]}-by-#{args[:approval_data][:approver]}")
    end
  end
end
