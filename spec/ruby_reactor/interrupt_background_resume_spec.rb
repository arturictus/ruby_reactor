# frozen_string_literal: true

require "spec_helper"

class BackgroundResumeInterruptReactor < RubyReactor::Reactor
  input :user_id

  step :prepare do
    argument :user_id, input(:user_id)
    run { |args| Success("prepared-#{args[:user_id]}") }
  end

  interrupt :wait_for_webhook, resume: :background do
    wait_for :prepare
    max_attempts 2

    validate_payload do
      required(:status).filled(:string)
    end
  end

  step :finalize do
    argument :webhook, result(:wait_for_webhook)
    run { |args| Success("finalized-#{args[:webhook][:status]}") }
  end
end

RSpec.describe "interrupt resume: :background", type: :integration do
  it "rejects an unknown resume mode at definition time" do
    expect do
      Class.new(RubyReactor::Reactor) do
        interrupt :bad, resume: :sideways
      end
    end.to raise_error(RubyReactor::Error::ValidationError, /invalid `resume: :sideways`/)
  end

  it "enqueues the resume to a worker instead of running it inline" do
    execution = BackgroundResumeInterruptReactor.run(user_id: "42")
    expect(execution).to be_a(RubyReactor::InterruptResult)

    result = BackgroundResumeInterruptReactor.continue(
      id: execution.execution_id, payload: { status: "ok" }, step_name: :wait_for_webhook
    )

    # The caller gets the hand-off, not the final result — :finalize has not run.
    expect(result).to be_a(RubyReactor::DispatchResult)
    expect(result.execution_id).to eq(execution.execution_id)
    expect(RubyReactor::Adapters::Sidekiq::Worker.jobs.size).to eq(1)

    paused = BackgroundResumeInterruptReactor.find(execution.execution_id).context
    expect(paused.intermediate_results).not_to have_key(:finalize)
    expect(paused.status.to_s).to eq("running")

    RubyReactor::Adapters::Sidekiq::Worker.drain

    finished = BackgroundResumeInterruptReactor.find(execution.execution_id).context
    expect(finished.status.to_s).to eq("completed")
    expect(finished.intermediate_results[:finalize]).to eq("finalized-ok")
  end

  it "does not enqueue anything when the payload is invalid" do
    execution = BackgroundResumeInterruptReactor.run(user_id: "43")

    expect do
      BackgroundResumeInterruptReactor.continue(
        id: execution.execution_id, payload: { status: "" }, step_name: :wait_for_webhook
      )
    end.to raise_error(RubyReactor::Error::InputValidationError)

    expect(RubyReactor::Adapters::Sidekiq::Worker.jobs).to be_empty

    paused = BackgroundResumeInterruptReactor.find(execution.execution_id).context
    expect(paused.status.to_s).to eq("paused")
  end
end
