# frozen_string_literal: true

require "active_job"

module RubyReactor
  module Adapters
    module ActiveJob
      # ActiveJob counterpart to Sidekiq::StepWorker — binding only.
      class StepWorker < ::ActiveJob::Base
        extend Compat

        queue_as { RubyReactor.configuration.queue_name }

        def perform(arguments)
          RubyReactor::StepWorker.perform(arguments)
        end
      end
    end
  end
end
