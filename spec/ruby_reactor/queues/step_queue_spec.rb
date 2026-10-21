# frozen_string_literal: true

require "spec_helper"

# 011 US3: steps declare their own queue. An `async_step`'s job (and its
# recovery) and an `async_reactor` child's jobs use it; a plain step hops to it
# for its run, retries and undo.
RSpec.describe "step queues (US3)", type: :reactor do
  def perform_all(limit: 50)
    count = 0
    while (job = QueueProbe.next_job)
      job.perform!
      count += 1
      raise "more than #{limit} jobs" if count > limit
    end
    count
  end

  def started(reactor_class, inputs = {})
    test_reactor(reactor_class, inputs, process_jobs: false).tap(&:run)
  end

  def step_jobs
    pending_async_jobs.select { |job| job.worker_class.name.end_with?("::StepWorker") }
  end

  def delete_job(job)
    if async_backend == :sidekiq
      job.worker_class.jobs.delete(job.raw)
    else
      ActiveJob::Base.queue_adapter.enqueued_jobs.delete(job.raw)
    end
  end

  def run_entry(context, step)
    context.execution_trace.find { |entry| entry[:type].to_s == "run" && entry[:step].to_s == step }
  end

  before do
    QueueFixtures::AnotherStep.fail_times = 0
    stub_const("AsyncChildRun", Class.new(RollbackRecorder::Reactor) do
      tag "m"
      queue :main
      recording_step :first
      async_reactor :child, QueueFixtures::Stripe
      async_reactor :plain_child, QueueFixtures::Undeclared
    end)
    stub_const("AnotherInCaller", Class.new(RollbackRecorder::Reactor) do
      tag "m"
      queue :main
      recording_step :first
      step(:another, QueueFixtures::AnotherStep) { wait_for :first }
      recording_step :after, after: :another
      background after: :another
    end)
    stub_const("AnotherRetrying", Class.new(RollbackRecorder::Reactor) do
      tag "m"
      queue :main
      recording_step :first
      recording_step :pre, after: :first
      step(:another, QueueFixtures::AnotherStep) do
        wait_for :pre
        retries max_attempts: 2, backoff: :fixed, base_delay: 0
      end
      background after: :first
    end)
  end

  after { QueueFixtures::AnotherStep.fail_times = 0 }

  for_each_async_backend do
    describe "async_step and async_reactor" do
      it "dispatches each async_step on its queue while the parent continues on its own (AS1-AS3)" do
        subject = started(QueueFixtures::MainSteps)
        QueueProbe.next_job.perform!

        expect(step_jobs.map(&:queue)).to contain_exactly("emails", "priority_emails", "main")
        expect(QueueFixtures.jobs_on(:another_one).size).to eq(1)

        perform_all
        expect(subject).to be_success
        expect(subject).to have_run_step(:email).on_queue(:emails)
        expect(subject).to have_run_step(:priority_email).on_queue(:priority_emails)
        expect(subject).to have_run_step(:plain_async).on_queue(:main)
        expect(subject.async_step(:email, :queue)).to eq("emails")
      end

      it "recovers a lost async_step job onto its queue (AS4)" do
        started(QueueFixtures::MainSteps)
        QueueProbe.next_job.perform!
        delete_job(step_jobs.find { |job| job.queue == "emails" })

        # Every dispatched unit without a live worker looks lost (its queued job
        # included), and each is re-dispatched to its own queue.
        expect(RubyReactor::StepSweeper.run_once).to be >= 1
        expect(step_jobs.map(&:queue)).to include("emails")
      end

      it "runs an async_reactor child on its own queue, and an undeclared one on the parent's (AS5)" do
        subject = started(AsyncChildRun)
        expect(QueueFixtures.queues_of_pending).to contain_exactly("stripe", "main")

        perform_all
        expect(subject).to be_success
        refs = subject.reactor_instance.context.composed_contexts
        child = QueueFixtures::Stripe.find((refs[:child] || refs["child"])[:execution_id]).context
        plain = QueueFixtures::Undeclared.find((refs[:plain_child] || refs["plain_child"])[:execution_id]).context
        expect(run_entry(child, "one")[:queue]).to eq("stripe")
        expect(run_entry(plain, "u1")[:queue]).to eq("main")
      end
    end

    describe "a plain step on its own queue" do
      it "hops out for the step and back for the next one (AS6)" do
        subject = started(QueueFixtures::MainSteps)
        perform_all

        expect(subject).to be_success
        expect(subject).to have_hopped_queues(:another_one, :main)
        expect(subject).to have_run_step(:another).on_queue(:another_one)
        expect(subject).to have_run_step(:after_another).on_queue(:main)
      end

      it "runs in the calling process before the background point, creating no job for its queue (AS7)" do
        subject = started(AnotherInCaller)

        expect(run_entry(subject.reactor_instance.context, "another")).not_to have_key(:queue)
        expect(QueueFixtures.queues_of_pending).to eq(["main"])
        perform_all
        expect(subject).to have_hopped_queues
      end

      it "requeues its retry on its queue (AS8)" do
        QueueFixtures::AnotherStep.fail_times = 1
        subject = started(AnotherRetrying)
        QueueProbe.next_job.perform! # main: :pre, hop
        QueueProbe.next_job.perform! # another_one: fails once, requeued

        expect(QueueFixtures.queues_of_pending).to eq(["another_one"])
        perform_all
        expect(subject).to be_success
        expect(QueueFixtures.count("run:another")).to eq(2)
      end

      it "undoes it on its queue when a later step fails (AS9)" do
        subject = started(QueueFixtures::MainStepsFailing)
        perform_all

        expect(subject).to be_failure
        expect(subject).to have_undone_step(:another).on_queue(:another_one)
        expect(subject).to have_undone_step(:pre).on_queue(:main)
      end
    end
  end
end
