# frozen_string_literal: true

require "spec_helper"

# The durable record behind `async_step` completion, against real Redis. It is
# deliberately separate from the parent's context blob: a worker writes it
# concurrently with the still-running parent, and two writers on one blob race.
RSpec.describe "Step Result Record storage" do
  let(:storage) { RubyReactor.configuration.storage_adapter }
  let(:context_id) { SecureRandom.uuid }
  let(:reactor_class_name) { "StepResultSpecReactor" }

  it "returns nil for a step that was never dispatched" do
    expect(storage.retrieve_step_result(context_id, :never, reactor_class_name)).to be_nil
  end

  it "round-trips a dispatched record" do
    storage.store_step_result(context_id, :send_email, { "status" => "dispatched" }, reactor_class_name)

    expect(storage.retrieve_step_result(context_id, :send_email, reactor_class_name))
      .to eq({ "status" => "dispatched" })
  end

  it "transitions dispatched -> completed in place" do
    storage.store_step_result(context_id, :send_email, { "status" => "dispatched" }, reactor_class_name)
    storage.store_step_result(
      context_id, :send_email,
      { "status" => "completed", "success" => true, "result" => "sent" },
      reactor_class_name
    )

    record = storage.retrieve_step_result(context_id, :send_email, reactor_class_name)
    expect(record["status"]).to eq("completed")
    expect(record["result"]).to eq("sent")
  end

  it "scopes records by step name within one parent execution" do
    storage.store_step_result(context_id, :a, { "status" => "completed" }, reactor_class_name)
    storage.store_step_result(context_id, :b, { "status" => "dispatched" }, reactor_class_name)

    expect(storage.retrieve_step_result(context_id, :a, reactor_class_name)["status"]).to eq("completed")
    expect(storage.retrieve_step_result(context_id, :b, reactor_class_name)["status"]).to eq("dispatched")
  end

  it "scopes records by parent execution" do
    other = SecureRandom.uuid
    storage.store_step_result(context_id, :a, { "status" => "completed" }, reactor_class_name)

    expect(storage.retrieve_step_result(other, :a, reactor_class_name)).to be_nil
  end

  it "stamps the record with context_ttl so it cannot outlive its parent" do
    storage.store_step_result(context_id, :send_email, { "status" => "dispatched" }, reactor_class_name)

    key = redis.keys("*#{context_id}*step_result*").first
    expect(key).not_to be_nil
    expect(redis.ttl(key)).to be_within(5).of(RubyReactor.configuration.context_ttl)
  end
end
