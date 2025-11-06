module Support
  class WorkerMock
    def self.perform_async(serialized_context, reactor_class_name = nil)
      # Execute inline by calling Worker.perform which returns an Executor
      perform(serialized_context, reactor_class_name)

      # For test purposes, we want to return the executor so the original
      # execution can integrate the results
      # This mimics async behavior but executes inline
    end

    def self.perform_in(_delay, serialized_context, reactor_class_name = nil)
      # Mock implementation of perform_in - same as perform_async for testing
      perform_async(serialized_context, reactor_class_name)
    end

    def self.perform(serialized_context, reactor_class_name = nil)
      RubyReactor::Worker.new.perform(serialized_context, reactor_class_name)
    end
  end
end
