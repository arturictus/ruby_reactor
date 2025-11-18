# frozen_string_literal: true

require "spec_helper"
require "globalid"

class TestGlobalIDModel
  include GlobalID::Identification

  def self.find(id)
    new(id)
  end

  def initialize(id)
    @id = id
  end

  attr_reader :id

  def to_global_id
    GlobalID.new("gid://app/TestGlobalIDModel/#{@id}")
  end
end

RSpec.describe RubyReactor::ContextSerializer do
  let(:context) { RubyReactor::Context.new }
  let(:job_id) { "test-job-123" }
  let(:started_at) { Time.now }

  before do
    context.inputs = { user_id: 123, amount: BigDecimal("100.50") }
    context.intermediate_results = { step1: { result: "success" } }
    context.private_data = { api_key: "secret" }
    context.current_step = :payment_step # Symbol, as used in production
    context.retry_count = 2
    context.concurrency_key = "user-123"
    context.reactor_class = TestReactor

    context.retry_context.step_attempts = { "payment_step" => 2 }
    context.retry_context.current_step = "payment_step"
    context.retry_context.failure_reason = StandardError.new("Payment failed")
    context.retry_context.next_retry_at = started_at + 60
  end

  describe ".serialize" do
    it "serializes context with all data" do
      serialized = described_class.serialize(context, job_id: job_id, started_at: started_at)

      expect(serialized).to be_a(String)

      data = JSON.parse(serialized)
      expect(data["job_id"]).to eq(job_id)
      expect(data["started_at"]).to eq(started_at.iso8601)
      expect(data["reactor_class"]).to eq("TestReactor")
      expect(data["inputs"]["user_id"]).to eq(123)
      expect(data["inputs"]["amount"]["_type"]).to eq("BigDecimal")
      expect(data["current_step"]).to eq("payment_step") # Serialized as string
      expect(data["retry_context"]["step_attempts"]["payment_step"]).to eq(2)
    end

    it "handles complex object serialization" do
      context.inputs[:timestamp] = Time.new(2023, 1, 1, 12, 0, 0, "+00:00")

      serialized = described_class.serialize(context)
      data = JSON.parse(serialized)

      expect(data["inputs"]["timestamp"]["_type"]).to eq("Time")
      expect(data["inputs"]["timestamp"]["value"]).to eq("2023-01-01T12:00:00+00:00")
    end

    it "serializes objects that respond to to_global_id" do
      global_id_object = TestGlobalIDModel.new(123)
      context.inputs[:global_id_object] = global_id_object

      serialized = described_class.serialize(context)
      data = JSON.parse(serialized)

      expect(data["inputs"]["global_id_object"]["_type"]).to eq("GlobalID")
      expect(data["inputs"]["global_id_object"]["gid"]).to eq("gid://app/TestGlobalIDModel/123")
    end

    it "raises error for context too large" do
      # Mock a very large context
      allow(context).to receive(:serialize_for_retry)
        .and_return({
                      "large_data" => "x" * (described_class::MAX_CONTEXT_SIZE + 1)
                    })

      expect do
        described_class.serialize(context)
      end.to raise_error(RubyReactor::Error::ContextTooLargeError)
    end
  end

  describe ".deserialize" do
    it "deserializes context correctly" do
      serialized = described_class.serialize(context, job_id: job_id, started_at: started_at)
      deserialized = described_class.deserialize(serialized)

      expect(deserialized.inputs[:user_id]).to eq(123)
      expect(deserialized.inputs[:amount]).to be_a(BigDecimal)
      expect(deserialized.inputs[:amount]).to eq(BigDecimal("100.50"))
      expect(deserialized.intermediate_results[:step1][:result]).to eq("success")
      expect(deserialized.current_step).to eq(:payment_step) # Deserialized as symbol
      expect(deserialized.retry_count).to eq(2)
      expect(deserialized.concurrency_key).to eq("user-123")
      expect(deserialized.reactor_class).to eq(TestReactor)
    end

    it "deserializes retry context correctly" do
      serialized = described_class.serialize(context)
      deserialized = described_class.deserialize(serialized)

      expect(deserialized.retry_context.step_attempts["payment_step"]).to eq(2)
      expect(deserialized.retry_context.current_step).to eq("payment_step")
      expect(deserialized.retry_context.failure_reason).to be_a(StandardError)
      expect(deserialized.retry_context.failure_reason.message).to eq("Payment failed")
      expect(deserialized.retry_context.next_retry_at).to be_within(1).of(started_at + 60)
    end

    it "handles complex object deserialization" do
      context.inputs[:timestamp] = Time.new(2023, 1, 1, 12, 0, 0, "+00:00")

      serialized = described_class.serialize(context)
      deserialized = described_class.deserialize(serialized)

      expect(deserialized.inputs[:timestamp]).to be_a(Time)
      expect(deserialized.inputs[:timestamp]).to eq(Time.new(2023, 1, 1, 12, 0, 0, "+00:00"))
    end

    it "deserializes GlobalID objects" do
      located_object = TestGlobalIDModel.new(123)
      allow(GlobalID::Locator).to receive(:locate).with("gid://app/TestGlobalIDModel/123").and_return(located_object)

      # Manually create serialized data with GlobalID
      data = {
        "schema_version" => "1.0",
        "inputs" => {
          "global_id_object" => { "_type" => "GlobalID", "gid" => "gid://app/TestGlobalIDModel/123" }
        },
        "intermediate_results" => {},
        "private_data" => {},
        "current_step" => nil,
        "retry_count" => 0,
        "concurrency_key" => nil,
        "retry_context" => {},
        "execution_trace" => [],
        "undo_stack" => [],
        "test_mode" => false
      }
      serialized = JSON.generate(data)

      deserialized = described_class.deserialize(serialized)

      expect(deserialized.inputs[:global_id_object]).to eq(located_object)
    end

    it "raises error for invalid JSON" do
      expect do
        described_class.deserialize("invalid json")
      end.to raise_error(RubyReactor::Error::DeserializationError)
    end

    it "raises error for unsupported schema version" do
      data = { "schema_version" => "999.0" }
      serialized = JSON.generate(data)

      expect do
        described_class.deserialize(serialized)
      end.to raise_error(RubyReactor::Error::SchemaVersionError)
    end
  end

  describe "round-trip serialization" do
    it "preserves all context data through serialize/deserialize" do
      original = context
      serialized = described_class.serialize(original)
      deserialized = described_class.deserialize(serialized)

      # Compare key attributes
      expect(deserialized.inputs).to eq(original.inputs)
      expect(deserialized.intermediate_results).to eq(original.intermediate_results)
      expect(deserialized.private_data).to eq(original.private_data)
      expect(deserialized.current_step).to eq(original.current_step)
      expect(deserialized.retry_count).to eq(original.retry_count)
      expect(deserialized.concurrency_key).to eq(original.concurrency_key)
      expect(deserialized.reactor_class).to eq(original.reactor_class)

      # Compare retry context
      expect(deserialized.retry_context.step_attempts).to eq(original.retry_context.step_attempts)
      expect(deserialized.retry_context.current_step).to eq(original.retry_context.current_step)
      expect(deserialized.retry_context.failure_reason.message).to eq(original.retry_context.failure_reason.message)
      expect(deserialized.retry_context.next_retry_at).to be_within(1).of(original.retry_context.next_retry_at)
    end
  end
end
