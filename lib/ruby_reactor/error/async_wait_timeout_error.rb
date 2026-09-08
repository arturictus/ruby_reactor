# frozen_string_literal: true

module RubyReactor
  module Error
    # Raised when a notified wait on an `async_step` / `async_reactor`
    # result exceeds `Configuration#async_wait_timeout`. Never an unbounded wait.
    class AsyncWaitTimeoutError < Base
    end
  end
end
