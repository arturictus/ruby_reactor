# frozen_string_literal: true

module RubyReactor
  module SidekiqWorkers
    class MapElementWorker
      include ::Sidekiq::Worker

      def perform(arguments)
        RubyReactor::Map::ElementExecutor.perform(arguments)
      end
    end
  end
end
