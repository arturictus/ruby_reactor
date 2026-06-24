# Research: Cross-Service Reactor Sagas

**Phase 0 output** — all design alternatives evaluated, decisions recorded.

---

## 1. DSL Keyword — Name

### Alternatives considered

- `remote` — short, reads naturally; could imply any remote call, not just saga
- `external` — matches branch naming; adjective without a noun (`external` what?)
- `call_remote` — explicit verb; verbose, inconsistent with `step`/`compose`/`map` nouns
- `bridge` — evocative of crossing service boundaries; too metaphorical
- `saga_call` — domain-accurate; redundant since every step is saga-scoped
- `connect` — suggests a persistent connection, not a step

**Decision**: `remote`

**Rationale**: Consistent with the one-word pattern of existing DSL keywords (`step`, `compose`, `map`, `interrupt`). Reads naturally in a reactor body: `remote :charge_payment, ChargePayment`.

---

## 2. Core Mechanic — `remote` = `step` + `interrupt`

### Key insight

`remote` is not a new primitive — it is a **fusion of two existing primitives**:

- **`step` part**: The user writes the outbound call in `call(args, context)`. The gem does not wrap HTTP, gRPC, or any protocol. The user uses whatever client they already have (Faraday, HTTParty, gRPC stubs, Kafka producer, etc.).
- **`interrupt` part**: After `call` returns `Success`, the gem automatically pauses the local saga (exactly as `interrupt` does) and waits for the inbound callback signal.

The gem's job is:
1. Inject `callback_url` into `args` before `call` runs (so the user can pass it to the remote)
2. After `call` returns `Success`: pause (return `InterruptResult`)
3. After `call` returns `Failure`: propagate failure immediately (no pause)
4. Resume when callback arrives at `POST /ruby_reactor/callback/:execution_id/:step_name`

### What the gem does NOT do

- No HTTP client
- No transport adapter
- No outbound protocol wrapping
- No retry of the outbound call (the user controls retry in their `call` method or via the existing `retries` DSL on the step)

### Why this is correct

Existing HTTP wrappers (Faraday, HTTParty) are mature, well-tested, and already in users' apps. Reimplementing connection pooling, retries, TLS, auth, timeouts, and content negotiation inside the gem would be out of scope and would compete with what users already have. The gem's value is the pause/resume lifecycle, not the HTTP layer.

---

## 3. DSL Interface — Step Authoring Style

### Class-based (preferred per constitution)

```ruby
class ChargePayment
  include RubyReactor::RemoteStep

  def self.call(args, context)
    # args[:callback_url] injected by the gem
    result = MyHTTPClient.post(
      "https://payment.internal/ruby_reactor/trigger",
      reactor_name: "PaymentReactor",
      inputs: { amount: args[:order_total], currency: "USD" },
      callback_url: args[:callback_url]
    )

    if result.status.success?
      Success({ remote_saga_id: result.body[:remote_saga_id] })
    else
      Failure("Payment trigger failed: #{result.status}")
    end
  end

  def self.compensate(_reason, _args, _ctx) = Success()
  def self.undo(_result, _args, _ctx)        = Success()
end

# Used in reactor:
remote :charge_payment, ChargePayment do
  wait_for :create_order
  argument :order_total, from(:order_total)
end
```

### Block-only DSL (simple cases)

```ruby
remote :charge_payment do
  wait_for :create_order
  argument :order_total, from(:order_total)

  run do |args, _ctx|
    result = MyHTTPClient.post(
      "https://payment.internal/ruby_reactor/trigger",
      inputs: { amount: args[:order_total] },
      callback_url: args[:callback_url]
    )
    result.success? ? Success() : Failure("trigger failed")
  end

  compensate { |_reason, _args, _ctx| Success() }
end
```

**Decision**: Class-based preferred (matches constitution). Block form allowed for simple cases. Identical to how `step` works today — same authoring patterns, no new conventions.

### Interface contract for `RemoteStep`

```ruby
module RubyReactor
  module RemoteStep
    module ClassMethods
      # The trigger. Receives resolved args + gem-injected :callback_context.
      # Returns Success (saga pauses) or Failure (saga compensates, no pause).
      def call(args, context); end

      # Local compensation when remote signals failure or local saga fails.
      def compensate(reason, args, context) = Success()

      # Reverse a successful trigger (e.g. ask remote to cancel).
      def undo(result, args, context) = Success()
    end
  end
end
```

---

## 4. Callback Context Injection

### Problem

The user's `call` method needs routing information to pass to the remote service. For HTTP this is a URL; for Kafka it is a topic + routing key; for gRPC it may be a routing envelope. A bare `callback_url` string is insufficient for non-HTTP transports and also makes logging/tracing harder since the step can't inspect `execution_id` separately.

### Solution: `CallbackContext` value object

The gem builds a `CallbackContext` struct and injects it as `args[:callback_context]` before `call` runs. The user extracts what the remote needs.

```ruby
# RubyReactor::CallbackContext (value object)
{
  callback_url:  "https://orders.internal/ruby_reactor/callback/ctx_abc/charge_payment",
  execution_id:  "ctx_abc",
  step_name:     "charge_payment"
}
```

The step uses what it needs:

```ruby
def self.call(args, _context)
  cb = args[:callback_context]

  # HTTP remote: pass callback_url
  Faraday.post("https://payment.internal/ruby_reactor/trigger",
    JSON.generate(inputs: { amount: args[:order_total] },
                  callback_url: cb.callback_url))

  # OR Kafka remote: pass execution_id + step_name as routing key
  KafkaProducer.produce("payment-triggers",
    inputs: { amount: args[:order_total] },
    callback_routing: { execution_id: cb.execution_id, step_name: cb.step_name })

  Success()
end
```

### `callback_url` construction

```
"#{config.callback_host}/ruby_reactor/callback/#{execution_id}/#{step_name}"
```

`config.callback_host` is the only new gem-level configuration required.

### Decision: Inject `args[:callback_context]` (struct with `callback_url`, `execution_id`, `step_name`)

**Rationale**: Richer than a bare URL, transport-agnostic, inspectable for logging. The user picks the fields the remote needs. Adding fields to `CallbackContext` in future (e.g. an HMAC token) is non-breaking.

---

## 5. Inbound Router (Callback Receiver)

### Responsibility

The gem provides one inbound route only:

```
POST /ruby_reactor/callback/:execution_id/:step_name
Body: { status: "success"|"failure", payload: {...}, error: "..." }
```

This is the only network boundary the gem owns. It resumes the waiting local saga.

### For RubyReactor-powered remote services (optional convenience)

The gem also exposes:

```
POST /ruby_reactor/trigger
Body: { reactor_name: "...", inputs: {...}, callback_url: "..." }
```

This is a convenience endpoint so a remote RubyReactor service can receive triggers without writing glue code. The remote's user mounts the router, and the trigger endpoint auto-starts the named reactor and fires the callback when the saga completes. This endpoint is entirely optional — the remote can implement trigger acceptance however it wants.

### Mounting

```ruby
# Rails
mount RubyReactor::Web::Router, at: "/ruby_reactor"

# Rack / Roda
run Rack::URLMap.new("/ruby_reactor" => RubyReactor::Web::Router, "/" => MyApp)
```

`RubyReactor::Web::Router` sits alongside the existing `Web::Application` (dashboard).

### Decision: Callback route is mandatory; trigger route is optional convenience

---

## 6. Remote Service Compatibility — RubyReactor vs. Generic

From the gem's perspective, both are identical: the user's `call` method fires; the gem pauses; a callback arrives; the gem resumes. The distinction lives entirely in the user's code.

**RubyReactor remote**: User POSTs to `/ruby_reactor/trigger` on the remote. The remote runs the reactor and sends the callback automatically (via the router's completion hook).

**Generic remote**: User calls any endpoint. The remote does its work and POSTs to `callback_url`. No RubyReactor knowledge required on the remote side. The minimal contract: receive a request, do work, POST `{ status, payload }` to `callback_url`.

No special gem support needed for either mode. The gem doesn't know or care which mode is in use.

---

## 7. Contract Enforcement

### Decision: Inline `validate_payload` on the step (same as `interrupt`)

The callback payload is validated using the same `validate_payload` block already available on interrupt steps. For the outbound trigger payload, the remote's existing `input` declarations validate it (for RubyReactor remotes) or the user validates it in their `call` method (for generic remotes).

No shared contract gem needed for v1. JSON Schema files recommended for cross-language remotes where dry-schema isn't available.

---

## 8. Service Registry — Simplified

### Decision: Not needed for outbound calls

Since the user's `call` method handles all outbound communication, there is no "remote service descriptor" for the gem to manage. URLs, auth, and transport config live in the user's app (environment variables, Rails credentials, Faraday config, etc.).

The only gem-level config is `callback_host` (section 4).

A named registry (like `config.remote_services.register`) may be useful for documentation and observability (step metadata showing which "service" a remote step is associated with), but it is **not required for routing or transport**. Defer to v2 if needed.

---

## 9. Crash Recovery for Waiting Steps

Same as interrupt steps — the sweeper already handles paused contexts. No new logic needed.

---

## 10. Idempotency and Duplicate Signals

Guarded by existing `continue` path: `intermediate_results.key?(step_name)` before resuming. Duplicate callbacks are no-ops returning `200 { resumed: false, reason: "already_completed" }`.

---

## 11. Polling as an Alternative Trigger Pattern

### Problem

Callback-based communication assumes the remote can reach the local service. This fails when:

- The remote is behind a firewall with no outbound access
- The remote is a third-party API (payment processors, export services, ML inference) that returns a job ID and exposes a status endpoint
- The remote has no webhook support

### Decision: Independent `poll` step — deferred to v2

A standalone `poll` step (separate DSL keyword) that: pauses the saga, schedules a Sidekiq job that re-polls an endpoint on an interval, and resumes when a caller-defined condition is met.

```ruby
poll :await_export_ready do
  every 10.seconds
  max_attempts 60

  check do |args, _ctx|
    MyHTTPClient.get("https://reports.internal/jobs/#{args[:job_id]}/status")
  end

  until { |response, _ctx| response[:status] == "ready" }
  extract { |response, _ctx| { download_url: response[:url] } }

  compensate { |_reason, _args, _ctx| Success() }
end
```

The user writes their own check call. The gem provides the scheduling + pause/resume lifecycle. Orthogonal to `remote` — useful for any polling pattern, not just cross-service sagas.

**YAGNI boundary**: ship `remote` (callback-based) in this MINOR. `poll` is a separate task.

---

## 12. `/trigger` Completion Callback Mechanism

### Problem

When `POST /trigger` arrives, the router calls `reactor_class.run(inputs)`. For
an async reactor, `run` returns `AsyncResult` immediately — the Sidekiq worker
handles the saga later. There was no specified mechanism for the router to fire
the `callback_url` when the saga eventually completes (which may be after
multiple interrupt/resume cycles).

### Decision: `RemoteCallbackMiddleware` + `private_data` + `complete_reactor` hook

Three existing pieces compose cleanly:

1. **`context.private_data`** (already serialized to Redis) — the trigger handler
   stores `callback_url` here before `run`:

   ```ruby
   context = Context.new(inputs, klass)
   context.private_data[:remote_callback_url] = callback_url
   reactor = klass.new(context)
   reactor.run(inputs)
   ```

   Because `save_context` runs BEFORE Sidekiq enqueue (F2 guarantee), the URL
   survives async hand-off and is present when the worker rehydrates the context.

2. **`complete_reactor` middleware event** (already emitted by `Executor`) — fires
   in the `ensure` block of both `execute` and `resume_execution` after every
   saga run, including resumed runs after interrupts.

3. **`RemoteCallbackMiddleware`** (new, ~15 lines) — hooks `on_complete_reactor`,
   checks for `private_data[:remote_callback_url]`, and fires only on terminal
   results (Success or Failure). InterruptResult means the remote saga paused
   mid-flight on its own interrupt steps — the middleware does nothing then and
   waits for the next terminal `complete_reactor` event.

### Why `complete_reactor` fires at the right time

`Executor#emit_lifecycle_completion` (executor.rb:153) calls
`middlewares.on(:complete_reactor, ...)` whenever `completed = true`. The
`completed` flag is set after `execute_all_steps` returns AND after
`handle_interrupt`. So it fires for every result type — the middleware simply
filters on `Success | Failure` to ignore paused states.

### Completion callback transport

The middleware calls `RubyReactor.configuration.callback_sender.call(url, body)`.
Default: stdlib `net/http`. Override in config to inject auth, custom TLS, or
retry logic. No new gem dependency.

### Registration

The router registers `RemoteCallbackMiddleware` in `RubyReactor.configuration.middlewares`
when it is first loaded (idempotent). Services that do not mount the router are
unaffected. Services that do mount it pay one nil-check per reactor completion
for non-triggered reactors.

### Full spec

See [contracts/router.md](./contracts/router.md) for the complete router
specification including mount interface, security guards, error handling, and
sequence diagrams.

---

## Resolved NEEDS CLARIFICATION

- **DSL keyword name** — `remote`
- **Core mechanic** — `remote` = `step` (user's trigger code) + `interrupt` (gem's pause/resume)
- **Transport / HTTP wrapper** — not in gem; user uses their own HTTP client in `call`
- **callback_context injection** — gem injects `args[:callback_context]` (struct: `callback_url`, `execution_id`, `step_name`); `callback_url` built from `config.callback_host`
- **Non-RubyReactor remote** — fully supported; user calls any endpoint in `call`; remote POSTs to `callback_url`
- **gRPC / Kafka / pubsub** — user uses those clients in `call`; gem stays protocol-agnostic
- **Contract enforcement** — inline `validate_payload` on step; JSON Schema for cross-language remotes
- **Inbound router** — `RubyReactor::Web::Router`; `/callback` mandatory, `/trigger` optional convenience; full spec in [contracts/router.md](./contracts/router.md)
- **Service registry** — not needed for v1; `config.callback_host` is the only gem-level config required
- **Crash recovery** — existing interrupt + sweeper machinery; no new logic
- **Duplicate callback** — guarded by existing `continue` idempotency check
- **Trigger completion hook** — `RemoteCallbackMiddleware` + `private_data[:remote_callback_url]` + `complete_reactor` event; see section 12
- **Trigger security** — `Object.const_get` guarded by `< RubyReactor::Dsl::Reactor` check; see [contracts/router.md](./contracts/router.md)
- **callback_sender config** — `config.callback_sender` proc (default: stdlib `net/http`); overridable for auth/TLS/retry
- **Polling alternative** — independent `poll` step; deferred to v2; callback is v1
