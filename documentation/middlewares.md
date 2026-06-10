# Middlewares & OpenTelemetry

RubyReactor exposes its execution lifecycle through a lightweight **middleware**
system. A middleware is a plain object that implements one or more
`on_<event>` hooks; RubyReactor invokes them as reactors, steps, compensations,
rollbacks, locks, and async hand-offs happen. This is the mechanism behind the
built-in **OpenTelemetry** instrumentation, and you can use it to add your own
logging, metrics, auditing, or tracing.

## Table of Contents

- [Overview](#overview)
- [Writing a Middleware](#writing-a-middleware)
- [Lifecycle Events](#lifecycle-events)
- [Registering Middlewares](#registering-middlewares)
- [Resolution & Order](#resolution--order)
- [Error Safety](#error-safety)
- [OpenTelemetry Tracing](#opentelemetry-tracing)

## Overview

Every execution path runs through a `MiddlewareRunner`, which dispatches each
lifecycle event to all configured middlewares:

- If a middleware responds to the specific hook (`on_start_step`,
  `on_complete_reactor`, …), that method is called.
- Otherwise, if it responds to a generic `on(event, *args)`, that is called.
- Otherwise the event is ignored for that middleware.

Middlewares are **observers**: their return values are ignored and they cannot
alter the result of a step or reactor. They are meant for side effects
(tracing, logging, metrics), not control flow.

## Writing a Middleware

Subclass `RubyReactor::Middleware` (which gives you an `options` reader) and
implement the hooks you care about. You only implement the events you need —
unhandled events are skipped.

```ruby
class TimingMiddleware < RubyReactor::Middleware
  def initialize(**options)
    super
    @started = {}
  end

  def on_start_step(step_name, _arguments, _context)
    @started[step_name] = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  def on_complete_step(step_name, _result, _context)
    started = @started.delete(step_name)
    return unless started

    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    RubyReactor.configuration.logger.info("step #{step_name} took #{elapsed.round(4)}s")
  end
end
```

A new middleware instance is created per reactor execution (see
[Resolution & Order](#resolution--order)), so it is safe to keep per-run state
in instance variables — concurrent reactors do not share a middleware instance.

You can also implement a single generic `on` method instead of individual
hooks:

```ruby
class AuditMiddleware < RubyReactor::Middleware
  def on(event, *args)
    RubyReactor.configuration.logger.debug("[audit] #{event}: #{args.first}")
  end
end
```

## Lifecycle Events

Every hook receives the relevant identifiers plus the execution `context` as the
last argument. The `context` exposes `context_id`, `reactor_class`, `inputs`,
`status`, `private_data`, and more.

### Reactor

| Event | Hook | Arguments |
| --- | --- | --- |
| Reactor started | `on_start_reactor` | `(reactor_class_name, inputs, context)` |
| Reactor completed | `on_complete_reactor` | `(reactor_class_name, result, context)` |
| Reactor failed | `on_failed_reactor` | `(reactor_class_name, error, context)` |

### Step

| Event | Hook | Arguments |
| --- | --- | --- |
| Step started | `on_start_step` | `(step_name, arguments, context)` |
| Step completed | `on_complete_step` | `(step_name, result, context)` |
| Step failed | `on_failed_step` | `(step_name, error, context)` |
| Retry attempt | `on_retry_attempt` | `(step_name, attempt_number, error, context)` |

### Compensation & Rollback (Undo)

| Event | Hook | Arguments |
| --- | --- | --- |
| Compensation started | `on_start_compensation` | `(step_name, error, arguments, context)` |
| Compensation completed | `on_complete_compensation` | `(step_name, result, context)` |
| Compensation failed | `on_failed_compensation` | `(step_name, error_or_result, context)` |
| Undo started | `on_start_undo` | `(step_name, step_result, arguments, context)` |
| Undo completed | `on_complete_undo` | `(step_name, result, context)` |
| Undo failed | `on_failed_undo` | `(step_name, error_or_result, context)` |

### Async, Locks & Semaphores

| Event | Hook | Arguments |
| --- | --- | --- |
| Before async enqueue | `on_before_async_enqueue` | `(context)` |
| Lock acquired | `on_lock_acquired` | `(key, context)` |
| Lock failed | `on_lock_failed` | `(key, error, context)` |
| Lock released | `on_lock_released` | `(key, context)` |
| Semaphore acquired | `on_semaphore_acquired` | `(key, limit, context)` |
| Semaphore failed | `on_semaphore_failed` | `(key, limit, error, context)` |
| Semaphore released | `on_semaphore_released` | `(key, context)` |

> **`on_before_async_enqueue`** fires just before a context is serialized and
> handed off to a background job (async step, async retry, or async map
> element). It is the place to inject any data that must travel with the job —
> this is exactly how the OpenTelemetry middleware propagates trace context
> across the async boundary by writing into `context.private_data`.

## Registering Middlewares

### Global

Configure middlewares once and they apply to every reactor:

```ruby
RubyReactor.configure do |config|
  config.middlewares = [
    TimingMiddleware,                      # class — instantiated per run
    [AuditMiddleware, { level: :debug }],  # [class, options] — options passed to initialize
    MetricsMiddleware.new                  # an already-built instance
  ]
end
```

Each entry may be:

- a **class** — a new instance is created per reactor run with no options,
- a **`[class, options]`** pair — instantiated per run with `class.new(**options)`,
- an **instance** — reused as-is.

### Per-Reactor

Declare middlewares on a specific reactor with the `middleware` DSL method.
These run **in addition to** the global ones:

```ruby
class CheckoutReactor < RubyReactor::Reactor
  middleware AuditMiddleware, level: :info

  input :cart_id
  # steps...
end
```

## Resolution & Order

When a reactor runs, RubyReactor builds the effective middleware list with
`Executor.middlewares_for`:

1. Global middlewares (`config.middlewares`) first, then per-reactor
   middlewares (`reactor.middlewares`).
2. Classes and `[class, options]` pairs are instantiated; instances are kept
   as-is.

Hooks are invoked on each middleware in that order. Because classes are
instantiated **per reactor execution**, middleware instance state is isolated
between concurrent reactors (including parallel async map elements).

## Error Safety

The `MiddlewareRunner` wraps every hook invocation in a rescue: a
`StandardError` raised inside a middleware is **caught and logged as a warning**,
and execution continues. A broken middleware can never crash a reactor:

```text
RubyReactor middleware error in AuditMiddleware during start_step: <message>
```

This means you should not rely on a middleware hook to enforce business rules —
use a step for that.

---

## OpenTelemetry Tracing

RubyReactor ships a built-in middleware, `RubyReactor::OpenTelemetry`, that
emits [OpenTelemetry](https://opentelemetry.io/) spans for the full execution
lifecycle. It turns a reactor run into a trace whose waterfall mirrors the
reactor → step → compensation/undo hierarchy, including work that crosses async
and retry boundaries.

The middleware loads the OpenTelemetry libraries lazily (`opentelemetry-api` is
required with a rescued `LoadError`). The lifecycle hooks expect the libraries
to be present: if you register the middleware without them installed, the
reactor/step start hooks raise. That error is caught and logged by the
middleware runner (see [Error Safety](#error-safety)) so it never crashes a
reactor, but it will log a warning on every run — only register
`RubyReactor::OpenTelemetry` in environments where OpenTelemetry is installed
and configured.

### What it produces

| Span | Created on | Notable attributes |
| --- | --- | --- |
| `<ReactorName>` | reactor start | `reactor.name`, `reactor.context_id`, `reactor.inputs.*`, `reactor.resumed` |
| `step.<name>` | step start | `step.name`, `step.arguments.*` |
| `step.<name>.enqueue` | async hand-off | `step.async`, `step.status=handed_off`, `step.async_job_id` |
| `compensate.<name>` | compensation start | `compensation.status`, `compensation.trigger_error.*` |
| `undo.<name>` | rollback start | `undo.status`, `undo.original_result.value` |

Retry, lock, and semaphore activity are recorded as **events** on the active
span (`retry_attempt`, `semaphore_acquisition_failed`, …) rather than separate
spans.

Reactor and step status is mapped onto the span status: success → `OK`,
failure → `ERROR` with the error class/message, and an attempt that was requeued
for an async retry is marked `ERROR` with `retry.will_retry=true` /
`step.status=failed_will_retry`. Because OpenTelemetry span status does not
propagate to the parent, a failed-and-requeued attempt does not poison the
overall trace if a later attempt succeeds.

### Setup

Add the OpenTelemetry gems:

```ruby
# Gemfile
gem "opentelemetry-api"
gem "opentelemetry-sdk"
gem "opentelemetry-exporter-otlp" # or any exporter you prefer
```

Configure the SDK (exporter, service name) and register the middleware:

```ruby
# config/initializers/opentelemetry.rb
require "opentelemetry/sdk"
require "opentelemetry/exporter/otlp"

OpenTelemetry::SDK.configure do |c|
  c.service_name = "my_app"
  c.add_span_processor(
    OpenTelemetry::SDK::Trace::Export::BatchSpanProcessor.new(
      OpenTelemetry::Exporter::OTLP::Exporter.new
    )
  )
end

RubyReactor.configure do |config|
  config.middlewares = [RubyReactor::OpenTelemetry]
end
```

That is all that is required — once registered, every reactor run is traced.

### Sensitive values & redaction

Reactor inputs and step arguments are attached to spans
(`reactor.inputs.*`, `step.arguments.*`). Any input declared with `redact: true`
is emitted as `"[REDACTED]"` instead of its value:

```ruby
class LoginReactor < RubyReactor::Reactor
  input :email
  input :password, redact: true   # never written to a span
  # ...
end
```

Values are also passed through a safe serializer so large or non-primitive
objects do not bloat the trace.

### Distributed & async traces

When a reactor hands work off to a background job — an async step, an async
retry, or an async map element — the trace must continue in the worker that
picks it up. The middleware handles this automatically:

1. On `before_async_enqueue` it injects the **currently active span context**
   into `context.private_data[:trace_context]` before the context is serialized.
2. When the worker resumes the context, the middleware extracts that trace
   context and starts the resumed reactor span underneath it.

The result is a single, connected trace across processes, with the resumed work
nested under the step that handed it off. Each subsequent hand-off in a chain
(async step → async retry → …) re-injects the span that is active at that
moment, so deep async chains stay correctly nested rather than flattened under
the first step.

### Custom exporters

`RubyReactor::OpenTelemetry` is just a span producer; **where** spans go is
entirely up to the OpenTelemetry SDK configuration, not RubyReactor. To send
traces somewhere the standard exporters do not cover, register a custom
exporter/processor with the SDK. The demo application includes one such example
(`demo_app/config/initializers/opentelemetry.rb`) that serializes spans to
OTLP/JSON and posts them to a local Teley trace viewer — a useful reference for
writing your own.

### Building your own tracer

The same lifecycle events power any instrumentation. If you do not use
OpenTelemetry, you can implement the same hooks (`on_start_reactor`,
`on_start_step`, `on_complete_step`, `on_start_compensation`, …) in a custom
middleware to emit metrics or logs in whatever format your observability stack
expects. See [Lifecycle Events](#lifecycle-events) for the full list.
