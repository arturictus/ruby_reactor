# frozen_string_literal: true

require "spec_helper"

# 011 R-03: every router method enqueues on a named queue, and the job carries
# that queue so it knows where it runs. Without one the job goes to the global
# `queue_name`, read when it is enqueued, with today's arguments (FR-024).
RSpec.describe "router queues" do
  def pending
    RubyReactor::RSpec::AsyncTestHelpers.pending_async_jobs
  end

  def args_of(job)
    async_backend == :sidekiq ? job.args : ActiveJob::Arguments.deserialize(job.raw[:args])
  end

  let(:step_args) do
    { root_context_id: "root", reactor_class_name: "K", step_context_id: "ctx", step_name: :s }
  end
  let(:element_args) do
    { map_id: "m", element_id: "m:0", index: 0, serialized_inputs: "{}", reactor_class_info: {},
      strict_ordering: true, parent_context_id: "p", parent_reactor_class_name: "K", step_name: "map" }
  end
  let(:rollback_args) do
    { map_id: "m", position: 0, element_context_id: "e", reactor_class_info: {}, parent_reactor_class_name: "K",
      step_name: "map", batch_size: 2, owner_context_id: "o", owner_reactor_class_name: "K" }
  end
  let(:collection_args) do
    { parent_context_id: "p", map_id: "m", parent_reactor_class_name: "K", step_name: "map",
      strict_ordering: true, timeout: 3600 }
  end

  def enqueue_all(**queue)
    router.perform_async("ctx", "K", **queue)
    router.perform_in(5, "ctx", "K", **queue, **(queue.empty? ? {} : { snooze_count: 2 }))
    router.perform_step_async(**step_args, **queue)
    router.perform_step_in(5, **step_args, contention_attempts: 1, **queue)
    router.perform_map_element_async(**element_args, **queue, **(queue.empty? ? {} : { owner_queue: "main" }))
    router.perform_map_element_in(5, **element_args, **queue)
    router.perform_map_element_rollback_async(**rollback_args, **queue)
    router.perform_map_element_rollback_in(5, **rollback_args, **queue)
    router.perform_map_collection_async(**collection_args, **queue)
  end

  for_each_async_backend do
    let(:router) { RubyReactor.configuration.async_router }

    around do |example|
      original = RubyReactor.configuration.queue_name
      example.run
    ensure
      RubyReactor.configuration.queue_name = original
    end

    it "enqueues every job on the given queue, and tells the job its queue" do
      enqueue_all(queue: "stripe")

      jobs = pending
      expect(jobs.size).to eq(9)
      expect(jobs.map(&:queue)).to all(eq("stripe"))

      root_args = jobs.select { |job| job.worker_class.name.end_with?("::Worker") }.map { |job| args_of(job) }
      expect(root_args).to contain_exactly(["ctx", "K", 0, "stripe"], ["ctx", "K", 2, "stripe"])

      payloads = (jobs.map { |job| args_of(job).first } - root_args.map(&:first)).grep(Hash)
      expect(payloads.size).to eq(7)
      expect(payloads.map { |payload| payload["queue"] }).to all(eq("stripe"))
      expect(payloads.count { |payload| payload["owner_queue"] == "main" }).to eq(1)
    end

    it "uses the global queue, read when enqueued, with today's arguments" do
      RubyReactor.configuration.queue_name = :critical
      enqueue_all

      jobs = pending
      expect(jobs.size).to eq(9)
      expect(jobs.map(&:queue)).to all(eq("critical"))

      root_args = jobs.select { |job| job.worker_class.name.end_with?("::Worker") }.map { |job| args_of(job) }
      expect(root_args).to eq([%w[ctx K], %w[ctx K]])

      payloads = jobs.map { |job| args_of(job).first }.grep(Hash)
      expect(payloads.size).to eq(7)
      expect(payloads.none? { |payload| payload.key?("queue") || payload.key?("owner_queue") }).to be(true)
    end
  end
end
