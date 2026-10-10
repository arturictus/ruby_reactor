# frozen_string_literal: true

require "spec_helper"

# 010 US4 (FR-015, FR-016, R-04, P-3): of two resumes of one interrupt at the
# same instant, exactly one is accepted, in every execution mode. The claim
# (`SET NX`) decides; the per-run lock is not needed for it.
RSpec.describe "Two resumes of one interrupt at the same instant (010 US4)" do
  let(:storage) { RubyReactor.configuration.storage_adapter }
  let(:rejected) { /already resumed|completed, not paused/ }

  def pause(klass)
    reactor = klass.new
    expect(reactor.run({})).to be_a(RubyReactor::InterruptResult)
    reactor.context.context_id
  end

  # Both threads call `continue` once a barrier releases them together.
  def race(klass, id)
    barrier = ResumeFixtures.barrier(2)
    [{ ok: true }, { ok: false }].map do |payload|
      Thread.new do
        barrier.wait
        klass.continue(id: id, payload: payload, step_name: :approval)
        [:accepted, payload]
      rescue RubyReactor::Error::ValidationError => e
        [:rejected, e.message]
      end
    end.map(&:value)
  end

  def expect_one_winner(klass, id, outcomes)
    accepted, losers = outcomes.partition { |kind, _| kind == :accepted }
    expect(accepted.size).to eq(1)
    expect(losers.first.last).to match(rejected)
    winner = accepted.first.last
    expect(klass.find(id).context.get_result(:approval)).to eq(winner)
    claim = storage.retrieve_interrupt_resumes(id, klass.name, ["approval"])["approval"]
    expect(RubyReactor::ContextSerializer.deserialize_value(JSON.parse(claim))).to eq(winner)
  end

  it "accepts exactly one of two simultaneous resumes, every time" do
    200.times do
      id = pause(ResumeFixtures::PlainApproval)

      expect_one_winner(ResumeFixtures::PlainApproval, id, race(ResumeFixtures::PlainApproval, id))
    end

    expect(RollbackRecorder.log.count("run:c")).to eq(200)
  end

  it "enqueues exactly one worker for a background-resume interrupt" do
    id = pause(ResumeFixtures::BackgroundApproval)

    outcomes = race(ResumeFixtures::BackgroundApproval, id)

    expect(outcomes.count { |kind, _| kind == :accepted }).to eq(1)
    expect(QueueProbe.pending.size).to eq(1)
  end

  # The one justified `Sidekiq::Testing.inline!` example (plan.md Complexity
  # Tracking, FR-016, R-14): inline mode takes no run lock, so before 010 two
  # resumes that both read `paused` both ran. Fake mode cannot show it — the
  # run lock is taken there, and it hid the race.
  context "with Sidekiq::Testing.inline!" do
    around { |example| Sidekiq::Testing.inline! { example.run } }

    it "still accepts exactly one" do
      50.times do
        id = pause(ResumeFixtures::PlainApproval)

        expect_one_winner(ResumeFixtures::PlainApproval, id, race(ResumeFixtures::PlainApproval, id))
      end

      expect(RollbackRecorder.log.count("run:c")).to eq(50)
    end
  end
end
