# frozen_string_literal: true

require "spec_helper"
require "active_job"
require "ruby_reactor/adapters/active_job/worker"

# The resume/snooze/escalate logic itself is exercised exhaustively against
# the shared `RubyReactor::Worker` mixin in
# spec/ruby_reactor/adapters/sidekiq/worker_spec.rb. This spec only covers
# the ActiveJob-specific wiring: Compat-based enqueue, and that #perform
# delegates into the shared mixin.
# rubocop:disable RSpec/MultipleMemoizedHelpers
RSpec.describe RubyReactor::Adapters::ActiveJob::Worker do
  around do |example|
    original = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    example.run
  ensure
    ActiveJob::Base.queue_adapter = original
  end

  it "extends Compat for perform_async/perform_in" do
    expect(described_class.singleton_class.included_modules).to include(RubyReactor::Adapters::ActiveJob::Compat)
  end

  it "includes the shared RubyReactor::Worker mixin" do
    expect(described_class.included_modules).to include(RubyReactor::Worker)
  end

  describe "#perform" do
    let(:context_id) { "test-execution-id" }
    let(:reactor_class_name) { "TestReactor" }
    let(:reactor_class) { Class.new { def self.name = "TestReactor" } }
    let(:context) do
      instance_double(
        RubyReactor::Context,
        context_id: context_id,
        reactor_class: reactor_class,
        inline_async_execution: true
      )
    end
    let(:executor) { instance_double(RubyReactor::Executor) }
    let(:adapter) { instance_double(RubyReactor::Storage::RedisAdapter) }
    let(:stored_data) { { "context_id" => context_id, "schema_version" => "1.0" } }

    before do
      allow(RubyReactor.configuration).to receive(:storage_adapter).and_return(adapter)
      allow(adapter).to receive(:retrieve_context).with(context_id, reactor_class_name).and_return(stored_data)
      allow(RubyReactor::ContextSerializer).to receive(:deserialize_hash).and_return(context)
      allow(RubyReactor::Executor).to receive(:new).and_return(executor)
      allow(context).to receive(:inline_async_execution=)
    end

    it "rehydrates by id and resumes the reactor" do
      allow(executor).to receive(:resume_execution)
      described_class.new.perform(context_id, reactor_class_name)
      expect(executor).to have_received(:resume_execution)
    end

    it "reschedules via the ActiveJob set(wait:).perform_later path on lock contention" do
      allow(executor).to receive(:resume_execution).and_raise(RubyReactor::Lock::AcquisitionError)
      RubyReactor.configuration.lock_snooze_base_delay = 5
      RubyReactor.configuration.lock_snooze_jitter = 0

      described_class.new.perform(context_id, reactor_class_name)

      enqueued = described_class.queue_adapter.enqueued_jobs
      expect(enqueued.size).to eq(1)
      expect(enqueued.first[:args]).to eq([context_id, reactor_class_name, 1])
    end
  end
end
# rubocop:enable RSpec/MultipleMemoizedHelpers
