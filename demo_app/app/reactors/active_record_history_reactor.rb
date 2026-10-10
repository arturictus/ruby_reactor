# frozen_string_literal: true

# Demonstrates the ActiveRecord storage adapter's history (specs/011 US4): every
# run stays in the database, and the dashboard (or `be_findable_by` in a spec)
# finds runs by input value — `user_id`, never the redacted `card_token`.
# `decline: true` fails :charge after :reserve, so :reserve is undone and the
# failed run is kept in history too.
class ActiveRecordHistoryReactor < RubyReactor::Reactor
  class ReserveStep < RubyReactor::Step
    input :user_id

    def run
      Success(reservation: "res-#{inputs.user_id}")
    end

    # Rolls :reserve back when a later step (:charge) fails.
    def undo
      Rails.logger.info("ActiveRecordHistoryReactor: released reservation for user #{inputs.user_id}")
      Success()
    end
  end

  class ChargeStep < RubyReactor::Step
    input :user_id
    input :card_token
    input :decline, optional: true

    def run
      return Failure("card declined for user #{inputs.user_id}") if inputs.decline

      Success(charged: true, user_id: inputs.user_id)
    end
  end

  input :user_id
  input :card_token, redact: true
  input :decline, optional: true

  step :reserve, ReserveStep do
    argument :user_id, input(:user_id)
  end

  step :charge, ChargeStep do
    argument :user_id, input(:user_id)
    argument :card_token, input(:card_token)
    argument :decline, input(:decline)
    wait_for :reserve
  end

  returns :charge
end
