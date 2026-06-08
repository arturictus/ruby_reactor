# frozen_string_literal: true

begin
  require "opentelemetry-api"
rescue LoadError
  # Optional load
end

module RubyReactor
  # Middleware implementing OpenTelemetry instrumentation for RubyReactor execution
  # rubocop:disable Metrics/ClassLength
  class OpenTelemetry < Middleware
    def initialize(**options)
      super
      @step_spans = {}
      @step_tokens = {}
      @retry_errors = {}
      @compensation_spans = {}
      @compensation_tokens = {}
      @undo_spans = {}
      @undo_tokens = {}
      @reactor_span = nil
      @reactor_token = nil
    end

    def on_start_reactor(reactor_name, inputs, context)
      ensure_opentelemetry_loaded!
      parent_ctx = extract_context(context)

      tracer = ::OpenTelemetry.tracer_provider.tracer("ruby_reactor")

      redact_keys = if context.reactor_class.respond_to?(:inputs)
                      context.reactor_class.inputs.select do |_, c|
                        c[:redact]
                      end.keys
                    else
                      []
                    end
      attributes = {
        "reactor.name" => reactor_name,
        "reactor.context_id" => context.context_id
      }
      inputs.each do |k, v|
        val = redact_keys.include?(k.to_sym) ? "[REDACTED]" : safe_value(v)
        attributes["reactor.inputs.#{k}"] = val
      end

      if context.status.to_s != "pending"
        attributes["reactor.resumed"] = true
      end

      @reactor_span = tracer.start_span(reactor_name, attributes: attributes, with_parent: parent_ctx || ::OpenTelemetry::Context.current)
      @reactor_token = ::OpenTelemetry::Context.attach(::OpenTelemetry::Trace.context_with_span(@reactor_span))
    end

    def on_complete_reactor(_reactor_name, result, context)
      ::OpenTelemetry::Context.detach(@reactor_token) if @reactor_token
      @reactor_token = nil

      span = @reactor_span
      @reactor_span = nil

      @step_spans.clear
      @step_tokens.clear
      @retry_errors.clear
      @compensation_spans.clear
      @compensation_tokens.clear
      @undo_spans.clear
      @undo_tokens.clear

      return unless span

      if result.is_a?(RubyReactor::RetryQueuedResult)
        # This execution attempt failed and was requeued for an async retry
        # (e.g. an async step or async map element). The reactor span therefore
        # represents one failed attempt; mark it ERROR (status does not
        # propagate to the parent, so a later successful attempt keeps the
        # overall trace healthy).
        map_reactor_retry_queued_status(span, result)
      else
        map_reactor_result_status(span, result, context)
      end
      span.finish
    end

    def on_failed_reactor(_reactor_name, error, context)
      ::OpenTelemetry::Context.detach(@reactor_token) if @reactor_token
      @reactor_token = nil

      span = @reactor_span
      @reactor_span = nil

      @step_spans.clear
      @step_tokens.clear
      @retry_errors.clear
      @compensation_spans.clear
      @compensation_tokens.clear
      @undo_spans.clear
      @undo_tokens.clear

      return unless span

      if error.is_a?(Exception)
        span.status = ::OpenTelemetry::Trace::Status.error(error.message)
        span.record_exception(error)
      elsif error.is_a?(RubyReactor::RetryQueuedResult)
        map_reactor_retry_queued_status(span, error)
      else
        map_reactor_result_status(span, error, context)
      end
      span.finish
    end

    def on_start_step(step_name, arguments, context)
      ensure_opentelemetry_loaded!
      tracer = ::OpenTelemetry.tracer_provider.tracer("ruby_reactor")

      redact_keys = if context.reactor_class.respond_to?(:inputs)
                      context.reactor_class.inputs.select do |_, c|
                        c[:redact]
                      end.keys
                    else
                      []
                    end
      attributes = { "step.name" => step_name.to_s }
      arguments.each do |k, v|
        val = redact_keys.include?(k.to_sym) ? "[REDACTED]" : safe_value(v)
        attributes["step.arguments.#{k}"] = val
      end

      parent_context = if @reactor_span
                         ::OpenTelemetry::Trace.context_with_span(@reactor_span)
                       else
                         ::OpenTelemetry::Context.current
                       end

      span = tracer.start_span("step.#{step_name}", attributes: attributes, with_parent: parent_context)
      token = ::OpenTelemetry::Context.attach(::OpenTelemetry::Trace.context_with_span(span))

      @step_spans[step_name] = span
      @step_tokens[step_name] = token
    end

    def on_complete_step(step_name, result, _context)
      token = @step_tokens.delete(step_name)
      ::OpenTelemetry::Context.detach(token) if token

      retry_error = @retry_errors.delete(step_name)

      span = @step_spans.delete(step_name)
      return unless span

      if result.is_a?(RubyReactor::AsyncResult)
        # The step was handed off to a background worker; the run block did not
        # execute here. Rename the span so it is not confused with the real
        # execution span emitted later under the resumed reactor span.
        span.name = "step.#{step_name}.enqueue" if span.respond_to?(:name=)
        span.set_attribute("step.async", true)
        span.set_attribute("step.status", "handed_off")
        span.set_attribute("step.async_job_id", result.job_id.to_s) if result.respond_to?(:job_id) && result.job_id
        span.status = ::OpenTelemetry::Trace::Status.ok
      elsif result.is_a?(RubyReactor::RetryQueuedResult)
        # This attempt failed and was requeued for an async retry. The span
        # represents a single failed attempt, so it is marked as an error.
        # OTel span status does not propagate to the parent, so the reactor
        # (and the overall trace) stays healthy if a later retry succeeds.
        map_retry_queued_status(span, result, retry_error)
      else
        map_step_result_status(span, result)
      end
      span.finish
    end

    def on_failed_step(step_name, error, _context)
      token = @step_tokens.delete(step_name)
      ::OpenTelemetry::Context.detach(token) if token
      @retry_errors.delete(step_name)

      span = @step_spans.delete(step_name)
      return unless span

      if error.is_a?(Exception)
        span.status = ::OpenTelemetry::Trace::Status.error(error.message)
        span.record_exception(error)
      else
        map_step_result_status(span, error)
      end
      span.finish
    end

    def on_retry_attempt(step_name, attempt, error, _context)
      return unless defined?(::OpenTelemetry)

      # Remember the error that triggered this attempt so we can annotate the
      # span if the step is requeued for an async retry (RetryQueuedResult does
      # not carry the error itself).
      @retry_errors[step_name] = error

      span = @step_spans[step_name]
      return unless span

      span.add_event("retry_attempt", attributes: {
                       "attempt" => attempt.to_i,
                       "error.message" => error.respond_to?(:message) ? error.message : error.to_s,
                       "error.class" => error.is_a?(Exception) ? error.class.name : "RubyReactor::Failure"
                     })
    end

    def on_start_compensation(step_name, error, arguments, context)
      ensure_opentelemetry_loaded!

      # Finish step span if it is still open, as compensation happens after the step execution has failed
      if (step_span = @step_spans.delete(step_name))
        step_token = @step_tokens.delete(step_name)
        ::OpenTelemetry::Context.detach(step_token) if step_token

        if error.is_a?(Exception)
          step_span.status = ::OpenTelemetry::Trace::Status.error(error.message)
          step_span.record_exception(error)
        else
          map_step_result_status(step_span, error)
        end
        step_span.finish
      end

      tracer = ::OpenTelemetry.tracer_provider.tracer("ruby_reactor")

      redact_keys = if context.reactor_class.respond_to?(:inputs)
                      context.reactor_class.inputs.select do |_, c|
                        c[:redact]
                      end.keys
                    else
                      []
                    end
      attributes = { "step.name" => step_name.to_s }
      arguments.each do |k, v|
        val = redact_keys.include?(k.to_sym) ? "[REDACTED]" : safe_value(v)
        attributes["step.arguments.#{k}"] = val
      end

      if error.is_a?(Exception)
        attributes["compensation.trigger_error.class"] = error.class.name
        attributes["compensation.trigger_error.message"] = error.message
      else
        attributes["compensation.trigger_error.message"] = error.to_s
      end

      parent_context = if @reactor_span
                         ::OpenTelemetry::Trace.context_with_span(@reactor_span)
                       else
                         ::OpenTelemetry::Context.current
                       end

      span = tracer.start_span("compensate.#{step_name}", attributes: attributes, with_parent: parent_context)
      token = ::OpenTelemetry::Context.attach(::OpenTelemetry::Trace.context_with_span(span))

      @compensation_spans[step_name] = span
      @compensation_tokens[step_name] = token
    end

    def on_complete_compensation(step_name, result, _context)
      token = @compensation_tokens.delete(step_name)
      ::OpenTelemetry::Context.detach(token) if token

      span = @compensation_spans.delete(step_name)
      return unless span

      map_compensation_result_status(span, result)
      span.finish
    end

    def on_failed_compensation(step_name, error, _context)
      token = @compensation_tokens.delete(step_name)
      ::OpenTelemetry::Context.detach(token) if token

      span = @compensation_spans.delete(step_name)
      return unless span

      span.set_attribute("compensation.status", "failed")
      if error.is_a?(Exception)
        span.status = ::OpenTelemetry::Trace::Status.error(error.message)
        span.record_exception(error)
        span.set_attribute("error.message", error.message)
        span.set_attribute("error.class", error.class.name)
      else
        map_compensation_result_status(span, error)
      end
      span.finish
    end

    def on_start_undo(step_name, step_result, arguments, context)
      ensure_opentelemetry_loaded!
      tracer = ::OpenTelemetry.tracer_provider.tracer("ruby_reactor")

      redact_keys = if context.reactor_class.respond_to?(:inputs)
                      context.reactor_class.inputs.select do |_, c|
                        c[:redact]
                      end.keys
                    else
                      []
                    end
      attributes = { "step.name" => step_name.to_s }
      arguments.each do |k, v|
        val = redact_keys.include?(k.to_sym) ? "[REDACTED]" : safe_value(v)
        attributes["step.arguments.#{k}"] = val
      end

      if step_result.respond_to?(:value)
        attributes["undo.original_result.value"] = safe_value(step_result.value)
      end

      parent_context = if @reactor_span
                         ::OpenTelemetry::Trace.context_with_span(@reactor_span)
                       else
                         ::OpenTelemetry::Context.current
                       end

      span = tracer.start_span("undo.#{step_name}", attributes: attributes, with_parent: parent_context)
      token = ::OpenTelemetry::Context.attach(::OpenTelemetry::Trace.context_with_span(span))

      @undo_spans[step_name] = span
      @undo_tokens[step_name] = token
    end

    def on_complete_undo(step_name, result, _context)
      token = @undo_tokens.delete(step_name)
      ::OpenTelemetry::Context.detach(token) if token

      span = @undo_spans.delete(step_name)
      return unless span

      map_undo_result_status(span, result)
      span.finish
    end

    def on_failed_undo(step_name, error, _context)
      token = @undo_tokens.delete(step_name)
      ::OpenTelemetry::Context.detach(token) if token

      span = @undo_spans.delete(step_name)
      return unless span

      span.set_attribute("undo.status", "failed")
      if error.is_a?(Exception)
        span.status = ::OpenTelemetry::Trace::Status.error(error.message)
        span.record_exception(error)
        span.set_attribute("error.message", error.message)
        span.set_attribute("error.class", error.class.name)
      else
        map_undo_result_status(span, error)
      end
      span.finish
    end

    def on_before_async_enqueue(context)
      return unless defined?(::OpenTelemetry)

      existing_tc = context.private_data[:trace_context] || context.private_data["trace_context"]
      return if existing_tc && !existing_tc.empty?

      carrier = {}
      ctx = if @reactor_span
              ::OpenTelemetry::Trace.context_with_span(@reactor_span)
            else
              ::OpenTelemetry::Context.current
            end

      ::OpenTelemetry.propagation.inject(carrier, context: ctx)
      context.private_data[:trace_context] = carrier unless carrier.empty?
    rescue StandardError => e
      RubyReactor.configuration.logger.warn("Telemetry context injection failed: #{e.message}")
    end

    def on_lock_acquired(key, _context)
      span = @reactor_span
      return unless span

      span.set_attribute("reactor.lock.key", key.to_s)
      span.add_event("lock_acquired", attributes: { "lock.key" => key.to_s })
    end

    def on_lock_released(key, _context)
      span = @reactor_span
      return unless span

      span.add_event("lock_released", attributes: { "lock.key" => key.to_s })
    end

    def on_lock_failed(key, error, _context)
      span = @reactor_span
      return unless span

      span.add_event("lock_acquisition_failed", attributes: {
                       "lock.key" => key.to_s,
                       "error.message" => error.message,
                       "error.class" => error.class.name
                     })
    end

    def on_semaphore_acquired(key, limit, _context)
      span = @reactor_span
      return unless span

      span.set_attribute("reactor.semaphore.key", key.to_s)
      span.set_attribute("reactor.semaphore.limit", limit.to_i)
      span.add_event("semaphore_acquired",
                     attributes: { "semaphore.key" => key.to_s, "semaphore.limit" => limit.to_i })
    end

    def on_semaphore_released(key, _context)
      span = @reactor_span
      return unless span

      span.add_event("semaphore_released", attributes: { "semaphore.key" => key.to_s })
    end

    def on_semaphore_failed(key, limit, error, _context)
      span = @reactor_span
      return unless span

      span.add_event("semaphore_acquisition_failed", attributes: {
                       "semaphore.key" => key.to_s,
                       "semaphore.limit" => limit.to_i,
                       "error.message" => error.message,
                       "error.class" => error.class.name
                     })
    end

    private

    def extract_context(context)
      return nil unless defined?(::OpenTelemetry)

      tc = fetch_trace_context(context)
      if tc.nil?
        RubyReactor.configuration.logger.debug("OTEL: No trace context found in context/storage for #{context.context_id}")
        return nil
      end
      RubyReactor.configuration.logger.debug("OTEL: Stored trace context hash is: #{tc.inspect}")

      tc = tc.transform_keys(&:to_s) if tc.respond_to?(:transform_keys)
      extracted = ::OpenTelemetry.propagation.extract(tc)
      if extracted
        span = ::OpenTelemetry::Trace.current_span(extracted)
        if span && span.context.valid?
          RubyReactor.configuration.logger.debug("OTEL: Extracted valid parent trace ID: #{span.context.hex_trace_id} for #{context.context_id}")
        else
          RubyReactor.configuration.logger.debug("OTEL: Extracted parent context is invalid for #{context.context_id}")
        end
      else
        RubyReactor.configuration.logger.debug("OTEL: Extraction returned nil for #{context.context_id}")
      end
      extracted
    rescue StandardError => e
      RubyReactor.configuration.logger.warn("Telemetry context extraction failed: #{e.message}")
      nil
    end

    def fetch_trace_context(context)
      tc = context.private_data[:trace_context] || context.private_data["trace_context"]
      tc ||= fetch_context_from_parent(context)
      tc ||= fetch_context_from_storage(context)
      tc
    end

    def fetch_context_from_parent(context)
      return nil unless context.parent_context

      pd = context.parent_context.private_data
      pd[:trace_context] || pd["trace_context"]
    end

    def fetch_context_from_storage(context)
      return nil unless context.parent_context_id

      parent_class = map_metadata_parent_class(context)
      return nil unless parent_class

      storage = RubyReactor.configuration.storage_adapter
      parent_data = storage.retrieve_context(context.parent_context_id, parent_class)
      return nil unless parent_data && parent_data["private_data"]

      private_data = ContextSerializer.deserialize_value(parent_data["private_data"])
      private_data[:trace_context] || private_data["trace_context"]
    rescue StandardError
      nil
    end

    def map_metadata_parent_class(context)
      meta = context.map_metadata
      meta&.dig(:parent_reactor_class_name) || meta&.dig("parent_reactor_class_name")
    end

    def safe_value(value)
      return "" if value.nil?

      str = value.is_a?(String) ? value : value.inspect
      if str.length > 256
        "#{str[0...240]}... [truncated]"
      else
        str
      end
    rescue StandardError
      "<unserializable>"
    end

    def ensure_opentelemetry_loaded!
      return if defined?(::OpenTelemetry)

      raise "OpenTelemetry is not loaded. Please make sure `opentelemetry-api` is installed and loaded."
    end

    def map_reactor_result_status(span, result, context)
      return unless result

      case result
      when RubyReactor::Success
        if result.skipped?
          span.set_attribute("reactor.status", "skipped")
          span.set_attribute("reactor.skipped_reason", result.reason.to_s)
          span.status = ::OpenTelemetry::Trace::Status.ok
        else
          span.set_attribute("reactor.status", "completed")
          span.status = ::OpenTelemetry::Trace::Status.ok

          rs = context.reactor_class.respond_to?(:returns) ? context.reactor_class.returns : nil
          if rs
            val = context.intermediate_results[rs.to_sym] || context.intermediate_results[rs.to_s]
            span.set_attribute("reactor.return_step", rs.to_s)
            span.set_attribute("reactor.return_value", safe_value(val))
          end
        end
      when RubyReactor::Failure
        span.set_attribute("reactor.status", "failed")
        msg = result.error.respond_to?(:message) ? result.error.message : result.error.to_s
        span.status = ::OpenTelemetry::Trace::Status.error(msg)
        span.set_attribute("error.class", result.exception_class.to_s) if result.exception_class
        span.set_attribute("error.message", msg)
        span.set_attribute("error.step_name", result.step_name.to_s) if result.step_name
        span.set_attribute("error.file_path", result.file_path) if result.file_path
        span.set_attribute("error.line_number", result.line_number) if result.line_number
        if result.validation_errors
          span.set_attribute("reactor.validation_errors", safe_value(result.validation_errors))
        end
      end
    end

    def map_reactor_retry_queued_status(span, result)
      span.set_attribute("reactor.status", "failed_will_retry")
      span.set_attribute("retry.will_retry", true)
      span.set_attribute("retry.step_name", result.step_name.to_s) if result.respond_to?(:step_name) && result.step_name
      span.set_attribute("retry.attempt", result.attempt_number.to_i) if result.respond_to?(:attempt_number)
      if result.respond_to?(:next_retry_at) && result.next_retry_at
        span.set_attribute("retry.next_retry_at", result.next_retry_at.to_s)
      end

      msg = if result.respond_to?(:step_name) && result.step_name
              "Reactor execution requeued: step '#{result.step_name}' will retry"
            else
              "Reactor execution requeued for retry"
            end
      span.status = ::OpenTelemetry::Trace::Status.error(msg)
    end

    def map_retry_queued_status(span, result, error)
      span.set_attribute("step.status", "failed_will_retry")
      span.set_attribute("retry.will_retry", true)
      span.set_attribute("retry.attempt", result.attempt_number.to_i) if result.respond_to?(:attempt_number)
      if result.respond_to?(:next_retry_at) && result.next_retry_at
        span.set_attribute("retry.next_retry_at", result.next_retry_at.to_s)
      end

      msg = if error.respond_to?(:message)
              error.message
            elsif error
              error.to_s
            else
              "Step failed; retry queued"
            end
      span.status = ::OpenTelemetry::Trace::Status.error(msg)

      if error.is_a?(Exception)
        span.record_exception(error)
        span.set_attribute("error.class", error.class.name)
      end
      span.set_attribute("error.message", msg)
    end

    def map_step_result_status(span, result)
      return unless result

      case result
      when RubyReactor::Success
        if result.skipped?
          span.set_attribute("step.status", "skipped")
          span.set_attribute("step.skipped_reason", result.reason.to_s)
        else
          span.set_attribute("step.status", "completed")
          span.status = ::OpenTelemetry::Trace::Status.ok
        end
      when RubyReactor::Failure
        span.set_attribute("step.status", "failed")
        msg = result.error.respond_to?(:message) ? result.error.message : result.error.to_s
        span.status = ::OpenTelemetry::Trace::Status.error(msg)
        span.set_attribute("error.class", result.exception_class.to_s) if result.exception_class
        span.set_attribute("error.message", msg)
        span.set_attribute("step.validation_errors", safe_value(result.validation_errors)) if result.validation_errors
      end
    end

    def map_compensation_result_status(span, result)
      return unless result

      case result
      when RubyReactor::Success
        if result.skipped?
          span.set_attribute("compensation.status", "skipped")
          span.set_attribute("compensation.skipped_reason", result.reason.to_s)
        else
          span.set_attribute("compensation.status", "completed")
          span.status = ::OpenTelemetry::Trace::Status.ok
        end
      when RubyReactor::Failure
        span.set_attribute("compensation.status", "failed")
        msg = result.error.respond_to?(:message) ? result.error.message : result.error.to_s
        span.status = ::OpenTelemetry::Trace::Status.error(msg)
        span.set_attribute("error.class", result.exception_class.to_s) if result.exception_class
        span.set_attribute("error.message", msg)
      end
    end

    def map_undo_result_status(span, result)
      return unless result

      case result
      when RubyReactor::Success
        if result.skipped?
          span.set_attribute("undo.status", "skipped")
          span.set_attribute("undo.skipped_reason", result.reason.to_s)
        else
          span.set_attribute("undo.status", "completed")
          span.status = ::OpenTelemetry::Trace::Status.ok
        end
      when RubyReactor::Failure
        span.set_attribute("undo.status", "failed")
        msg = result.error.respond_to?(:message) ? result.error.message : result.error.to_s
        span.status = ::OpenTelemetry::Trace::Status.error(msg)
        span.set_attribute("error.class", result.exception_class.to_s) if result.exception_class
        span.set_attribute("error.message", msg)
      end
    end
  end
  # rubocop:enable Metrics/ClassLength

  # Also expose it inside Middleware::OpenTelemetry namespace for compatibility
  class Middleware
    class OpenTelemetry < ::RubyReactor::OpenTelemetry
    end
  end
end
