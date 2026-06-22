# frozen_string_literal: true

require "active_job"

module RubyReactor
  module Adapters
    module ActiveJob
      class MapElementWorker < ::ActiveJob::Base
        extend Compat

        queue_as { RubyReactor.configuration.queue_name }

        def perform(arguments)
          RubyReactor::Map::ElementExecutor.perform(arguments)
        end
      end
    end
  end
end
