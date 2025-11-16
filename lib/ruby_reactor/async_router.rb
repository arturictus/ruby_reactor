# frozen_string_literal: true

module RubyReactor
  class AsyncRouter
    def self.perform_async(serialized_context, reactor_class_name = nil)
      # Mock implementation of perform_async
      job_id = Worker.perform_async(serialized_context, reactor_class_name)
      RubyReactor::AsyncResult.new(job_id: job_id)
    end

    def self.perform_in(delay, serialized_context, reactor_class_name = nil)
      # Mock implementation of perform_in
      job_id = Worker.perform_in(delay, serialized_context, reactor_class_name)
      RubyReactor::AsyncResult.new(job_id: job_id)
    end
  end
end
