# frozen_string_literal: true

module RubyReactor
  class Context
    attr_accessor :inputs, :intermediate_results, :private_data, :current_step, :retry_count, :concurrency_key

    def initialize(inputs = {})
      @inputs = inputs
      @intermediate_results = {}
      @private_data = {}
      @current_step = nil
      @retry_count = 0
      @concurrency_key = nil
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
        retry_count: @retry_count
      }
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
  end
end
