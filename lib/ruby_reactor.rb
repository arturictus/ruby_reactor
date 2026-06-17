# frozen_string_literal: true

require "zeitwerk"
require "pathname"
require "securerandom"
require_relative "ruby_reactor/registry"
require_relative "ruby_reactor/utils/code_extractor"
require_relative "ruby_reactor/dsl/lockable" # Add this
require_relative "ruby_reactor/lock"
require_relative "ruby_reactor/ordered_lock"
require_relative "ruby_reactor/semaphore"
require_relative "ruby_reactor/period"
require_relative "ruby_reactor/rate_limit"

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
loader.inflector.inflect("api" => "API", "rspec" => "RSpec")
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

    def skipped?
      false
    end

    def to_h
      { success: true, value: @value }
    end
  end

  # A "clean halt" signal. Two ways to produce one:
  #
  #   1. Implicitly, when a reactor's `with_period` gate finds the bucket has
  #      already been claimed. The executor short-circuits before any step
  #      runs.
  #
  #   2. Explicitly, by returning `RubyReactor.Skipped(reason: "...")` from a
  #      step's `run` block. The reactor halts immediately — no further steps,
  #      and crucially **no compensation** of already-completed steps. Use this
  #      when a step discovers that the rest of the workflow is not needed
  #      (e.g. "user already opted out", "nothing to do this round") and the
  #      partial progress is still correct to keep.
  #
  # Subclass of Success so callers that only check `success?` continue to work;
  # `skipped?` distinguishes it.
  class Skipped < Success
    attr_reader :reason, :period_key, :step_name

    def initialize(reason: nil, period_key: nil, step_name: nil)
      super(nil)
      @reason = reason
      @period_key = period_key
      @step_name = step_name
    end

    def skipped?
      true
    end
  end

  class Failure
    attr_reader :error, :retryable, :step_name, :inputs, :backtrace, :reactor_name, :step_arguments, :exception_class,
                :file_path, :line_number, :code_snippet, :validation_errors

    # rubocop:disable Metrics/ParameterLists, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
    def initialize(error, retryable: nil, step_name: nil, inputs: {}, backtrace: nil, redact_inputs: [],
                   reactor_name: nil, step_arguments: {}, exception_class: nil,
                   file_path: nil, line_number: nil, code_snippet: nil, invalid_payload: false, validation_errors: nil)
      # rubocop:enable Metrics/ParameterLists, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
      @error = error

      # Handle case where error is a serialized hash (e.g. from async failure propagation)
      if @error.is_a?(Hash)
        attributes = extract_attributes_from_hash(@error)
        @error = attributes[:error]
        retryable = attributes[:retryable] if retryable.nil?
        step_name ||= attributes[:step_name]
        reactor_name ||= attributes[:reactor_name]
        inputs = attributes[:inputs] if inputs.empty?
        step_arguments = attributes[:step_arguments] if step_arguments.empty?
        raw_backtrace ||= attributes[:backtrace] || backtrace
        exception_class ||= attributes[:exception_class]
        file_path ||= attributes[:file_path]
        line_number ||= attributes[:line_number]
        code_snippet ||= attributes[:code_snippet]
        validation_errors ||= attributes[:validation_errors]
      end

      @retryable = if retryable.nil?
                     @error.respond_to?(:retryable?) ? @error.retryable? : true
                   else
                     retryable
                   end
      @step_name = step_name
      @reactor_name = reactor_name
      @inputs = inputs
      @step_arguments = step_arguments
      raw_backtrace ||= backtrace || (@error.respond_to?(:backtrace) ? @error.backtrace : caller)
      @backtrace = filter_backtrace(raw_backtrace)
      @redact_inputs = redact_inputs
      @exception_class = exception_class || (@error.is_a?(Exception) ? @error.class.name : nil)
      @file_path = file_path
      @line_number = line_number
      @code_snippet = code_snippet
      @invalid_payload = invalid_payload
      @validation_errors = validation_errors
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

    def skipped?
      false
    end

    def invalid_payload?
      @invalid_payload
    end

    def message
      msg = [build_header]
      msg << "Location: #{file_path}:#{line_number}" if file_path && line_number

      append_code_snippet(msg)
      append_inputs(msg)
      append_step_arguments(msg)
      append_backtrace(msg)

      msg.join("\n")
    end

    def to_s
      message
    end

    def to_h
      {
        success: false,
        error: error_message,
        step_name: @step_name,
        inputs: @inputs,
        redact_inputs: @redact_inputs,
        reactor_name: @reactor_name,
        step_arguments: @step_arguments,
        exception_class: @exception_class,
        file_path: @file_path,
        line_number: @line_number,
        code_snippet: @code_snippet,
        validation_errors: @validation_errors,
        backtrace: @backtrace
      }
    end

    private

    def build_header
      header = "Error"
      header += " in reactor '#{reactor_name}'" if reactor_name
      header += " step '#{step_name}'" if step_name
      header += ": #{error_message}"
      header
    end

    def append_code_snippet(msg)
      return unless code_snippet && !code_snippet.empty?

      msg << "Code Snippet:"
      msg << "```"
      code_snippet.each do |line|
        prefix = line[:target] ? ">" : " "
        msg << "#{prefix} #{line[:line_number].to_s.rjust(4)}  #{line[:content]}"
      end
      msg << "```"
    end

    def append_inputs(msg)
      return unless inputs && !inputs.empty?

      msg << "Inputs:"
      inputs.each do |key, value|
        val = @redact_inputs.include?(key) ? "[REDACTED]" : value.inspect
        msg << "  #{key}: #{val}"
      end
    end

    def append_step_arguments(msg)
      return unless step_arguments && !step_arguments.empty?

      msg << "Step Arguments:"
      step_arguments.each do |key, value|
        msg << "  #{key}: #{value.inspect}"
      end
    end

    def append_backtrace(msg)
      return unless backtrace

      msg << "Backtrace:"
      msg << backtrace.take(10).map { |line| "  #{line}" }.join("\n")
    end

    def filter_backtrace(backtrace)
      return backtrace if ENV["RUBY_REACTOR_DEBUG"] == "true"
      return backtrace if backtrace.nil? || backtrace.empty?

      internal_prefix = RubyReactor.internal_lib_path
      filtered = []
      filtered << backtrace.first

      internal_block = false
      backtrace[1..]&.each do |line|
        file_path, = RubyReactor::Utils::BacktraceLocation.parse(line)
        if file_path&.start_with?(internal_prefix)
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

    def extract_attributes_from_hash(error_hash)
      # Ensure indifferent access
      err = ->(k) { error_hash[k.to_s] || error_hash[k.to_sym] }

      {
        error: err[:message] || err[:error] || error_hash,
        retryable: err[:retryable],
        step_name: err[:step_name],
        reactor_name: err[:reactor_name],
        inputs: err[:inputs] || {},
        step_arguments: err[:step_arguments] || {},
        backtrace: err[:backtrace],
        exception_class: err[:exception_class],
        file_path: err[:file_path],
        line_number: err[:line_number],
        code_snippet: err[:code_snippet],
        validation_errors: err[:validation_errors]
      }
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

  # Build a `Skipped` result. Return one from a step's `run` block to halt the
  # reactor cleanly without triggering compensation of previous steps.
  def self.Skipped(reason: nil, **kwargs)
    Skipped.new(reason: reason, **kwargs)
  end

  def self.configure
    yield(Configuration.instance) if block_given?
  end

  def self.configuration
    Configuration.instance
  end

  # The name under which a reactor class's durable state is keyed in storage
  # (`reactor:<name>:context:<id>`, map metadata, etc.). MUST be stable across
  # processes: the enqueuing process writes the blob under this name and a
  # *different* worker process reads it back by the same name. So an anonymous
  # class falls back to a fixed constant, NOT `object_id` — object_id is
  # process-local and would make the worker's read key miss the writer's key.
  # The context_id in the key still disambiguates distinct anonymous reactors.
  # (A truly anonymous class can't be reconstituted by name in another process,
  # so cross-process resume of one is inherently unsupported; this only keeps
  # the keys self-consistent within a process — e.g. inline tests.)
  def self.reactor_storage_name(reactor_class)
    return "AnonymousReactor" if reactor_class.nil?

    reactor_class.name || "AnonymousReactor"
  end

  # Kick the self-rescheduling recovery sweeper chain. Call once per cluster —
  # typically from an initializer (`RubyReactor.start_sweeper!`). Idempotent:
  # calling it on every process boot is safe because the worker claims each tick
  # by time-window, so duplicate kicks collapse to a single chain. No-op when
  # `config.sweeper_enabled` is false. Returns the scheduled job id, or nil when
  # disabled or when this window's tick was already claimed by another caller.
  def self.start_sweeper!
    return unless configuration.sweeper_enabled

    SidekiqWorkers::SweeperWorker.schedule_next
  end

  # Run both recovery sweepers exactly once and return their counts. The
  # synchronous escape hatch for hosts that schedule recovery with their own
  # cron / k8s CronJob instead of the in-cluster chain (set
  # `config.sweeper_enabled = false` and call this from `rake ruby_reactor:sweep`
  # or a binstub).
  def self.sweep_once(limit: nil)
    limit ||= configuration.sweeper_limit
    {
      reactors: Sweeper.run_once(limit: limit),
      maps: Map::Sweeper.run_once(limit: limit)
    }
  end

  def self.root
    Pathname.new(File.expand_path("..", __dir__))
  end

  def self.internal_lib_path
    File.join(root.to_s, "lib")
  end
end
