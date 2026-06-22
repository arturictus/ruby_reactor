# frozen_string_literal: true

require "active_job"

module RubyReactor
  module Adapters
    module ActiveJob
      class SweeperWorker < ::ActiveJob::Base
        extend Compat
        include RubyReactor::SweeperJob

        queue_as { RubyReactor.configuration.queue_name }
      end
    end
  end
end
