# frozen_string_literal: true

require "spec_helper"

# 009 API §Background workers: both routers enqueue their adapter's
# MapElementRollbackWorker with string-key args.
RSpec.describe "map element rollback routing" do
  let(:args) do
    { map_id: "p:m", position: 0, element_context_id: "e", reactor_class_info: { "type" => "class" },
      parent_reactor_class_name: "P", step_name: "m", batch_size: 2, owner_context_id: "p",
      owner_reactor_class_name: "P" }
  end
  let(:payload) { args.transform_keys(&:to_s).merge("attempt" => 0) }

  it "enqueues the Sidekiq worker" do
    RubyReactor::Adapters::Sidekiq::Router.perform_map_element_rollback_async(**args)
    RubyReactor::Adapters::Sidekiq::Router.perform_map_element_rollback_in(5, **args, attempt: 1)

    jobs = RubyReactor::Adapters::Sidekiq::MapElementRollbackWorker.jobs
    expect(jobs.map { |job| job["args"].first }).to eq([payload, payload.merge("attempt" => 1)])
  end

  it "enqueues the ActiveJob worker" do
    original = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    RubyReactor::Adapters::ActiveJob::Router.perform_map_element_rollback_async(**args)

    job = ActiveJob::Base.queue_adapter.enqueued_jobs.last
    expect(job[:job]).to eq(RubyReactor::Adapters::ActiveJob::MapElementRollbackWorker)
    expect(RubyReactor::RSpec::ActiveJobHelpers.arguments(job)).to eq([payload])
  ensure
    ActiveJob::Base.queue_adapter = original
  end
end
