# frozen_string_literal: true

module RubyReactor
  module Adapters
    module ActiveJob
      # `Sidekiq::Worker` gives every job class `.perform_async` / `.perform_in`
      # for free; ActiveJob only has `.perform_later`. Extending this onto an
      # ActiveJob class normalizes its enqueue API to the same two class
      # methods, so `RubyReactor::Worker` and `RubyReactor::SweeperJob` can keep
      # calling `self.class.perform_in(...)` unchanged regardless of backend.
      # Both methods return the job id (a String), matching what Sidekiq's
      # native `perform_async`/`perform_in` return.
      module Compat
        def perform_async(*args)
          perform_later(*args).job_id
        end

        def perform_in(delay, *args)
          set(wait: delay).perform_later(*args).job_id
        end
      end
    end
  end
end
