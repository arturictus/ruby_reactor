# frozen_string_literal: true

module RubyReactor
  class Context
    attr_accessor :inputs, :intermediate_results, :private_data, :current_step, :retry_count, :concurrency_key,
                  :retry_context, :reactor_class, :execution_trace, :inline_async_execution, :undo_stack, :test_mode,
                  :parent_context, :root_context, :composed_contexts, :context_id, :map_operations, :map_metadata,
                  :cancelled, :cancellation_reason, :parent_context_id

    def initialize(inputs = {}, reactor_class = nil)
      @context_id = SecureRandom.uuid
      @inputs = inputs
      @intermediate_results = {}
      @private_data = {}
      @composed_contexts = {}
      @map_operations = {}
      @map_metadata = nil
      @current_step = nil
      @retry_count = 0
      @concurrency_key = nil
      @retry_context = RetryContext.new
      @reactor_class = reactor_class
      @execution_trace = []
      @inline_async_execution = false # Flag to prevent nested async calls
      @undo_stack = [] # Initialize the undo stack
      @test_mode = false
      @cancelled = false
      @cancellation_reason = nil
      @parent_context = nil
      @parent_context_id = nil
      @root_context = nil
    end

    def get_input(name, path = nil)
      value = @inputs[name.to_sym] || @inputs[name.to_s]
      return nil if value.nil?

      if path
        extract_path(value, path)
      else
        value
      end
    end
    alias input get_input

    def get_result(step_name, path = nil)
      value = @intermediate_results[step_name.to_sym] || @intermediate_results[step_name.to_s]
      return nil if value.nil?

      if path
        extract_path(value, path)
      else
        value
      end
    end
    alias result get_result

    def set_result(step_name, value)
      @intermediate_results[step_name.to_sym] = value
    end

    def with_step(step_name)
      old_step = @current_step
      @current_step = step_name
      yield
    ensure
      @current_step = old_step
    end

    def to_h
      {
        inputs: @inputs,
        intermediate_results: @intermediate_results,
        composed_contexts: @composed_contexts,
        map_operations: @map_operations,
        map_metadata: @map_metadata,
        current_step: @current_step,
        retry_count: @retry_count,
        retry_context: @retry_context,
        reactor_class: @reactor_class,
        execution_trace: @execution_trace,
        test_mode: @test_mode
      }
    end

    def serialize_for_retry(job_id: nil, started_at: nil)
      {
        job_id: job_id,
        context_id: @context_id,
        started_at: (started_at || Time.now).iso8601,
        reactor_class: @reactor_class&.name,
        inputs: ContextSerializer.serialize_value(@inputs),
        intermediate_results: ContextSerializer.serialize_value(@intermediate_results),
        private_data: ContextSerializer.serialize_value(@private_data),
        composed_contexts: ContextSerializer.serialize_value(@composed_contexts),
        map_operations: ContextSerializer.serialize_value(@map_operations),
        map_metadata: ContextSerializer.serialize_value(@map_metadata),
        current_step: @current_step,
        retry_count: @retry_count,
        concurrency_key: @concurrency_key,
        retry_context: @retry_context.serialize_for_retry,
        execution_trace: ContextSerializer.serialize_value(@execution_trace),
        undo_stack: serialize_undo_stack,
        test_mode: @test_mode,
        cancelled: @cancelled,
        cancellation_reason: @cancellation_reason,
        parent_context_id: @parent_context&.context_id || @parent_context_id
      }
    end

    def self.deserialize_from_retry(data)
      context = new
      context.context_id = data["context_id"] if data["context_id"]
      context.reactor_class = resolve_reactor_class(data["reactor_class"])
      context.inputs = ContextSerializer.deserialize_value(data["inputs"]) || {}
      context.intermediate_results = ContextSerializer.deserialize_value(data["intermediate_results"]) || {}
      context.private_data = ContextSerializer.deserialize_value(data["private_data"]) || {}
      context.composed_contexts = ContextSerializer.deserialize_value(data["composed_contexts"]) || {}
      context.map_operations = ContextSerializer.deserialize_value(data["map_operations"]) || {}
      context.map_metadata = ContextSerializer.deserialize_value(data["map_metadata"])
      context.current_step = data["current_step"]&.to_sym
      context.retry_count = data["retry_count"] || 0
      context.concurrency_key = data["concurrency_key"]
      context.retry_context = RetryContext.deserialize_from_retry(data["retry_context"] || {})
      context.execution_trace = ContextSerializer.deserialize_value(data["execution_trace"]) || []
      context.undo_stack = deserialize_undo_stack(data["undo_stack"] || [], context.reactor_class)
      context.test_mode = data["test_mode"] || false
      context.cancelled = data["cancelled"] || false
      context.cancellation_reason = data["cancellation_reason"]
      context.parent_context_id = data["parent_context_id"]

      context
    end

    def self.resolve_reactor_class(name)
      return nil unless name

      begin
        Object.const_get(name)
      rescue NameError
        # Try finding in registry for anonymous classes
        RubyReactor::Registry.find(name)
      end
    end

    private

    def extract_path(value, path)
      if path.is_a?(Symbol) && value.respond_to?(:[])
        value[path]
      elsif path.is_a?(String)
        path.split(".").reduce(value) { |v, key| v&.send(:[], key) }
      elsif path.is_a?(Array)
        path.reduce(value) { |v, key| v&.send(:[], key) }
      elsif value.respond_to?(path)
        value.send(path)
      end
    end

    def serialize_undo_stack
      @undo_stack.map do |item|
        {
          step_name: item[:step].name,
          arguments: ContextSerializer.serialize_value(item[:arguments]),
          result: ContextSerializer.serialize_value(item[:result])
        }
      end
    end

    def self.deserialize_undo_stack(data, reactor_class)
      return [] unless reactor_class

      data.map do |item|
        step_config = reactor_class.steps[item["step_name"].to_sym]
        next nil unless step_config

        {
          step: step_config,
          arguments: ContextSerializer.deserialize_value(item["arguments"]),
          result: ContextSerializer.deserialize_value(item["result"])
        }
      end.compact
    end

    private_class_method :deserialize_undo_stack
  end
end
