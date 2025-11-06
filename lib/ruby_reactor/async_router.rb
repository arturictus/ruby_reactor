# frozen_string_literal: true

module RubyReactor
  class AsyncRouter
    def self.perform_async(serialized_context, reactor_class_name = nil)
      # Mock implementation of perform_async
      Worker.perform_async(serialized_context, reactor_class_name)
      RubyReactor::AsyncResult.new(job_id: nil) # TODO: Get job ID from Sidekiq
    end

    def self.perform_in(delay, serialized_context, reactor_class_name = nil)
      # Mock implementation of perform_in
      Worker.perform_in(delay, serialized_context, reactor_class_name)
      RubyReactor::AsyncResult.new(job_id: nil) # TODO: Get job ID from Sidekiq
    end
  end
end
