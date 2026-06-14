# frozen_string_literal: true

# Demonstrates `with_ordered_lock`. Three transactions submitted for the same
# account always apply in submission order, even when the Sidekiq worker pool
# dequeues them in a different order.
#
# A monotonically increasing nonce is assigned inside `Reactor.run` (caller
# process) BEFORE the job is enqueued. The worker can only apply its
# transaction when its nonce equals `last_completed + 1`; otherwise it raises
# `RubyReactor::OrderedLock::WaitError` and the worker snoozes via
# `perform_in`. After a full drain, the counter resets to 0 and the next
# batch starts at nonce 1 again.
class LedgerTransactionReactor < RubyReactor::Reactor
  # In-memory append-only log keyed by account_id. Each entry records the
  # nonce assigned at enqueue alongside the applied transaction, so the demo
  # / spec can assert ordering.
  class Ledger
    class << self
      def reset!
        @entries = Hash.new { |h, k| h[k] = [] }
      end

      def append(account_id, entry)
        @entries ||= Hash.new { |h, k| h[k] = [] }
        @entries[account_id] << entry
      end

      def for(account_id)
        (@entries ||= {})[account_id] || []
      end
    end
  end

  async true

  input :account_id do
    required(:account_id).filled(:string)
  end

  input :transaction do
    required(:transaction).hash do
      required(:amount).filled(:integer)
      required(:type).filled(:string, included_in?: %w[credit debit])
    end
  end

  with_ordered_lock(poison_pill_timeout: 60) { |inputs| "ledger:#{inputs[:account_id]}" }

  step :apply do
    argument :account_id, input(:account_id)
    argument :transaction, input(:transaction)

    run do |args, context|
      nonce = context.private_data[:ordered_lock][:nonce] ||
              context.private_data["ordered_lock"]["nonce"]

      Ledger.append(args[:account_id], { nonce: nonce, **args[:transaction] })

      Success(account_id: args[:account_id], nonce: nonce, applied: args[:transaction])
    end
  end

  returns :apply
end
