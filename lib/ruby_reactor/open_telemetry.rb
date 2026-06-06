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
      return unless span

      map_reactor_result_status(span, result, context)
      span.finish
    end

    def on_failed_reactor(_reactor_name, error, context)
      ::OpenTelemetry::Context.detach(@reactor_token) if @reactor_token
      @reactor_token = nil

      span = @reactor_span
      @reactor_span = nil
      return unless span

      if error.is_a?(Exception)
        span.status = ::OpenTelemetry::Trace::Status.error(error.message)
        span.record_exception(error)
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

      span = @step_spans.delete(step_name)
      return unless span

      map_step_result_status(span, result)
      span.finish
    end

    def on_failed_step(step_name, error, _context)
      token = @step_tokens.delete(step_name)
      ::OpenTelemetry::Context.detach(token) if token

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

      span = @step_spans[step_name]
      return unless span

      span.add_event("retry_attempt", attributes: {
                       "attempt" => attempt.to_i,
                       "error.message" => error.respond_to?(:message) ? error.message : error.to_s,
                       "error.class" => error.is_a?(Exception) ? error.class.name : "RubyReactor::Failure"
                     })
    end

    def on_before_async_enqueue(context)
      return unless defined?(::OpenTelemetry)

      carrier = {}
      ::OpenTelemetry.propagation.inject(carrier)
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
  end
  # rubocop:enable Metrics/ClassLength

  # Also expose it inside Middleware::OpenTelemetry namespace for compatibility
  class Middleware
    class OpenTelemetry < ::RubyReactor::OpenTelemetry
    end
  end
end
