# frozen_string_literal: true

module RubyReactor
  module Adapters
    module Sidekiq
      # Rolls back one element of a fan-out map (009 R-07).
      class MapElementRollbackWorker
        include ::Sidekiq::Worker

        def perform(arguments)
          RubyReactor::Map::ElementRollback.perform(arguments)
        end
      end
    end
  end
end
