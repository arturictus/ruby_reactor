# frozen_string_literal: true

require "active_job"

module RubyReactor
  module Adapters
    module ActiveJob
      # Rolls back one element of a fan-out map (009 R-07).
      class MapElementRollbackWorker < ::ActiveJob::Base
        extend Compat

        queue_as { RubyReactor.configuration.queue_name }

        def perform(arguments)
          RubyReactor::Map::ElementRollback.perform(arguments)
        end
      end
    end
  end
end
