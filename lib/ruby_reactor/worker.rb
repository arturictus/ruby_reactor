# frozen_string_literal: true

require "sidekiq"

module RubyReactor
  # Sidekiq worker for executing RubyReactor reactors asynchronously
  # with non-blocking retry capabilities
  class Worker
    include Sidekiq::Worker

    # Enable Sidekiq retries for infrastructure failures only
    sidekiq_options retry: RubyReactor.configuration.sidekiq_retry_count, dead: false,
                    queue: RubyReactor.configuration.sidekiq_queue

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
      executor.resume_execution
    end

    private

    def log_infrastructure_failure(msg, exception)
      Sidekiq.logger.error("RubyReactor infrastructure failure: #{exception.message}")
      Sidekiq.logger.error("Job details: #{msg.inspect}")
    end

    # TODO: delete from here --------------------------------
    def run_compensation_for_current_step(context)
      return unless context.current_step

      step_config = context.reactor_class.steps[context.current_step]
      return unless step_config

      # Get the arguments that were passed to the failed step
      arguments = resolve_arguments_for_step(step_config, context)

      # Run compensation
      compensate_step(step_config, context.retry_context.failure_reason, arguments, context)
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
