# frozen_string_literal: true

module RubyReactor
  module Adapters
    module Sidekiq
      class MapElementWorker
        include ::Sidekiq::Worker

        def perform(arguments)
          RubyReactor::Map::ElementExecutor.perform(arguments)
        end
      end
    end
  end
end
