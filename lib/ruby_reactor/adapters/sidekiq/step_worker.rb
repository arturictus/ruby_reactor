# frozen_string_literal: true

module RubyReactor
  module Adapters
    module Sidekiq
      # One dispatched `async_step`, mirroring MapElementWorker: the backend
      # binding only, all behavior in the shared `RubyReactor::StepWorker`.
      class StepWorker
        include ::Sidekiq::Worker

        def perform(arguments)
          RubyReactor::StepWorker.perform(arguments)
        end
      end
    end
  end
end
