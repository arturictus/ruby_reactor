# frozen_string_literal: true

require "zeitwerk"
require "pathname"
require_relative "ruby_reactor/registry"
require_relative "ruby_reactor/utils/code_extractor"

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
loader.inflector.inflect("api" => "API")
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
    attr_reader :error, :retryable, :step_name, :inputs, :backtrace, :reactor_name, :step_arguments, :exception_class,
                :file_path, :line_number, :code_snippet

    # rubocop:disable Metrics/ParameterLists
    def initialize(error, retryable: nil, step_name: nil, inputs: {}, backtrace: nil, redact_inputs: [],
                   reactor_name: nil, step_arguments: {}, exception_class: nil,
                   file_path: nil, line_number: nil, code_snippet: nil, invalid_payload: false)
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
      raw_backtrace = backtrace || (error.respond_to?(:backtrace) ? error.backtrace : caller)
      @backtrace = filter_backtrace(raw_backtrace)
      @redact_inputs = redact_inputs
      @exception_class = exception_class || (error.is_a?(Exception) ? error.class.name : nil)
      @file_path = file_path
      @line_number = line_number
      @code_snippet = code_snippet
      @invalid_payload = invalid_payload
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

    def invalid_payload?
      @invalid_payload
    end

    def message
      msg = []
      header = "Error"
      header += " in reactor '#{reactor_name}'" if reactor_name
      header += " step '#{step_name}'" if step_name
      header += ": #{error_message}"

      msg << header

      msg << "Location: #{file_path}:#{line_number}" if file_path && line_number

      if code_snippet && !code_snippet.empty?
        msg << "Code Snippet:"
        msg << "```"
        code_snippet.each do |line|
          prefix = line[:target] ? ">" : " "
          msg << "#{prefix} #{line[:line_number].to_s.rjust(4)}  #{line[:content]}"
        end
        msg << "```"
      end

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
        msg << backtrace.take(10).map { |line| "  #{line}" }.join("\n")
      end

      msg.join("\n")
    end

    def to_s
      message
    end

    private

    def filter_backtrace(backtrace)
      return backtrace if ENV["RUBY_REACTOR_DEBUG"] == "true"
      return backtrace if backtrace.nil? || backtrace.empty?

      root_path = RubyReactor.root.to_s
      filtered = []
      filtered << backtrace.first

      internal_block = false
      backtrace[1..]&.each do |line|
        if line.start_with?(root_path)
          unless internal_block
            filtered << "... [ruby-reactor-internals-redacted-trace]"
            internal_block = true
          end
        else
          filtered << line
          internal_block = false
        end
      end
      filtered
    end

    def error_message
      @error.respond_to?(:message) ? @error.message : @error.to_s
    end
  end

  # Async result for background job execution
  class AsyncResult
    attr_reader :job_id, :intermediate_results, :execution_id

    def initialize(job_id:, intermediate_results: {}, execution_id: nil)
      @job_id = job_id
      @intermediate_results = intermediate_results
      @execution_id = execution_id
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

  def self.root
    Pathname.new(File.expand_path("..", __dir__))
  end
end
