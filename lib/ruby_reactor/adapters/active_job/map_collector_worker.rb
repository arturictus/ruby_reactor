# frozen_string_literal: true

require "active_job"

module RubyReactor
  module Adapters
    module ActiveJob
      class MapCollectorWorker < ::ActiveJob::Base
        extend Compat

        queue_as { RubyReactor.configuration.queue_name }

        def perform(arguments)
          RubyReactor::Map::Collector.perform(arguments)
        end
      end
    end
  end
end
