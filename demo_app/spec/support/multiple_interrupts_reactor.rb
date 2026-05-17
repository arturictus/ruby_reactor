# frozen_string_literal: true

class MultipleInterruptsReactor < RubyReactor::Reactor
  def self.trace
    @trace ||= []
  end

  step :initiate_transaction do
    run do |_args, context|
      context.reactor_class.trace << :initiate_transaction
      Success({ amount: 100 })
    end
  end

  interrupt :manager_one_approval do
    wait_for :initiate_transaction

    validate do
      required(:status).filled(:string, eql?: "approved")
    end
  end

  interrupt :manager_two_approval do
    wait_for :initiate_transaction

    validate do
      required(:status).filled(:string, eql?: "approved")
    end
  end

  step :complete_transaction do
    argument :approval_one, result(:manager_one_approval)
    argument :approval_two, result(:manager_two_approval)

    run do |args, context|
      context.reactor_class.trace << :complete_transaction
      Success({
                status: "completed",
                approvals: [args[:approval_one], args[:approval_two]]
              })
    end
  end

  step :processing_phase_2 do
    wait_for :complete_transaction
    run do |_args, context|
      context.reactor_class.trace << :processing_phase_2
      Success()
    end
  end

  interrupt :final_approval_1 do
    wait_for :processing_phase_2
    validate do
      required(:status).filled(:string, eql?: "final_ok")
    end
  end

  interrupt :final_approval_2 do
    wait_for :processing_phase_2
    validate do
      required(:status).filled(:string, eql?: "final_ok")
    end
  end

  step :final_completion do
    argument :final_1, result(:final_approval_1)
    argument :final_2, result(:final_approval_2)

    run do |_args, context|
      context.reactor_class.trace << :final_completion
      Success("done")
    end
  end

  returns :final_completion
end
