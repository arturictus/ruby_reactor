module Support
  class WorkerMock
    def self.perform_async(serialized_context, reactor_class_name = nil)
      # Mock implementation of perform_async
      perform(serialized_context, reactor_class_name)
    end

    def self.perform_in(_delay, serialized_context, reactor_class_name = nil)
      # Mock implementation of perform_in
      perform(serialized_context, reactor_class_name)
    end

    def self.perform(serialized_context, reactor_class_name = nil)
      RubyReactor::Worker.new.perform(serialized_context, reactor_class_name)
    end
  end
end
