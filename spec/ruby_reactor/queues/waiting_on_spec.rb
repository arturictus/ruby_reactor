# frozen_string_literal: true

require "spec_helper"

# 011 FR-020, SC-007: a run waiting for a job on a queue says which queue and
# since when, stays running, and is never failed for queue lag.
RSpec.describe "runs waiting on a queue", type: :reactor do
  let(:storage) { RubyReactor.configuration.storage_adapter }
  let(:log) { StringIO.new }

  around do |example|
    original = RubyReactor.configuration.logger
    RubyReactor.configuration.logger = Logger.new(log)
    example.run
  ensure
    RubyReactor.configuration.logger = original
  end

  def started(reactor_class)
    test_reactor(reactor_class, {}, process_jobs: false).tap(&:run)
  end

  def record(subject, name = "QueueFixtures::Main")
    storage.retrieve_run_dispatch(subject.reactor_instance.context.context_id, name)
  end

  def status(klass, subject)
    klass.find(subject.reactor_instance.context.context_id).context.status.to_s
  end

  for_each_async_backend do
    it "records the queue a hop waits on, logs the hop, and stays running" do
      subject = started(QueueFixtures::Main)
      QueueProbe.next_job.perform!

      expect(record(subject)["queue"]).to eq("stripe")
      expect(record(subject)["since"]).not_to be_empty
      expect(status(QueueFixtures::Main, subject)).to eq("running")
      expect(log.string).to include('event="ruby_reactor.queue.hop"', 'from="main"', 'to="stripe"',
                                    'direction="forward"')
    end

    it "is never failed while it waits, however many sweeps pass" do
      subject = started(QueueFixtures::Main)
      QueueProbe.next_job.perform!

      2.times { RubyReactor::Sweeper.run_once }
      expect(status(QueueFixtures::Main, subject)).to eq("running")
      expect(log.string).to include("event=ruby_reactor.queue.waiting", 'queue="stripe"')
    end

    it "is no longer waiting once a job on that queue picks it up" do
      subject = started(QueueFixtures::Main)
      QueueProbe.next_job.perform!
      job = QueueFixtures.jobs_on(:stripe).first
      RubyReactor::RSpec::AsyncTestHelpers.pending_async_jobs.each { |pending| pending.perform! unless pending == job }
      job.perform!

      expect(record(subject)["queue"]).to eq("main")
      QueueFixtures.jobs_on(:main).first.perform!
      expect(record(subject)["since"]).to eq("")
      expect(subject).to be_success
    end

    it "shows a rolling-back run waiting on the queue of its next undo" do
      subject = started(QueueFixtures::MainFailing)
      3.times { QueueProbe.next_job.perform! }

      expect(status(QueueFixtures::MainFailing, subject)).to eq("rolling_back")
      expect(record(subject, "QueueFixtures::MainFailing")["queue"]).to eq("stripe")
      expect(record(subject, "QueueFixtures::MainFailing")["since"]).not_to be_empty
    end
  end
end
