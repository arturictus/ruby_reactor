# frozen_string_literal: true

module RubyReactor
  module SidekiqWorkers
    class MapCollectorWorker
      include ::Sidekiq::Worker

      def perform(arguments)
        RubyReactor::Map::Collector.perform(arguments)
      end
    end
  end
end
