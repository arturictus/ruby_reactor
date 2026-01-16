require "spec_helper"
require "sidekiq/testing"
require "ruby_reactor/sidekiq_workers/worker"

RSpec.describe RubyReactor::SidekiqWorkers::Worker do
  let(:context) { instance_double(RubyReactor::Context, context_id: "test-execution-id", reactor_class: reactor_class, inline_async_execution: true) }
  let(:reactor_class) { double("ReactorClass", name: "TestReactor") }
  let(:executor) { instance_double(RubyReactor::Executor) }
  let(:serialized_context) { "{}" }

  before do
    allow(RubyReactor::ContextSerializer).to receive(:deserialize).and_return(context)
    allow(RubyReactor::Executor).to receive(:new).and_return(executor)
    allow(executor).to receive(:save_context)
    allow(context).to receive(:inline_async_execution=)
  end

  describe "#perform" do
    it "executes the reactor" do
      expect(executor).to receive(:resume_execution)
      subject.perform(serialized_context)
    end

    context "when lock acquisition fails" do
      before do
        allow(executor).to receive(:resume_execution).and_raise(RubyReactor::Lock::AcquisitionError)
      end

      it "reschedules the job" do
        expect(described_class).to receive(:perform_in).with(5, serialized_context, nil)

        subject.perform(serialized_context)
      end
    end
  end
end
