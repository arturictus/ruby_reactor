# frozen_string_literal: true

require "sidekiq"

module RubyReactor
  # Sidekiq worker for executing RubyReactor reactors asynchronously
  # with non-blocking retry capabilities
  class Worker
    include Sidekiq::Worker

    # Enable Sidekiq retries for infrastructure failures only
    sidekiq_options retry: RubyReactor::Configuration.sidekiq_retry_count, dead: false, queue: RubyReactor::Configuration.sidekiq_queue

    sidekiq_retries_exhausted do |_, exception|
      # Handle infrastructure failures (network, Redis, etc.)
      puts "RubyReactor infrastructure failure: #{exception.message}"
    end

    def perform(serialized_context, reactor_class_name = nil)
      context = ContextSerializer.deserialize(serialized_context)

      # If reactor_class_name is provided, use it to get the reactor class
      # This handles cases where the class can't be found via const_get
      if reactor_class_name && context.reactor_class.nil?
        begin
          context.reactor_class = Object.const_get(reactor_class_name)
        rescue NameError
          # If not found, try to find it in the current namespace
          # This is a fallback for test environments
          context.reactor_class = reactor_class_name.constantize if reactor_class_name.respond_to?(:constantize)
        end
      end

      # Resume execution from the failed step
      executor = Executor.new(context.reactor_class, {}, context)
      result = executor.resume_execution
      Sidekiq.logger.info "RubyReactor: Worker resume_execution result: #{result.class.name}"

      case result
      when RubyReactor::Failure
        # Step failed finally, run compensation
        run_compensation_for_current_step(context)
        error_message = result.error.respond_to?(:message) ? result.error.message : result.error.to_s
        Sidekiq.logger.error "RubyReactor step '#{context.current_step}' failed: #{error_message}"
        # Don't raise - let the job complete (AsyncResult will remain in async state)
      when RubyReactor::Success
        # Execution completed successfully
        Sidekiq.logger.info "RubyReactor execution completed successfully"
      when RubyReactor::RetryQueuedResult
        # Job was re-queued for retry, nothing more to do
        Sidekiq.logger.info "RubyReactor job re-queued for retry of step '#{result.step_name}'"
      else
        # Unexpected result
        Sidekiq.logger.error "Unexpected result from resume_execution: #{result.inspect}"
      end
    rescue StandardError => e
      # Log unexpected errors but don't retry - our custom logic handles retries
      Sidekiq.logger.error "RubyReactor unexpected error: #{e.message}"
      Sidekiq.logger.error "Context: #{context.inspect}"
      raise
    end

    private

    def log_infrastructure_failure(msg, exception)
      Sidekiq.logger.error("RubyReactor infrastructure failure: #{exception.message}")
      Sidekiq.logger.error("Job details: #{msg.inspect}")
    end

    def run_compensation_for_current_step(context)
      return unless context.current_step

      step_config = context.reactor_class.steps[context.current_step]
      return unless step_config

      # Get the arguments that were passed to the failed step
      arguments = resolve_arguments_for_step(step_config, context)

      # Run compensation
      compensation_result = compensate_step(step_config, context.retry_context.failure_reason, arguments, context)

      case compensation_result
      when RubyReactor::Success
        Sidekiq.logger.info "Compensation succeeded for step '#{context.current_step}'"
      when RubyReactor::Failure
        Sidekiq.logger.error "Compensation failed for step '#{context.current_step}': #{compensation_result.error}"
      end
    end

    def resolve_arguments_for_step(step_config, context)
      # Simplified argument resolution for compensation
      arguments = {}
      step_config.arguments.each do |arg_name, arg_config|
        arguments[arg_name] = resolve_argument_value(arg_config, context)
      end
      arguments
    end

    def resolve_argument_value(arg_config, context)
      source = arg_config[:source]
      case source
      when RubyReactor::Template::Input
        context.get_input(source.name)
      when RubyReactor::Template::Result
        context.get_result(source.step_name, source.path)
      when RubyReactor::Template::Value
        source.value
      else
        source
      end
    end

    def compensate_step(step_config, error, arguments, context)
      if step_config.compensate_block
        step_config.compensate_block.call(error, arguments, context)
      elsif step_config.has_impl?
        step_config.impl.compensate(error, arguments, context)
      else
        RubyReactor.Success() # Default compensation
      end
    end

    def log_unexpected_error(error, context)
      Sidekiq.logger.error("RubyReactor unexpected error: #{error.message}")
      Sidekiq.logger.error("Context: #{context.inspect}") if context
    end
  end
end
