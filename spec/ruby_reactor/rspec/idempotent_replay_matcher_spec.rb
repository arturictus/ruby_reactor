# frozen_string_literal: true

require "spec_helper"

class IdempotentReplayMatcherReactor < RubyReactor::Reactor
  input :order_id

  step :charge do
    argument :order_id, input(:order_id)
    run { |args, _ctx| RubyReactor.Success(args.order_id) }
  end
end

# 011 US6: `be_idempotent_replay` and `test_reactor(..., idempotency_key:)`.
RSpec.describe "be_idempotent_replay", type: :reactor do
  it "matches a repeated key and inspects the original run" do
    first = test_reactor(IdempotentReplayMatcherReactor, { order_id: 1 }, idempotency_key: "order-1")
    again = test_reactor(IdempotentReplayMatcherReactor, { order_id: 1 }, idempotency_key: "order-1")

    expect(first).to be_success
    expect(first).not_to be_idempotent_replay
    expect(again).to be_idempotent_replay
    expect(again).to be_success
    expect(again.reactor_instance.context.context_id).to eq(first.reactor_instance.context.context_id)
  end

  it "fails with a clear message for a run that executed" do
    subject = test_reactor(IdempotentReplayMatcherReactor, { order_id: 2 })

    expect { expect(subject).to be_idempotent_replay }
      .to raise_error(RSpec::Expectations::ExpectationNotMetError, /but the run executed/)
  end
end
