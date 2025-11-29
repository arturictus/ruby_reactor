# frozen_string_literal: true

require "sidekiq"

module RubyReactor
  module SidekiqWorkers
    class MapExecutionWorker
      include ::Sidekiq::Worker

      def perform(arguments)
        RubyReactor::Map::Execution.perform(arguments)
      end
    end
  end
end
