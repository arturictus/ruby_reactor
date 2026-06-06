# frozen_string_literal: true

require "opentelemetry/sdk"
require "net/http"
require "json"
require "uri"

# Use "none" for default traces exporter so we only use our custom JSON exporter
ENV["OTEL_TRACES_EXPORTER"] = "none"
ENV["OTEL_EXPORTER_OTLP_TRACES_ENDPOINT"] ||= "http://localhost:5754/r/ruby_reactor_session"

# Custom OpenTelemetry Exporter to serialize and post spans in OTLP JSON format
class TeleyJsonExporter
  def initialize(endpoint:)
    @uri = URI(endpoint)
  end

  def export(spans, timeout: nil)
    return OpenTelemetry::SDK::Trace::Export::SUCCESS if spans.empty?

    # Retrieve resource attributes safely
    resource = (spans.first.respond_to?(:resource) && spans.first.resource) ||
               (OpenTelemetry.respond_to?(:tracer_provider) && OpenTelemetry.tracer_provider.respond_to?(:resource) && OpenTelemetry.tracer_provider.resource)
    
    resource_attrs_hash = {}
    if resource && resource.respond_to?(:attribute_enumerator)
      resource_attrs_hash = resource.attribute_enumerator.to_h
    end

    resource_attrs = map_attributes(resource_attrs_hash)
    
    # Ensure service.name is present in resource attributes
    unless resource_attrs.any? { |a| a[:key] == "service.name" }
      resource_attrs << { key: "service.name", value: { stringValue: "demo_app" } }
    end

    # Group spans by scope (instrumentation library)
    scope_spans_map = {}
    spans.each do |span|
      scope_name = (span.respond_to?(:instrumentation_library) && span.instrumentation_library&.name) || "ruby_reactor"
      scope_spans_map[scope_name] ||= []
      scope_spans_map[scope_name] << map_span(span)
    end

    scope_spans = scope_spans_map.map do |name, mapped_spans|
      {
        scope: { name: name },
        spans: mapped_spans
      }
    end

    payload = {
      resourceSpans: [
        {
          resource: { attributes: resource_attrs },
          scopeSpans: scope_spans
        }
      ]
    }

    # Post OTLP JSON to Teley
    begin
      req = Net::HTTP::Post.new(@uri)
      req["Content-Type"] = "application/json"
      req.body = JSON.generate(payload)

      Net::HTTP.start(@uri.hostname, @uri.port, use_ssl: @uri.scheme == "https") do |http|
        http.request(req)
      end
      OpenTelemetry::SDK::Trace::Export::SUCCESS
    rescue StandardError => e
      warn "TeleyJsonExporter failed to export traces: #{e.message}"
      OpenTelemetry::SDK::Trace::Export::FAILURE
    end
  end

  def force_flush(timeout: nil)
    OpenTelemetry::SDK::Trace::Export::SUCCESS
  end

  def shutdown(timeout: nil)
    OpenTelemetry::SDK::Trace::Export::SUCCESS
  end

  private

  def map_span(span)
    parent_span_id = span.parent_span_id ? span.parent_span_id.unpack1("H*") : nil
    parent_span_id = nil if parent_span_id == "0000000000000000"

    kind_int = case span.kind
               when :internal then 1
               when :server then 2
               when :client then 3
               when :producer then 4
               when :consumer then 5
               else 1
               end

    status_hash = { code: span.status.code }
    status_hash[:message] = span.status.description if span.status.description && !span.status.description.empty?

    events_mapped = (span.events || []).map do |ev|
      {
        timeUnixNano: ev.timestamp.to_s,
        name: ev.name,
        attributes: map_attributes(ev.attributes)
      }
    end

    {
      traceId: span.trace_id.unpack1("H*"),
      spanId: span.span_id.unpack1("H*"),
      parentSpanId: parent_span_id,
      name: span.name,
      kind: kind_int,
      startTimeUnixNano: span.start_timestamp.to_s,
      endTimeUnixNano: span.end_timestamp.to_s,
      attributes: map_attributes(span.attributes),
      events: events_mapped,
      status: status_hash
    }.compact
  end

  def map_attributes(attrs)
    return [] unless attrs
    attrs.map do |k, v|
      val_hash = if v.is_a?(String)
                   { stringValue: v }
                 elsif v.is_a?(Integer)
                   { intValue: v }
                 elsif v.is_a?(Float)
                   { doubleValue: v }
                 elsif v.is_a?(TrueClass) || v.is_a?(FalseClass)
                   { boolValue: v }
                 elsif v.is_a?(Array)
                   { arrayValue: { values: v.map { |x| map_val(x) } } }
                 else
                   { stringValue: v.to_s }
                 end
      { key: k.to_s, value: val_hash }
    end
  end

  def map_val(x)
    if x.is_a?(String)
      { stringValue: x }
    elsif x.is_a?(Integer)
      { intValue: x }
    elsif x.is_a?(Float)
      { doubleValue: x }
    elsif x.is_a?(TrueClass) || x.is_a?(FalseClass)
      { boolValue: x }
    else
      { stringValue: x.to_s }
    end
  end
end

OpenTelemetry::SDK.configure do |c|
  c.service_name = "demo_app"
  
  # Register the custom Teley OTLP/JSON exporter
  exporter = TeleyJsonExporter.new(endpoint: ENV["OTEL_EXPORTER_OTLP_TRACES_ENDPOINT"])
  processor = OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(exporter)
  c.add_span_processor(processor)
end
