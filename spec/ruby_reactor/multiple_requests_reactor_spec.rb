# frozen_string_literal: true

require "spec_helper"

RSpec.describe MultipleRequestsReactor do
  subject(:reactor) do
    test_reactor(described_class, inputs)
      .mock_step(:call_service_1) { |args| RubyReactor::Success(args[:request_id]) }
      .mock_step(:call_service_2) { |args| RubyReactor::Success(args[:request_id]) }
      .mock_step(:call_service_3) { |args| RubyReactor::Success(args[:request_id]) }
  end

  context "when valid inputs" do
    let(:inputs) { { request_id: 1 } }

    it "processes successfully" do
      expect(reactor).to be_success
    end
  end

  context "when invalid inputs" do
    let(:inputs) { { request_id: "invalid" } }

    it "returns failure" do
      reactor.run
      expect(reactor).to be_failure
    end
  end
end
