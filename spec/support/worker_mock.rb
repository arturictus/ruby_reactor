# frozen_string_literal: true

module Support
  class WorkerMock
    def self.perform_async(serialized_context, reactor_class_name = nil)
      warn "[WORKER_MOCK] perform_async CALLED"
      # Execute inline by calling Worker.perform which returns an Executor or Failure
      warn "[WORKER_MOCK] About to call perform"
      result = perform(serialized_context, reactor_class_name)
      warn "[WORKER_MOCK] perform returned: #{result.class}"

      # If the result is RetryQueuedResult, simulate requeue by executing again
      while result.is_a?(RubyReactor::RetryQueuedResult)
        warn "[WORKER_MOCK] Got RetryQueuedResult, simulating requeue"
        result = perform(serialized_context, reactor_class_name)
        warn "[WORKER_MOCK] Re-executed, got: #{result.class}"
      end

      if result.is_a?(RubyReactor::Executor)
        warn "[WORKER_MOCK] Executor trace length: #{result.context.execution_trace.length}"
        warn "[WORKER_MOCK] Executor trace: #{result.context.execution_trace.map do |t|
          "#{t[:type]}:#{t[:step]}"
        end.join(", ")}"
      end

      warn "[WORKER_MOCK] Returning result"
      result
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
      context = RubyReactor::ContextSerializer.deserialize(serialized_context)
      context.test_mode = true
      serialized_context = RubyReactor::ContextSerializer.serialize(context)
      result = RubyReactor::Worker.new.perform(serialized_context, reactor_class_name)
      puts "[WORKER_MOCK.perform] Returning result: #{result.class}, result.result: #{result.result&.class}"
      result
    end

    def self.perform_map_element_async(map_id:, element_id:, index:, serialized_inputs:, reactor_class_info:,
                                       strict_ordering:, parent_context_id:, parent_reactor_class_name:, step_name:)
      warn "[WORKER_MOCK] perform_map_element_async CALLED"
      job_id = RubyReactor::MapElementWorker.perform_async(
        map_id, element_id, index, serialized_inputs, reactor_class_info, strict_ordering, parent_context_id, parent_reactor_class_name, step_name
      )
      RubyReactor::AsyncResult.new(job_id: job_id)
    end

    def self.perform_map_collection_async(parent_context_id:, map_id:, parent_reactor_class_name:, step_name:,
                                          strict_ordering:, timeout:)
      warn "[WORKER_MOCK] perform_map_collection_async CALLED"
      job_id = RubyReactor::MapCollectorWorker.perform_async(
        parent_context_id, map_id, parent_reactor_class_name, step_name, strict_ordering, timeout
      )
      RubyReactor::AsyncResult.new(job_id: job_id)
    end

    def self.perform_map_execution_async(map_id:, serialized_inputs:, reactor_class_info:, strict_ordering:,
                                         parent_context_id:, parent_reactor_class_name:, step_name:)
      warn "[WORKER_MOCK] perform_map_execution_async CALLED"
      job_id = RubyReactor::MapExecutionWorker.perform_async(
        map_id, serialized_inputs, reactor_class_info, strict_ordering, parent_context_id, parent_reactor_class_name, step_name
      )
      RubyReactor::AsyncResult.new(job_id: job_id)
    end
  end
end
