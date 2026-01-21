# frozen_string_literal: true

module RubyReactor
  module RSpec
    # rubocop:disable Metrics/ClassLength
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

      # Intercept a step and provide a custom implementation
      #
      # @param step_name [Symbol, String] The name of the step to intercept
      # @param nested_steps [Array<Symbol, String>] Path to nested steps if applicable
      # @param element_index [Integer] Optional index for map steps
      # @yield [args, context, original_impl] block to execute
      #   @yieldparam args [Hash] The arguments passed to the step
      #   @yieldparam context [RubyReactor::Context] The execution context
      #   @yieldparam original_impl [Proc] A proc that can be called to execute the original implementation:
      #     original_impl.call(args, context)
      def mock_step(step_name, *nested_steps, element_index: nil, &block)
        @interceptors << {
          type: :mock,
          step_path: [step_name, *nested_steps],
          conditions: { element_index: element_index, block: block }
        }
        self
      end

      # Fluent API for mocking nested map steps
      # @example
      #   reactor.map(:my_map).mock_step(:inner_step) { ... }
      def map(step_name)
        StepProxy.new(self, step_name)
      end

      # Fluent API for mocking nested compose steps
      # @example
      #   reactor.compose(:my_sub_reactor).mock_step(:inner_step) { ... }
      def composed(step_name)
        # If already executed, return the traversed subject
        return traverse_composed(step_name) if @executed

        # Otherwise return a configuration proxy
        StepProxy.new(self, step_name)
      end
      alias compose composed

      # Proxy class for fluent mocking configuration
      class StepProxy
        def initialize(subject, step_name)
          @subject = subject
          @step_name = step_name
        end

        def mock_step(inner_step_name, *nested_steps, &block)
          @subject.mock_step(@step_name, inner_step_name, *nested_steps, &block)
          @subject # Return subject to allow chaining or calling run
        end

        # Support deep nesting?
        def map(inner_step_name)
          StepProxy.new(@subject, [@step_name, inner_step_name].flatten)
        end

        def composed(inner_step_name)
          StepProxy.new(@subject, [@step_name, inner_step_name].flatten)
        end
      end

      # --- Traversal ---

      def map_elements(step_name)
        ensure_executed!

        # Check composed_contexts
        entry = @reactor_instance.context.composed_contexts[step_name] ||
                @reactor_instance.context.composed_contexts[step_name.to_s] ||
                @reactor_instance.context.composed_contexts[step_name.to_sym]

        return [] unless entry && entry[:type] == :map_ref

        map_id = entry[:map_id]
        storage = RubyReactor.configuration.storage_adapter

        # This requires the storage adapter to implement retrieval of map element context IDs
        # If it's not implemented in MemoryAdapter (if used), we might need to fallback?
        # But tests use Redis.
        child_ids = storage.retrieve_map_element_context_ids(map_id, @reactor_instance.class.name)

        child_ids.map do |id|
          klass = RubyReactor::Context.resolve_reactor_class(entry[:element_reactor_class])
          child_instance = klass.find(id)
          self.class.new(
            reactor_class: child_instance.class,
            inputs: child_instance.context.inputs,
            context: child_instance.context,
            async: @async,
            process_jobs: @process_jobs
          ).tap do |s|
            s.instance_variable_set(:@executed, true)
            s.instance_variable_set(:@reactor_instance, child_instance)
          end
        end
      end

      def map_element(step_name, index: 0)
        elements = map_elements(step_name)
        elements[index]
      end

      private

      def traverse_composed(step_name)
        ensure_executed!

        entry = @reactor_instance.context.composed_contexts[step_name] ||
                @reactor_instance.context.composed_contexts[step_name.to_s] ||
                @reactor_instance.context.composed_contexts[step_name.to_sym]

        unless entry && entry[:type] == :composed
          # Try to find failed attempt if validation failure?
          return nil
        end

        child_context = entry[:context]
        child_instance = child_context.reactor_class.new(child_context)

        self.class.new(
          reactor_class: child_instance.class,
          inputs: child_instance.context.inputs,
          context: child_instance.context,
          async: @async,
          process_jobs: @process_jobs
        ).tap do |s|
          s.instance_variable_set(:@executed, true)
          s.instance_variable_set(:@reactor_instance, child_instance)
        end
      end

      public

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

        # Reload using the execution class (which might be the mocked subclass with unique name)
        @reactor_instance = execution_class.find(captured_context_id)
        # Update our reference to the class so future reloads (e.g. in result introspection) work
        @reactor_class = execution_class
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
          return ctx.failure_reason if ctx.failure_reason.is_a?(RubyReactor::Failure)

          RubyReactor::Failure.new(ctx.failure_reason || {})
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
        when "running"
          # Try to determine if it is truly running or if we just missed the completion
          if @process_jobs && defined?(Sidekiq::Testing)
            # Force one more check
            process_pending_jobs
            # Reload status
            @reactor_instance = @reactor_class.find(@reactor_instance.context.context_id)
            return result unless @reactor_instance.context.status.to_s == "running"
          end

          # If still running, return a Pending/Running result instead of nil
          # This allows matchers to report "expected success but was running"
          RubyReactor::Failure("Reactor is still running (Async operations pending?)",
                               retryable: true)
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

      # --- Interrupt Test Helpers ---

      # Check if the reactor is paused at an interrupt
      #
      # @return [Boolean] true if the reactor is in paused state
      def paused?
        ensure_executed!
        @reactor_instance.context.status.to_s == "paused"
      end

      # Get the current step where the reactor is paused (interrupt step)
      # Note: When multiple interrupts are ready, this returns just one of them.
      # Use `ready_interrupt_steps` to get all ready interrupt steps.
      #
      # @return [Symbol, nil] the name of the current interrupt step, or nil if not paused
      def current_step
        ensure_executed!
        step = @reactor_instance.context.current_step
        step&.to_sym
      end

      # Get all ready interrupt steps (steps that can be resumed)
      # This is useful when multiple interrupts are waiting concurrently.
      #
      # @return [Array<Symbol>] list of ready interrupt step names
      def ready_interrupt_steps
        ensure_executed!
        return [] unless paused?

        # Build the dependency graph and get ready steps
        graph = RubyReactor::DependencyGraph.new
        graph_manager = RubyReactor::Executor::GraphManager.new(
          @reactor_class, graph, @reactor_instance.context
        )
        graph_manager.build_and_validate!
        graph_manager.mark_completed_steps_from_context

        # Filter to only interrupt steps (using interrupt? predicate method)
        ready = graph_manager.dependency_graph.ready_steps
        ready.select { |step_config| step_config.respond_to?(:interrupt?) && step_config.interrupt? }
             .map { |step_config| step_config.name.to_sym }
      end

      # Resume a paused reactor with the given payload
      #
      # @param payload [Hash] The data to provide to the interrupt step
      # @param step [Symbol, String, nil] The specific interrupt step to resume.
      #   Required when multiple interrupts are ready. If not provided and only
      #   one interrupt is ready, that step will be used.
      # @return [TestSubject] self for chaining and introspection
      # @raise [Error::ValidationError] if the reactor is not paused, step is ambiguous, or payload is invalid
      def resume(payload: {}, step: nil)
        ensure_executed!

        unless paused?
          raise RubyReactor::Error::ValidationError,
                "Cannot resume: reactor is not paused (status: #{@reactor_instance.context.status})"
        end

        step_name = determine_resume_step(step)

        # Use the reactor's continue method
        @reactor_instance.continue(payload: payload, step_name: step_name)

        # Process any pending async jobs
        process_pending_jobs if @process_jobs && defined?(Sidekiq::Testing)

        # Reload the reactor instance to get updated state
        @reactor_instance = @reactor_class.find(@reactor_instance.context.context_id)

        # Return self for chaining and introspection
        self
      end

      private

      def determine_resume_step(step)
        ready_steps = ready_interrupt_steps

        if step
          # User explicitly specified a step
          step_sym = step.to_sym
          unless ready_steps.include?(step_sym)
            raise RubyReactor::Error::ValidationError,
                  "Cannot resume: step :#{step} is not ready. Ready steps: #{ready_steps.inspect}"
          end
          step_sym
        elsif ready_steps.size == 1
          # Only one step ready, use it
          ready_steps.first
        elsif ready_steps.size > 1
          # Multiple steps ready, step is required
          raise RubyReactor::Error::ValidationError,
                "Cannot resume: multiple interrupt steps are ready (#{ready_steps.inspect}). " \
                "Please specify which step to resume using: resume(step: :step_name, payload: {...})"
        else
          # Fallback to current_step (shouldn't happen normally)
          current_step || raise(RubyReactor::Error::ValidationError, "Cannot resume: no ready interrupt steps found")
        end
      end

      public

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

        execution_class = Class.new(@reactor_class) do
          # 1. Copy configuration from parent
          @steps = superclass.steps.dup
          @inputs = superclass.inputs.dup
          @return_step = superclass.return_step
          @start_step = superclass.instance_variable_get(:@start_step)
          @async = superclass.async?
          @retry_defaults = superclass.instance_variable_get(:@retry_defaults)

          # 2. Add Name Handling with Unique Registry Entry
          # We must register a unique name so that if this reactor is reloaded (e.g. after async child completion),
          # it resolves back to THIS mocked class, not the original superclass.
          unique_name = "#{superclass.name}Mock#{object_id}"
          define_singleton_method(:name) { unique_name }
          RubyReactor::Registry.register(unique_name, self)

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
        end

        # 4. Apply Interceptors
        apply_interceptors(execution_class, interceptors)

        execution_class
      end

      def apply_interceptors(klass, interceptors)
        # Group interceptors by the current level step
        grouped = interceptors.group_by { |i| i[:step_path].first }

        grouped.each do |target_step, step_interceptors|
          step_config_orig = klass.steps[target_step]

          unless step_config_orig
            # Maybe it's a map step? We can't easily intercept inner steps from here
            next
          end

          # Create a new StepConfig
          step_config = step_config_orig.clone

          # Check if we have nested interceptors
          nested_interceptors = step_interceptors.select { |i| i[:step_path].size > 1 }

          if nested_interceptors.any?
            apply_nested_interceptors(step_config, nested_interceptors)
            step_config.instance_variable_set(:@async, false)
          end

          # Apply direct interceptors (mocks/failures on this step)
          direct_interceptors = step_interceptors.select { |i| i[:step_path].size == 1 }
          direct_interceptors.each do |interceptor|
            case interceptor[:type]
            when :failure
              apply_failure_interceptor(step_config, target_step)
            when :mock
              apply_mock_interceptor(step_config, target_step, step_config_orig, interceptor)
            end
          end

          klass.steps[target_step] = step_config
        end
      end

      def apply_nested_interceptors(step_config, interceptors)
        # Determine if it's a map step or compose step based on arguments
        # Map steps have :mapped_reactor_class in arguments
        # Compose steps (ComposeStep logic) should also have it in arguments (passed via DSL builder)

        args = step_config.arguments
        target_reactor_class_source = nil
        arg_key = nil

        if args[:mapped_reactor_class]
          target_reactor_class_source = args[:mapped_reactor_class][:source]
          arg_key = :mapped_reactor_class
        elsif args[:composed_reactor_class]
          target_reactor_class_source = args[:composed_reactor_class][:source]
          arg_key = :composed_reactor_class
        end

        return unless target_reactor_class_source.is_a?(RubyReactor::Template::Value)

        original_child_reactor = target_reactor_class_source.value

        # Dynamically subclass the child reactor
        mocked_child_reactor = Class.new(original_child_reactor) do
          define_singleton_method(:name) { original_child_reactor.name }
          # Copy configuration
          @steps = superclass.steps.dup
          @inputs = superclass.inputs.dup
          @return_step = superclass.return_step
          @start_step = superclass.instance_variable_get(:@start_step)
          @async = superclass.async?
        end

        # Recursively apply interceptors to the child reactor
        # Shift path: [:map_step, :inner, :deep] -> [:inner, :deep]
        child_interceptors = interceptors.map do |i|
          i.merge(step_path: i[:step_path].drop(1))
        end

        apply_interceptors(mocked_child_reactor, child_interceptors)

        # Replace the argument source with the mocked class
        # We need to clone arguments hash to avoid mutating original config globally if shared?
        # StepConfig arguments are usually unique per config instance (we cloned step_config)
        # BUT arguments hash is shared references. We must dup it.

        current_args = step_config.arguments
        step_config.instance_variable_set(:@arguments, current_args.dup)

        step_config.arguments[arg_key] = step_config.arguments[arg_key].dup if step_config.arguments[arg_key]

        step_config.arguments[arg_key][:source] = RubyReactor::Template::Value.new(mocked_child_reactor)
      end

      def apply_failure_interceptor(step_config, target_step)
        failure_impl = lambda do |_input, _context|
          RubyReactor::Failure("Simulated failure at #{target_step}")
        end

        step_config.instance_variable_set(:@run_block, failure_impl)
      end

      def apply_mock_interceptor(step_config, target_step, step_config_orig, interceptor)
        mock_block = interceptor[:conditions][:block]

        # Prepare original implementation call
        original_impl = if step_config_orig.has_run_block?
                          step_config_orig.run_block
                        elsif step_config_orig.has_impl?
                          ->(args, ctx) { step_config_orig.impl.run(args, ctx) }
                        else
                          ->(_, _) { raise "No implementation found for #{target_step}" }
                        end

        # Create the new implementation that wraps the user block
        wrapper_impl = lambda do |args, context|
          if mock_block.arity == 3
            mock_block.call(args, context, original_impl)
          else
            mock_block.call(args, context)
          end
        end

        step_config.instance_variable_set(:@run_block, wrapper_impl)
        step_config.instance_variable_set(:@async, false)
      end
    end
    # rubocop:enable Metrics/ClassLength
  end
end
