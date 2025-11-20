# frozen_string_literal: true

module RubyReactor
  class Context
    attr_accessor :inputs, :intermediate_results, :private_data, :current_step, :retry_count, :concurrency_key,
                  :retry_context, :reactor_class, :execution_trace, :inline_async_execution, :undo_stack, :test_mode,
                  :parent_context, :root_context, :composed_contexts, :context_id

    def initialize(inputs = {}, reactor_class = nil)
      @context_id = SecureRandom.uuid
      @inputs = inputs
      @intermediate_results = {}
      @private_data = {}
      @composed_contexts = {}
      @current_step = nil
      @retry_count = 0
      @concurrency_key = nil
      @retry_context = RetryContext.new
      @reactor_class = reactor_class
      @execution_trace = []
      @inline_async_execution = false # Flag to prevent nested async calls
      @undo_stack = [] # Initialize the undo stack
      @test_mode = false
      @parent_context = nil
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

    def get_result(step_name, path = nil)
      value = @intermediate_results[step_name.to_sym] || @intermediate_results[step_name.to_s]
      return nil if value.nil?

      if path
        extract_path(value, path)
      else
        value
      end
    end

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
        inputs: serialize_value(@inputs),
        intermediate_results: serialize_value(@intermediate_results),
        private_data: serialize_value(@private_data),
        composed_contexts: serialize_value(@composed_contexts),
        current_step: @current_step,
        retry_count: @retry_count,
        concurrency_key: @concurrency_key,
        retry_context: @retry_context.serialize_for_retry,
        execution_trace: serialize_value(@execution_trace),
        undo_stack: serialize_undo_stack,
        test_mode: @test_mode
      }
    end

    def self.deserialize_from_retry(data)
      context = new
      context.context_id = data["context_id"] if data["context_id"]
      context.reactor_class = data["reactor_class"] ? Object.const_get(data["reactor_class"]) : nil
      context.inputs = deserialize_value(data["inputs"]) || {}
      context.intermediate_results = deserialize_value(data["intermediate_results"]) || {}
      context.private_data = deserialize_value(data["private_data"]) || {}
      context.composed_contexts = deserialize_value(data["composed_contexts"]) || {}
      context.current_step = data["current_step"]&.to_sym
      context.retry_count = data["retry_count"] || 0
      context.concurrency_key = data["concurrency_key"]
      context.retry_context = RetryContext.deserialize_from_retry(data["retry_context"] || {})
      context.execution_trace = deserialize_value(data["execution_trace"]) || []
      context.undo_stack = deserialize_undo_stack(data["undo_stack"] || [], context.reactor_class)
      context.test_mode = data["test_mode"] || false

      # Reconstruct parent/root relationships if nested contexts exist in private_data
      # This is tricky because private_data is just a hash.
      # We rely on the fact that nested contexts are stored in private_data by ComposeStep
      # But here we just deserialize the values.

      context
    end

    private

    # rubocop:disable Metrics/CyclomaticComplexity, Metrics/MethodLength
    def serialize_value(value)
      case value
      when RubyReactor::Success
        { "_type" => "Success", "value" => serialize_value(value.value) }
      when RubyReactor::Failure
        { "_type" => "Failure", "error" => serialize_value(value.error), "retryable" => value.retryable }
      when RubyReactor::Context
        { "_type" => "Context", "value" => value.serialize_for_retry }
      when Time
        { "_type" => "Time", "value" => value.iso8601 }
      when BigDecimal
        { "_type" => "BigDecimal", "value" => value.to_s("F") }
      when Rational
        { "_type" => "Rational", "numerator" => value.numerator, "denominator" => value.denominator }
      when Date
        { "_type" => "Date", "value" => value.iso8601 }
      when DateTime
        { "_type" => "DateTime", "value" => value.iso8601 }
      when Complex
        { "_type" => "Complex", "real" => value.real, "imag" => value.imag }
      when Range
        { "_type" => "Range", "begin" => serialize_value(value.begin), "end" => serialize_value(value.end),
          "exclude_end" => value.exclude_end? }
      when Regexp
        { "_type" => "Regexp", "source" => value.source, "options" => value.options }
      when ->(v) { v.respond_to?(:to_global_id) }
        { "_type" => "GlobalID", "gid" => value.to_global_id.to_s }
      when Hash
        value.transform_values { |v| serialize_value(v) }
      when Array
        value.map { |v| serialize_value(v) }
      else
        value
      end
    end

    def self.deserialize_value(value)
      case value
      when Hash
        if value.key?("_type")
          # Special serialized types (Time, BigDecimal, etc.)
          case value["_type"]
          when "Success"
            RubyReactor::Success(deserialize_value(value["value"]))
          when "Failure"
            RubyReactor::Failure(deserialize_value(value["error"]), retryable: value["retryable"])
          when "Context"
            Context.deserialize_from_retry(value["value"])
          when "Time"
            Time.iso8601(value["value"])
          when "BigDecimal"
            BigDecimal(value["value"])
          when "Rational"
            Rational(value["numerator"], value["denominator"])
          when "Date"
            Date.iso8601(value["value"])
          when "DateTime"
            DateTime.iso8601(value["value"])
          when "Complex"
            Complex(value["real"], value["imag"])
          when "Range"
            Range.new(deserialize_value(value["begin"]), deserialize_value(value["end"]), value["exclude_end"])
          when "Regexp"
            Regexp.new(value["source"], value["options"])
          when "GlobalID"
            GlobalID::Locator.locate(value["gid"])
          else
            value
          end
        else
          # Regular hash - symbolize all keys recursively
          value.transform_keys(&:to_sym).transform_values { |v| deserialize_value(v) }
        end
      when Array
        value.map { |v| deserialize_value(v) }
      else
        value
      end
    end
    # rubocop:enable Metrics/CyclomaticComplexity, Metrics/MethodLength

    private_class_method :deserialize_value

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
          arguments: serialize_value(item[:arguments]),
          result: serialize_value(item[:result])
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
          arguments: deserialize_value(item["arguments"]),
          result: deserialize_value(item["result"])
        }
      end.compact
    end

    private_class_method :deserialize_undo_stack
  end
end
