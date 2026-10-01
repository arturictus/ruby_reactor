# frozen_string_literal: true

require "spec_helper"

# 009 R-11, FR-023, S-6: jobs enqueued by the previous gem version carry
# `fail_fast` instead of `atomic`, with string keys. They keep the policy they
# were enqueued with.
module MapLegacyPayloadSpec
  MapRollbackFixtures.parent(self, :Batched, MapRollbackFixtures::Elem, fan_out: true, batch_size: 1)
end

RSpec.describe "map jobs with a pre-upgrade payload" do
  let(:storage) { RubyReactor.configuration.storage_adapter }
  let(:parent_name) { MapLegacyPayloadSpec::Batched.name }

  def take_job(suffix)
    job = QueueProbe.pending.find { |j| QueueProbe.class_of(j).name.end_with?(suffix) }
    if async_backend == :sidekiq
      job.worker_class.jobs.delete(job.raw)
    else
      ActiveJob::Base.queue_adapter.enqueued_jobs.delete(job.raw)
    end
    job
  end

  def legacy(args)
    args.to_h.transform_keys(&:to_s).except("atomic", "_aj_symbol_keys").merge("fail_fast" => true)
  end

  for_each_async_backend do
    it "keeps an element job atomic when it carries fail_fast" do
      id = MapLegacyPayloadSpec::Batched.run(items: [0, 1, 2, 3], fail_at: 0).execution_id
      job = take_job("MapElementWorker")

      RubyReactor::Map::ElementExecutor.perform(legacy(job.args.first))

      map_id = "#{id}:m"
      expect(storage.retrieve_map_failed_context_id(map_id, parent_name)).not_to be_nil
      expect(storage.retrieve_map_results(map_id, parent_name)[1..]).to eq([{ "_skipped" => true }] * 3)
    end

    it "keeps a dispatcher continuation atomic when it carries fail_fast" do
      id = MapLegacyPayloadSpec::Batched.run(items: [0, 1, 2, 3], fail_at: 0).execution_id
      map_id = "#{id}:m"
      storage.store_map_failed_context_id(map_id, "failed-element", parent_name)

      RubyReactor::Map::Dispatcher.perform(
        "map_id" => map_id, "parent_context_id" => id, "parent_reactor_class_name" => parent_name,
        "step_name" => "m", "batch_size" => 1, "strict_ordering" => true, "continuation" => true,
        "fail_fast" => true
      )

      expect(QueueProbe.enqueued("MapElementWorker")).to eq(1)
      expect(storage.retrieve_map_results(map_id, parent_name)).to eq([{ "_skipped" => true }] * 3)
    end

    it "signals the owner from a collector job with string keys" do
      id = MapLegacyPayloadSpec::Batched.run(items: [0], fail_at: nil).execution_id
      take_job("MapElementWorker").perform!
      take_job("MapCollectorWorker") while QueueProbe.enqueued("MapCollectorWorker").positive?

      RubyReactor::Map::Collector.perform(
        "parent_context_id" => id, "map_id" => "#{id}:m", "parent_reactor_class_name" => parent_name,
        "step_name" => "m", "strict_ordering" => true, "timeout" => 3600
      )
      RubyReactor::RSpec::AsyncTestHelpers.drain_async_jobs

      expect(MapLegacyPayloadSpec::Batched.find(id).context.status.to_s).to eq("completed")
    end
  end
end
