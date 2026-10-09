# frozen_string_literal: true

require "spec_helper"

# 010 R-04 / DM §2–§3: a resume is claimed per interrupt (SET NX), and only
# the execution that owns the run's lock applies the claimed payload.
RSpec.describe RubyReactor::InterruptClaims do
  let(:storage) { RubyReactor.configuration.storage_adapter }
  let(:klass) { ResumeFixtures::DualApproval }
  let(:klass_name) { "ResumeFixtures::DualApproval" }

  before do
    ResumeFixtures.reset!
    Sidekiq::Worker.clear_all
  end

  def paused_dual
    reactor = klass.new
    expect(reactor.run({})).to be_a(RubyReactor::InterruptResult)
    reactor
  end

  describe "storage" do
    let(:id) { SecureRandom.uuid }

    it "claims an interrupt once, for the context's TTL" do
      expect(storage.claim_interrupt_resume(id, klass_name, :approval, "{}")).to be(true)
      expect(storage.claim_interrupt_resume(id, klass_name, :approval, "{}")).to be(false)

      ttl = redis.ttl("reactor:#{klass_name}:context:#{id}:resume:approval")
      expect(ttl).to be_within(5).of(RubyReactor.configuration.context_ttl)
    end

    it "returns only the claimed steps" do
      storage.claim_interrupt_resume(id, klass_name, :a, '{"x":1}')

      expect(storage.retrieve_interrupt_resumes(id, klass_name, %w[a b])).to eq("a" => '{"x":1}')
    end

    it "counts attempts atomically, with a TTL" do
      expect(storage.increment_interrupt_attempts(id, klass_name, :approval)).to eq(1)
      expect(storage.increment_interrupt_attempts(id, klass_name, :approval)).to eq(2)
      expect(redis.ttl("reactor:#{klass_name}:context:#{id}:resume_attempts:approval")).to be > 0
    end
  end

  describe "claim! / unapplied / apply!" do
    it "stores the payload, lists only interrupts without a result, and applies them" do
      context = paused_dual.context
      expect(described_class.claim!(context, :b, { ok: true })).to be(true)
      expect(described_class.claim!(context, :b, { ok: false })).to be(false)

      expect(described_class.unapplied(context)).to eq(b: { ok: true })
      expect(described_class.apply!(context)).to eq([:b])
      expect(context.get_result(:b)).to eq(ok: true)
      expect(described_class.unapplied(context)).to eq({})
    end

    it "claims, lists and applies an interrupt inside a composed child by its step path" do
      fx = InterruptInComposeFixtures
      RollbackRecorder.reset!
      context = fx::Root.find(fx::Root.run({}).execution_id).context
      path = %i[fulfil approve]

      expect(described_class.claim!(context, path, { ok: true })).to be(true)
      expect(described_class.claim!(context, path, { ok: false })).to be(false)
      expect(described_class.claim!(context, :approve, { ok: false })).to be(true) # a root step of that name is apart

      expect(described_class.unapplied(context)).to eq(path => { ok: true })
      expect(described_class.apply!(context)).to eq([path])
      expect(context.composed_contexts[:fulfil][:context].get_result(:approve)).to eq(ok: true)
      expect(described_class.unapplied(context)).to eq({})
    end

    it "reads nothing for a reactor without interrupts" do
      context = RubyReactor::Context.new({}, ResumeFixtures::SlowSync)
      allow(storage).to receive(:retrieve_interrupt_resumes)

      expect(described_class.unapplied(context)).to eq({})
      expect(storage).not_to have_received(:retrieve_interrupt_resumes)
    end
  end

  describe "applied by the lock owner" do
    # The claim's copy goes through serialization; the process that owns the
    # run hands its step the caller's payload exactly as given, as before 010.
    it "gives an inline resume's step the caller's payload as given, string keys included" do
      context = paused_dual.context

      result = klass.continue(id: context.context_id, payload: { "a" => 1 }, step_name: :a)

      expect(result).to be_a(RubyReactor::InterruptResult) # paused at :b
      expect(result.intermediate_results[:after_a]).to eq("a" => 1)
    end

    it "lets a Worker resume a paused run that has a claim, applying it at resume start" do
      context = paused_dual.context
      described_class.claim!(context, :b, { ok: true })

      RubyReactor::Adapters::Sidekiq::Worker.new.perform(context.context_id, klass_name)

      stored = klass.find(context.context_id).context
      expect(stored.get_result(:b)).to eq(ok: true)
      expect(stored.status.to_s).to eq("paused")
      expect(stored.current_step.to_s).to eq("a")
    end

    it "lets a Worker resume a run paused in a composed child that has a claim on its path" do
      fx = InterruptInComposeFixtures
      RollbackRecorder.reset!
      id = fx::Root.run({}).execution_id
      described_class.claim!(fx::Root.find(id).context, %i[fulfil approve], { ok: true })

      RubyReactor::Adapters::Sidekiq::Worker.new.perform(id, fx::Root.name)

      expect(fx::Root.find(id).context.status.to_s).to eq("completed")
      expect(RollbackRecorder.log).to eq(%w[run:r1 run:child.c1 run:child.c2 run:r2])
    end
  end
end
