# frozen_string_literal: true

module RubyReactor
  class AsyncRouter
    def self.perform_async(serialized_context, reactor_class_name = nil)
      # Mock implementation of perform_async
      job_id = Worker.perform_async(serialized_context, reactor_class_name)
      
      # Extract intermediate_results from context if available
      intermediate_results = extract_intermediate_results(serialized_context)
      
      RubyReactor::AsyncResult.new(job_id: job_id, intermediate_results: intermediate_results)
    end

    def self.perform_in(delay, serialized_context, reactor_class_name = nil)
      # Mock implementation of perform_in
      job_id = Worker.perform_in(delay, serialized_context, reactor_class_name)
      
      # Extract intermediate_results from context if available
      intermediate_results = extract_intermediate_results(serialized_context)
      
      RubyReactor::AsyncResult.new(job_id: job_id, intermediate_results: intermediate_results)
    end

    def self.extract_intermediate_results(serialized_context)
      return {} unless serialized_context.is_a?(String)

      begin
        context_data = JSON.parse(serialized_context)
        intermediate_results_data = context_data["intermediate_results"] || {}
        
        # Deserialize the intermediate_results if they are serialized
        ContextSerializer.deserialize_value(intermediate_results_data)
      rescue JSON::ParserError, StandardError
        {}
      end
    end
    private_class_method :extract_intermediate_results
  end
end
