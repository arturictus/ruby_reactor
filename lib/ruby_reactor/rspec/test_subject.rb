# frozen_string_literal: true

module RubyReactor
  module RSpec
    class TestSubject
      include ::RSpec::Mocks::ExampleMethods

      attr_reader :reactor_instance, :run_result

      def initialize(reactor_class:, inputs:, context: {}, async: nil, process_jobs: true)
        @reactor_class = reactor_class
        @inputs = inputs
        @context_data = context
        @async = async
        @process_jobs = process_jobs
        @interceptors = []
        @executed = false
      end

      # --- Configuration DSL ---

      def failing_at(step_name, *nested_steps, element_index: nil, &block)
        @interceptors << {
          type: :failure,
          step_path: [step_name, *nested_steps],
          conditions: { element_index: element_index, block: block }
        }
        self
      end

      def run_async(boolean)
        @async = boolean
        self
      end

      # --- Execution ---

      def run
        return self if @executed

        # 1. Apply Interceptors (Dynamic Subclassing)
        execution_class = prepare_execution_class

        # 2. Capture Context ID
        captured_context_id = nil

        allow(RubyReactor::Context).to receive(:new).and_wrap_original do |m, *args|
          ctx = m.call(*args)
          captured_context_id ||= ctx.context_id
          ctx
        end

        # 3. Native Run
        if @async == false
          allow(execution_class).to receive(:async?).and_return(false)
        elsif @async == true
          allow(execution_class).to receive(:async?).and_return(true)
        end

        @run_result = nil
        if @process_jobs && defined?(Sidekiq::Testing)
          # Ensure SidekiqAdapter is used to capture jobs in fake mode
          allow(RubyReactor.configuration).to receive(:async_router).and_return(RubyReactor::SidekiqAdapter)

          # Avoid nesting error which happens in Sidekiq 7+ if a mode is already set
          begin
            Sidekiq::Testing.fake! do
              @run_result = execution_class.run(@inputs)
            end
          rescue Sidekiq::Testing::TestModeAlreadySetError
            @run_result = execution_class.run(@inputs)
          end
        else
          @run_result = execution_class.run(@inputs)
        end

        # 4. Reload
        raise "Could not capture context ID during execution" unless captured_context_id

        @reactor_instance = @reactor_class.find(captured_context_id)
        @executed = true
        self
      end

      # --- Introspection (Auto-Run) ---

      def result
        ensure_executed!

        ctx = @reactor_instance.context
        status = ctx.status.to_s
        case status
        when "failed"
          reason = ctx.failure_reason || {}
          RubyReactor::Failure.new(
            reason[:message],
            step_name: reason[:step_name],
            inputs: reason[:inputs],
            backtrace: reason[:backtrace],
            reactor_name: reason[:reactor_name],
            step_arguments: reason[:step_arguments],
            exception_class: reason[:exception_class],
            file_path: reason[:file_path],
            line_number: reason[:line_number],
            code_snippet: reason[:code_snippet],
            validation_errors: reason[:validation_errors]
          )
        when "completed"
          # Determine the success value
          val = if @reactor_class.return_step
                  ctx.intermediate_results[@reactor_class.return_step.to_sym]
                else
                  # Return result of the last executed step
                  # Execution trace contains: { step: name, ... }
                  # Trace does not strictly contain result, so we look up in intermediate_results
                  last_trace = ctx.execution_trace.last
                  if last_trace
                    step_name = last_trace[:step]
                    # Handle symbol/string mismatch
                    ctx.intermediate_results[step_name.to_sym] || ctx.intermediate_results[step_name.to_s]
                  end
                end
          RubyReactor::Success.new(val)
        when "paused"
          RubyReactor::InterruptResult.new(
            execution_id: ctx.context_id,
            intermediate_results: ctx.intermediate_results
            # We assume no error if paused normally
          )
        end
      end

      def success?
        ensure_executed!
        @reactor_instance.context.status.to_s == "completed"
      end

      def failure?
        ensure_executed!
        @reactor_instance.context.status.to_s == "failed"
      end

      def step_result(name)
        ensure_executed!
        # Prefer intermediate_results as it is the data store
        # Logic to handle symbol vs string mismatch
        key_sym = name.to_sym
        key_str = name.to_s

        if @reactor_instance.context.intermediate_results.key?(key_sym)
          @reactor_instance.context.intermediate_results[key_sym]
        elsif @reactor_instance.context.intermediate_results.key?(key_str)
          @reactor_instance.context.intermediate_results[key_str]
        else
          # Fallback to execution trace if available (e.g. for inspection)
          entry = @reactor_instance.context.execution_trace.find { |t| t[:step].to_s == key_str }
          entry ? entry[:result] : nil
        end
      end

      def error
        res = result
        res.respond_to?(:error) ? res.error : nil
      end

      def ensure_executed!
        run unless @executed

        # Process jobs if status is running and processing is enabled
        return unless @process_jobs && @reactor_instance.context.status.to_s == "running"

        process_pending_jobs
      end

      private

      def process_pending_jobs
        return unless defined?(Sidekiq::Testing)

        # Loop until no more jobs are being queued
        # This handles batched map execution where jobs queue more jobs
        max_iterations = 100
        iterations = 0

        while iterations < max_iterations
          iterations += 1
          jobs_processed = false

          # Known worker classes to check
          worker_classes = [
            RubyReactor::SidekiqWorkers::Worker,
            RubyReactor::SidekiqWorkers::MapElementWorker,
            RubyReactor::SidekiqWorkers::MapExecutionWorker,
            RubyReactor::SidekiqWorkers::MapCollectorWorker
          ]

          worker_classes.each do |worker_class|
            while worker_class.jobs.any?
              job = worker_class.jobs.shift
              worker_class.new.perform(*job["args"])
              jobs_processed = true
            end
          end

          break unless jobs_processed
        end

        # Final reload
        @reactor_instance = @reactor_class.find(@reactor_instance.context.context_id)
      end

      def prepare_execution_class
        # Even if no interceptors, we might need to subclass to override async steps
        return @reactor_class if @interceptors.empty? && @async != false

        interceptors = @interceptors
        force_sync = @async == false

        Class.new(@reactor_class) do
          # 1. Copy configuration from parent
          @steps = superclass.steps.dup
          @inputs = superclass.inputs.dup
          @return_step = superclass.return_step
          @start_step = superclass.instance_variable_get(:@start_step)
          @async = superclass.async?
          @retry_defaults = superclass.instance_variable_get(:@retry_defaults)

          # 2. Add Name Handling
          define_singleton_method(:name) { superclass.name }

          # 3. Apply Force Sync (Disable async on all steps)
          if force_sync
            @steps.each do |name, config|
              next unless config.async?

              # Clone and modify
              new_config = config.clone
              new_config.instance_variable_set(:@async, false)
              @steps[name] = new_config
            end
          end

          # 4. Apply Interceptors
          interceptors.each do |interceptor|
            next unless interceptor[:type] == :failure

            target_step = interceptor[:step_path].first
            step_config_orig = steps[target_step]

            unless step_config_orig
              # Maybe it's a map step? We can't easily intercept inner steps from here
              next
            end

            # Create a new StepConfig with failure logic
            step_config = step_config_orig.clone

            failure_impl = lambda do |_input, _context|
              RubyReactor::Failure("Simulated failure at #{target_step}")
            end

            # Prioritize our failure block
            step_config.instance_variable_set(:@run_block, failure_impl)

            steps[target_step] = step_config
          end
        end
      end
    end
  end
end
