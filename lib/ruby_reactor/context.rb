# frozen_string_literal: true

module RubyReactor
  class Context
    attr_accessor :inputs, :intermediate_results, :private_data, :current_step, :retry_count, :concurrency_key, :retry_context, :reactor_class

    def initialize(inputs = {}, reactor_class = nil)
      @inputs = inputs
      @intermediate_results = {}
      @private_data = {}
      @current_step = nil
      @retry_count = 0
      @concurrency_key = nil
      @retry_context = RetryContext.new
      @reactor_class = reactor_class
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
        current_step: @current_step,
        retry_count: @retry_count,
        retry_context: @retry_context,
        reactor_class: @reactor_class
      }
    end

    def serialize_for_retry(job_id: nil, started_at: nil)
      {
        job_id: job_id,
        started_at: (started_at || Time.now).iso8601,
        reactor_class: @reactor_class&.name,
        inputs: serialize_value(@inputs),
        intermediate_results: serialize_value(@intermediate_results),
        private_data: serialize_value(@private_data),
        current_step: @current_step,
        retry_count: @retry_count,
        concurrency_key: @concurrency_key,
        retry_context: @retry_context.serialize_for_retry
      }
    end

    def self.deserialize_from_retry(data)
      context = new
      context.reactor_class = data['reactor_class'] ? Object.const_get(data['reactor_class']) : nil
      context.inputs = deserialize_value(data['inputs']) || {}
      context.intermediate_results = deserialize_value(data['intermediate_results']) || {}
      context.private_data = deserialize_value(data['private_data']) || {}
      context.current_step = data['current_step']
      context.retry_count = data['retry_count'] || 0
      context.concurrency_key = data['concurrency_key']
      context.retry_context = RetryContext.deserialize_from_retry(data['retry_context'] || {})
      context
    end

    private

    def serialize_value(value)
      case value
      when Time
        { '_type' => 'Time', 'value' => value.iso8601 }
      when BigDecimal
        { '_type' => 'BigDecimal', 'value' => value.to_s('F') }
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
        if value.key?('_type')
          case value['_type']
          when 'Time'
            Time.iso8601(value['value'])
          when 'BigDecimal'
            BigDecimal(value['value'])
          else
            value
          end
        else
          value.transform_keys(&:to_sym).transform_values { |v| deserialize_value(v) }
        end
      when Array
        value.map { |v| deserialize_value(v) }
      else
        value
      end
    end

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
  end
end
