# Contract: Web Router (`RubyReactor::Web::Router`)

**Phase 1 output** — specification for the new Rack application that handles
cross-service HTTP traffic: inbound callback signals (mandatory) and inbound
trigger requests (optional convenience).

Related: [http-callback.md](./http-callback.md) | [http-trigger.md](./http-trigger.md)

---

## What It Is

`RubyReactor::Web::Router` is a standalone Roda-based Rack application, separate
from the existing `RubyReactor::Web::Application` (dashboard). It owns exactly
two routes and has no UI concerns. It is the only network boundary the gem owns
for cross-service communication.

---

## Mount Interface

The router is a standard Rack app. Mount it at any path; the prefix is consumed
by the host and the router sees relative paths (`/callback/...`, `/trigger`).

```ruby
# Rails (routes.rb)
mount RubyReactor::Web::Router, at: "/ruby_reactor"

# Rack / Roda
run Rack::URLMap.new(
  "/ruby_reactor" => RubyReactor::Web::Router,
  "/"             => MyApp
)
```

### Coexistence with `Web::Application`

Both can be mounted simultaneously at different paths. Neither depends on the
other.

```ruby
# Rails
mount RubyReactor::Web::Application, at: "/ruby_reactor_ui"
mount RubyReactor::Web::Router,      at: "/ruby_reactor"
```

---

## Route Table

| Method | Path                                      | Purpose                                | Required? |
| ------ | ----------------------------------------- | -------------------------------------- | --------- |
| POST   | `/callback/:execution_id/:step_name`      | Resume a paused local saga             | Mandatory |
| POST   | `/trigger`                                | Start a named reactor (remote service) | Optional  |

All other paths return `404 Not Found`.

---

## Route 1 — `POST /callback/:execution_id/:step_name`

**Direction**: Remote service → this service (local).

The remote POSTs here when its work is done. The router resumes the waiting
local saga. See [http-callback.md](./http-callback.md) for the full HTTP contract
(request/response shapes, status codes).

### Implementation logic

```
1. Parse JSON body → { status, payload, error }
2. Look up context by execution_id (storage_adapter.find_context_by_id)
3. If not found → 404 { error: "Reactor not found" }
4. Resolve reactor_class from context["reactor_class"]
5. Idempotency check: if intermediate_results already has step_name → 200 { resumed: false, reason: "already_completed" }
6. If RemoteStepConfig.validate_payload defined and payload fails → 422 { error: ..., fields: ... }
   (step is marked failed; compensation runs)
7. Call reactor_class.continue(id: execution_id, step_name: step_name, payload: callback_payload)
   where callback_payload = { status:, payload:, error: } (status drives Success vs Failure in the step)
8. Return 200 { resumed: true }
```

### Reactor class resolution

The router uses the same pattern as `Web::API`:

```ruby
raw = storage_adapter.find_context_by_id(execution_id)
return not_found unless raw
reactor_class_name = raw["reactor_class"] || raw[:reactor_class]
reactor_class = Context.resolve_reactor_class(reactor_class_name)
return not_found unless reactor_class
```

`Context.resolve_reactor_class` (existing method) handles `const_get` safely.

### What the `continue` call does

`reactor_class.continue` (existing — `reactor.rb:38`) rehydrates the context
from Redis, writes the callback payload into `intermediate_results[step_name]`,
and resumes execution from the waiting step. No new logic is needed here.

---

## Route 2 — `POST /trigger`

**Direction**: Remote local service → this service (acting as the remote).

Optional. Only needed when this service acts as the *remote* in another
service's `remote` step. Without this route mounted, triggers must be accepted
by the application's own endpoints. See [http-trigger.md](./http-trigger.md)
for the full HTTP contract.

### Implementation logic

```
1. Parse JSON body → { reactor_name, inputs, callback_url }
2. Validate all three fields present → 422 if missing
3. Resolve reactor class:
     klass = Context.resolve_reactor_class(reactor_name)
   Return 404 { error: "Reactor '#{reactor_name}' not found" } if klass is nil
   Return 404 if klass does not include RubyReactor::Dsl::Reactor (security guard)
4. Validate inputs against reactor's declared inputs → 422 if invalid
5. Pre-seed context with callback_url:
     context = Context.new(inputs, klass)
     context.private_data[:remote_callback_url] = callback_url
6. Run reactor with pre-seeded context:
     reactor = klass.new(context)
     reactor.run(inputs)
7. Return 202 { remote_saga_id: context.context_id, status: "accepted" }
```

### Security guard — reactor_name

`reactor_name` is a user-supplied string. The router validates it via
`Context.resolve_reactor_class` (which wraps `const_get` with rescue) and then
requires the result to include `RubyReactor::Dsl::Reactor`. This prevents
arbitrary constant access while remaining open to any user-defined reactor
without a separate registry.

```ruby
klass = Context.resolve_reactor_class(reactor_name)
halt(404, { error: "Reactor '#{reactor_name}' not found" }) unless klass
halt(404, { error: "Reactor '#{reactor_name}' not found" }) unless klass.include?(RubyReactor::Dsl::Reactor)
```

### Why `context.private_data` survives async execution

`private_data` is a field on `Context` that is serialized to Redis on every
`save_context` / `checkpoint!` call. When `reactor.run` enqueues a Sidekiq job
(async reactor), it calls `save_context` BEFORE enqueuing (F2 guarantee — see
`reactor.rb:116`). The worker rehydrates the full context including
`private_data[:remote_callback_url]`, so the callback URL is available when
the saga eventually reaches a terminal state.

---

## Completion Callback — `RemoteCallbackMiddleware`

This is the mechanism that closes the loop for the `/trigger` route: when the
triggered remote saga reaches a terminal state, the gem POSTs the result back
to the `callback_url`.

### How it works

A new `RubyReactor::RemoteCallbackMiddleware` class (registered globally at
router mount time) hooks into the existing `complete_reactor` lifecycle event
that the `Executor` already emits (see `executor.rb:155`):

```
Executor#execute / #resume_execution (ensure block)
  → emit_lifecycle_completion
    → middlewares.on(:complete_reactor, reactor_name, result, context)
```

The middleware fires on every `complete_reactor` event, checks for a stored
`callback_url`, and fires only when the result is terminal:

```ruby
class RemoteCallbackMiddleware < RubyReactor::Middleware
  def on_complete_reactor(_reactor_name, result, context)
    callback_url = context.private_data[:remote_callback_url]
    return unless callback_url
    # InterruptResult = saga paused mid-flight (its own interrupt steps);
    # do NOT fire yet — wait for eventual terminal result.
    return unless result.is_a?(RubyReactor::Success) || result.is_a?(RubyReactor::Failure)

    body = build_callback_body(result)
    RubyReactor.configuration.callback_sender.call(callback_url, body)
  rescue StandardError => e
    RubyReactor.configuration.logger.warn(
      "RubyReactor: failed to deliver remote callback to #{callback_url}: #{e.message}"
    )
  end

  private

  def build_callback_body(result)
    if result.is_a?(RubyReactor::Success)
      { status: "success", payload: result.value || {} }
    else
      { status: "failure", error: result.error.to_s, payload: {} }
    end
  end
end
```

### Registration at mount time

The router registers `RemoteCallbackMiddleware` globally when first loaded.
Registration is idempotent (checked before adding):

```ruby
# inside RubyReactor::Web::Router, at class load time:
unless RubyReactor.configuration.middlewares.include?(RemoteCallbackMiddleware)
  RubyReactor.configuration.middlewares << RemoteCallbackMiddleware
end
```

This means the middleware is only active when the router is mounted — services
that do not mount the router are not affected. Local sagas that do not use
`/trigger` (i.e., `private_data[:remote_callback_url]` is nil) incur a single
nil-check per reactor completion, which is negligible.

### The `InterruptResult` case

When the triggered remote saga has its own `interrupt` steps, `complete_reactor`
fires with an `InterruptResult`. The middleware returns early. When the operator
(or another service) later resumes that saga and it eventually reaches
`Success`/`Failure`, `complete_reactor` fires again — this time the middleware
delivers the callback. No extra tracking is needed.

---

## New Configuration

### `callback_host` (local side — already in data-model.md)

Required on the service that makes outbound remote steps. Used to build
`CallbackContext.callback_url`.

```ruby
RubyReactor.configure do |config|
  config.callback_host = "https://orders.internal"
end
```

### `callback_sender` (remote side — new)

Proc called by `RemoteCallbackMiddleware` to deliver the completion callback.
Default uses `net/http` (stdlib, no new gem dependency). Override for custom
TLS, auth headers, or retry behaviour:

```ruby
RubyReactor.configure do |config|
  config.callback_sender = lambda do |url, body|
    MyHTTPClient.post(url, json: body, headers: { "Authorization" => "Bearer #{ENV['CALLBACK_TOKEN']}" })
  end
end
```

Default implementation (gem-provided, no extra dependencies):

```ruby
def callback_sender
  @callback_sender ||= lambda do |url, body|
    require "net/http"
    require "json"
    uri = URI(url)
    Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") do |http|
      req = Net::HTTP::Post.new(uri, "Content-Type" => "application/json")
      req.body = JSON.generate(body)
      http.request(req)
    end
  end
end
```

---

## Error Handling Summary

| Condition                              | Route     | Status | Body                                      |
| -------------------------------------- | --------- | ------ | ----------------------------------------- |
| execution_id not found in Redis        | /callback | 404    | `{ error: "Reactor not found" }`          |
| reactor_class not loadable             | /callback | 404    | `{ error: "Reactor not found" }`          |
| step already completed (idempotency)   | /callback | 200    | `{ resumed: false, reason: "already_completed" }` |
| validate_payload fails                 | /callback | 422    | `{ error: "...", fields: {...} }`         |
| reactor_name missing / not found       | /trigger  | 404    | `{ error: "Reactor '...' not found" }`   |
| reactor_name fails security guard      | /trigger  | 404    | `{ error: "Reactor '...' not found" }`   |
| inputs missing                         | /trigger  | 422    | `{ error: "inputs is required" }`        |
| input validation fails                 | /trigger  | 422    | `{ error: "...", fields: {...} }`        |
| callback_url missing                   | /trigger  | 422    | `{ error: "callback_url is required" }`  |
| callback delivery fails (middleware)   | async     | n/a    | logged, not propagated to caller          |

---

## Sequence Diagrams

### Callback flow (mandatory route)

```
Remote service                     Local service
     │                                  │
     │  POST /ruby_reactor/callback     │
     │  /:execution_id/:step_name ────► │
     │                                  │ 1. find context by id
     │                                  │ 2. idempotency check
     │                                  │ 3. validate_payload (optional)
     │                                  │ 4. reactor_class.continue(...)
     │  200 { resumed: true }           │    → executor resumes from paused step
     │ ◄────────────────────────────── │    → subsequent steps run
     │                                  │    → context saved as completed/failed
```

### Trigger flow (optional route) — async remote reactor

```
Local service (caller)            Remote service (this service)
     │                                  │
     │  POST /ruby_reactor/trigger ───► │
     │                                  │ 1. resolve reactor class
     │                                  │ 2. pre-seed context (callback_url in private_data)
     │                                  │ 3. reactor.run(inputs)
     │                                  │    → context saved to Redis (callback_url persisted)
     │                                  │    → Sidekiq job enqueued
     │  202 { remote_saga_id: "..." }   │
     │ ◄────────────────────────────── │
     :                                  :
     :               (later)            :
     :                                  │ Sidekiq worker runs
     :                                  │ → executor resumes_execution
     :                                  │ → saga completes (Success/Failure)
     :                                  │ → emit_lifecycle_completion(:complete_reactor, ...)
     :                                  │ → RemoteCallbackMiddleware#on_complete_reactor
     :                                  │ → callback_sender.call(callback_url, body)
     │                                  │
     │  POST /ruby_reactor/callback ◄── │
     │  (from callback_sender)          │
     │ saga resumes on local side       │
```
