# frozen_string_literal: true

require "spec_helper"
require "active_job"
require "ruby_reactor/adapters/active_job/compat"

RSpec.describe RubyReactor::Adapters::ActiveJob::Compat do
  let(:job_class) do
    Class.new(ActiveJob::Base) do
      extend RubyReactor::Adapters::ActiveJob::Compat

      def perform(*); end
    end
  end

  around do |example|
    original = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    example.run
  ensure
    ActiveJob::Base.queue_adapter = original
  end

  describe ".perform_async" do
    it "enqueues immediately via perform_later and returns the job id" do
      job_id = job_class.perform_async("a", "b")

      enqueued = job_class.queue_adapter.enqueued_jobs
      expect(enqueued.size).to eq(1)
      expect(enqueued.first[:args]).to eq(%w[a b])
      expect(job_id).to be_a(String)
    end
  end

  describe ".perform_in" do
    it "enqueues with a wait delay via perform_later and returns the job id" do
      job_id = job_class.perform_in(30, "a")

      enqueued = job_class.queue_adapter.enqueued_jobs
      expect(enqueued.size).to eq(1)
      expect(enqueued.first[:args]).to eq(["a"])
      expect(job_id).to be_a(String)
    end
  end
end
