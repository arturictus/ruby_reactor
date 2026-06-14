require "rails_helper"

RSpec.describe LedgerTransactionReactor, type: :reactor do
  before { described_class::Ledger.reset! }

  def enqueue_tx(account_id, transaction, **opts)
    test_reactor(
      described_class,
      { account_id: account_id, transaction: transaction },
      process_jobs: false,
      **opts
    ).run
  end

  describe "happy path" do
    let(:account_id) { "acct_1" }

    it "assigns a nonce per call inside Reactor.run" do
      enqueue_tx(account_id, { amount: 10, type: "credit" })
      enqueue_tx(account_id, { amount: 20, type: "debit" })

      key = "ledger:#{account_id}"
      expect(key).to have_ordered_lock_next(2)
      expect(key).to have_ordered_lock_in_flight(1, 2)
    end

    it "applies transactions in submission order when drained" do
      [
        { amount: 100, type: "credit" },
        { amount: 25,  type: "debit" },
        { amount: 50,  type: "credit" }
      ].each { |tx| enqueue_tx(account_id, tx) }

      drain_async_jobs

      entries = described_class::Ledger.for(account_id)
      expect(entries.map { |e| e[:nonce] }).to eq([1, 2, 3])
      expect(entries.map { |e| e[:amount] }).to eq([100, 25, 50])
    end

    it "drains the counter once all transactions complete" do
      2.times { enqueue_tx(account_id, { amount: 1, type: "credit" }) }
      drain_async_jobs

      expect("ledger:#{account_id}").to be_ordered_lock_drained
    end

    it "restarts at nonce 1 after a clean drain" do
      enqueue_tx(account_id, { amount: 5, type: "credit" })
      drain_async_jobs

      enqueue_tx(account_id, { amount: 7, type: "debit" })
      expect("ledger:#{account_id}").to have_ordered_lock_next(1)
    end
  end

  describe "ordering enforcement" do
    let(:account_id) { "acct_2" }

    it "snoozes a job whose nonce is ahead of last_completed + 1" do
      RubyReactor.configuration.lock_snooze_base_delay = 0.01
      RubyReactor.configuration.lock_snooze_jitter = 0

      enqueue_tx(account_id, { amount: 1, type: "credit" }) # nonce 1
      enqueue_tx(account_id, { amount: 2, type: "credit" }) # nonce 2

      jobs = pending_async_jobs
      expect(jobs.size).to eq(2)

      # Run only nonce 2 — it should snooze (re-enqueue) because nonce 1 hasn't applied.
      jobs.last.perform!

      expect(described_class::Ledger.for(account_id)).to be_empty
      expect("ledger:#{account_id}").to have_ordered_lock_last_completed(0)
      expect(pending_async_jobs.size).to eq(2)
    end
  end

  describe "scoping" do
    it "uses an independent counter per account" do
      enqueue_tx("acct_a", { amount: 1, type: "credit" })
      enqueue_tx("acct_b", { amount: 2, type: "debit" })

      expect("ledger:acct_a").to have_ordered_lock_next(1)
      expect("ledger:acct_b").to have_ordered_lock_next(1)
    end
  end
end
