# frozen_string_literal: true

require "spec_helper"

# 010 US3 (FR-008–FR-014, R-05, P-2): a valid resume that meets the reactor's
# held lock or semaphore is accepted and handed to a worker, never lost.
RSpec.describe "A resume contended on the reactor's lock or semaphore (010 US3)" do
  let(:logger) { RubyReactor.configuration.logger }

  before { allow(logger).to receive(:info).and_call_original }

  def pause(klass)
    reactor = klass.new
    expect(reactor.run({})).to be_a(RubyReactor::InterruptResult)
    reactor.context.context_id
  end

  def status(klass, id)
    klass.find(id).context.status.to_s
  end

  def drain
    RubyReactor::RSpec::AsyncTestHelpers.drain_async_jobs
  end

  def with_lock_held(key)
    lock = RubyReactor::Lock.new(key, owner: "another-run", ttl: 30, auto_extend: false)
    lock.acquire
    yield
  ensure
    lock&.release
  end

  for_each_async_backend do
    let(:klass) { ResumeFixtures::LockedApproval }

    it "accepts a valid resume, hands it to a worker, and finishes once the lock is released" do
      id = pause(klass)

      result = with_lock_held("resume-fx:locked") do
        klass.continue(id: id, payload: { ok: true }, step_name: :approval)
      end

      expect(result).to be_a(RubyReactor::DispatchResult)
      expect(result.execution_id).to eq(id)
      expect(status(klass, id)).to eq("running")
      expect(logger).to have_received(:info)
        .with(/event="ruby_reactor.resume.deferred".*context_id="#{id}".*step="approval".*reason="lock"/)
      expect(logger).to have_received(:info).with(/resume.deferred.*key="resume-fx:locked"/)
      expect(QueueProbe.pending.size).to eq(1)

      drain
      expect(status(klass, id)).to eq("completed")
      expect(klass.find(id).context.get_result(:approval)).to eq(ok: true)
      expect(RollbackRecorder.log).to eq(%w[run:a run:c])
    end

    it "answers an invalid payload with its validation failure, storing and enqueuing nothing" do
      id = pause(klass)
      storage = RubyReactor.configuration.storage_adapter

      with_lock_held("resume-fx:locked") do
        expect { klass.continue(id: id, payload: { ok: "nope" }, step_name: :approval) }
          .to raise_error(RubyReactor::Error::InputValidationError)
        instance = klass.find(id).continue(payload: { ok: "nope" }, step_name: :approval)
        expect(instance).to be_failure
        expect(instance.invalid_payload?).to be(true)
      end

      expect(status(klass, id)).to eq("paused")
      expect(QueueProbe.pending).to be_empty
      expect(storage.retrieve_interrupt_resumes(id, "ResumeFixtures::LockedApproval", ["approval"])).to eq({})
    end

    it "rejects a second resume of the same interrupt while the first waits" do
      id = pause(klass)

      with_lock_held("resume-fx:locked") do
        klass.continue(id: id, payload: { ok: true }, step_name: :approval)
        expect { klass.continue(id: id, payload: { ok: false }, step_name: :approval) }
          .to raise_error(RubyReactor::Error::ValidationError, /already resumed|running/)
      end

      drain
      expect(klass.find(id).context.get_result(:approval)).to eq(ok: true)
    end

    it "does nothing when the run is cancelled before the worker gets it" do
      id = pause(klass)
      with_lock_held("resume-fx:locked") do
        klass.continue(id: id, payload: { ok: true }, step_name: :approval)
      end

      klass.cancel(id: id, reason: "operator")
      drain

      expect(status(klass, id)).to eq("cancelled")
      expect(RollbackRecorder.log).to eq(%w[run:a])
    end

    context "with a reactor semaphore" do
      let(:klass) { ResumeFixtures::SemaphoredApproval }

      it "defers the same way while every slot is taken" do
        id = pause(klass)
        slot = RubyReactor::Semaphore.new("resume-fx:sem", limit: 1)
        slot.acquire

        result = klass.continue(id: id, payload: { ok: true }, step_name: :approval)

        expect(result).to be_a(RubyReactor::DispatchResult)
        expect(status(klass, id)).to eq("running")
        expect(logger).to have_received(:info).with(/reason="semaphore".*key="resume-fx:sem"/)

        slot.release
        drain
        expect(status(klass, id)).to eq("completed")
      end
    end

    context "with a background-resume interrupt" do
      let(:klass) { ResumeFixtures::BackgroundApproval }

      it "hands off as before, logging the deferral" do
        id = pause(klass)

        result = klass.continue(id: id, payload: { ok: true }, step_name: :approval)

        expect(result).to be_a(RubyReactor::DispatchResult)
        expect(status(klass, id)).to eq("running")
        expect(logger).to have_received(:info).with(/event="ruby_reactor.resume.deferred".*reason="background"/)

        drain
        expect(status(klass, id)).to eq("completed")
        expect(RollbackRecorder.log).to eq(%w[run:a run:c])
      end
    end
  end
end
