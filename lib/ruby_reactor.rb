# frozen_string_literal: true

require "concurrent"
require "zeitwerk"

# Load dry-validation if available (for validation features)
begin
  require "dry-validation"
rescue LoadError
  # dry-validation is optional, validation features won't be available
end

# Load sidekiq if available (for async features)
begin
  require "sidekiq"
rescue LoadError
  # sidekiq is optional, async features won't be available
end

loader = Zeitwerk::Loader.for_gem
loader.setup

module RubyReactor
  # Success/Failure pattern for results
  class Success
    attr_reader :value

    def initialize(value = nil)
      @value = value
    end

    def success?
      true
    end

    def failure?
      false
    end
  end

  class Failure
    attr_reader :error, :retryable, :step_name, :inputs, :backtrace, :reactor_name, :step_arguments

    # rubocop:disable Metrics/ParameterLists
    def initialize(error, retryable: nil, step_name: nil, inputs: {}, backtrace: nil, redact_inputs: [],
                   reactor_name: nil, step_arguments: {})
      # rubocop:enable Metrics/ParameterLists
      @error = error
      @retryable = if retryable.nil?
                     error.respond_to?(:retryable?) ? error.retryable? : true
                   else
                     retryable
                   end
      @step_name = step_name
      @reactor_name = reactor_name
      @inputs = inputs
      @step_arguments = step_arguments
      @backtrace = backtrace || (error.respond_to?(:backtrace) ? error.backtrace : caller)
      @redact_inputs = redact_inputs
    end

    def success?
      false
    end

    def failure?
      true
    end

    def retryable?
      @retryable
    end

    def message
      msg = []
      header = "Error"
      header += " in reactor '#{reactor_name}'" if reactor_name
      header += " step '#{step_name}'" if step_name
      header += ": #{error_message}"

      msg << header

      if inputs && !inputs.empty?
        msg << "Inputs:"
        inputs.each do |key, value|
          val = @redact_inputs.include?(key) ? "[REDACTED]" : value.inspect
          msg << "  #{key}: #{val}"
        end
      end

      if step_arguments && !step_arguments.empty?
        msg << "Step Arguments:"
        step_arguments.each do |key, value|
          # We might want to redact step arguments too if they come from redacted inputs
          # For now, let's assume if the input key matches a redacted input key, it should be redacted
          # But step arguments have different names.
          # We can't easily track redaction for step arguments without more metadata.
          # For now, let's just display them.
          msg << "  #{key}: #{value.inspect}"
        end
      end

      if backtrace
        msg << "Backtrace:"
        msg << backtrace.take(5).map { |line| "  #{line}" }.join("\n")
      end

      msg.join("\n")
    end

    def to_s
      message
    end

    private

    def error_message
      @error.respond_to?(:message) ? @error.message : @error.to_s
    end
  end

  # Async result for background job execution
  class AsyncResult
    attr_reader :job_id, :intermediate_results

    def initialize(job_id:, intermediate_results: {})
      @job_id = job_id
      @intermediate_results = intermediate_results
    end

    def async?
      true
    end

    def success?
      false
    end

    def failure?
      false
    end
  end

  # Global helper methods
  def self.Success(value = nil)
    Success.new(value)
  end

  def self.Failure(error, **kwargs)
    Failure.new(error, **kwargs)
  end

  def self.configure
    yield(Configuration.instance) if block_given?
  end

  def self.configuration
    Configuration.instance
  end
end
