# frozen_string_literal: true

# Demonstrates `retries` on a `compose`: the child reserves a seat (with an
# `undo`) and then confirms it; the first confirmation fails.
#
#   attempt 1: reserve -> confirm fails -> the child releases the seat
#   attempt 2: a FRESH child: reserve again -> confirm succeeds
#
# The seat is reserved on both attempts: a retry never counts rolled-back work
# as done. Log helpers live on the parent reactor: Zeitwerk only autoloads the
# constant matching this file's name.
class ComposeRetryReserveStep < RubyReactor::Step
  input :seat, :string

  def run
    ComposeRetryDemoReactor.log << "reserve #{inputs.seat}"
    Success(reservation: "res_#{inputs.seat}_#{ComposeRetryDemoReactor.log.count { |l| l.start_with?("reserve") }}")
  end

  def undo
    ComposeRetryDemoReactor.log << "release #{inputs.seat}"
    Success()
  end
end

class ComposeRetryConfirmStep < RubyReactor::Step
  input :reservation, :hash

  def run
    ComposeRetryDemoReactor.confirm_calls += 1
    ComposeRetryDemoReactor.log << "confirm #{inputs.reservation[:reservation]}"
    return Failure("confirmation service timed out") if ComposeRetryDemoReactor.confirm_calls == 1

    Success(confirmed: inputs.reservation[:reservation])
  end
end

class ComposeRetryReservationReactor < RubyReactor::Reactor
  input :seat, :string

  step :reserve, ComposeRetryReserveStep do
    argument :seat, input(:seat)
  end

  step :confirm, ComposeRetryConfirmStep do
    argument :reservation, result(:reserve)
  end

  returns :confirm
end

class ComposeRetryDemoReactor < RubyReactor::Reactor
  class << self
    attr_writer :confirm_calls

    def log
      @log ||= []
    end

    def confirm_calls
      @confirm_calls ||= 0
    end

    def reset!
      @log = []
      @confirm_calls = 0
    end
  end

  input :seat, :string

  compose :reservation, ComposeRetryReservationReactor do
    argument :seat, input(:seat)
    retries max_attempts: 2, base_delay: 0
  end

  returns :reservation
end
