module Support
  class WorkerMock
    def self.perform_async(serialized_context, reactor_class_name = nil)
      warn "[WORKER_MOCK] perform_async CALLED"
      # Execute inline by calling Worker.perform which returns an Executor
      warn "[WORKER_MOCK] About to call perform"
      executor = perform(serialized_context, reactor_class_name)
      warn "[WORKER_MOCK] perform returned: #{executor.class}"
      warn "[WORKER_MOCK] Executor trace length: #{executor.context.execution_trace.length}"
      warn "[WORKER_MOCK] Executor trace: #{executor.context.execution_trace.map do |t|
        "#{t[:type]}:#{t[:step]}"
      end.join(", ")}"
      warn "[WORKER_MOCK] Returning executor"
      executor
    rescue StandardError => e
      warn "[WORKER_MOCK] EXCEPTION: #{e.class}: #{e.message}"
      warn e.backtrace.first(5).join("\n")
      raise
    end

    def self.perform_in(_delay, serialized_context, reactor_class_name = nil)
      # Mock implementation of perform_in - same as perform_async for testing
      perform_async(serialized_context, reactor_class_name)
    end

    def self.perform(serialized_context, reactor_class_name = nil)
      executor = RubyReactor::Worker.new.perform(serialized_context, reactor_class_name)
      puts "[WORKER_MOCK.perform] Returning executor: #{executor.class}"
      executor
    end
  end
end
