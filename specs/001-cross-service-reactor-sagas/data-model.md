# Data Model: Cross-Service Reactor Sagas

**Phase 1 output** — entities, fields, relationships, state transitions.

---

## Entities

### 1. `RemoteStepConfig`

DSL configuration object produced by `RemoteBuilder#build`. Stored in the reactor's `steps` hash alongside `StepConfig` and `InterruptStepConfig`. Extends `StepConfig` — all existing wiring (`arguments`, `dependencies`, `conditions`, `guards`) is inherited.

```text
RemoteStepConfig  (extends StepConfig)
├── validate_payload : Schema | nil    # dry-schema for callback payload validation
├── timeout_config   : Hash | nil      # { duration: Integer, strategy: :lazy | :eager }
├── compensate_block : Proc | nil      # local compensation logic
└── undo_block       : Proc | nil      # undo a successful trigger
```

`RemoteStepConfig` has no service registry reference. The user's `call` method handles all outbound routing. The gem only manages the pause/resume lifecycle.

---

### 2. `CrossServiceContext` (stored in Redis)

Written when a `remote` step fires and the saga pauses. Cleared on step completion.

```text
CrossServiceContext
├── execution_id  : String    # local saga's context_id (UUID)
├── step_name     : Symbol    # which remote step is waiting
├── triggered_at  : Time      # when call() returned Success
├── callback_url  : String    # the URL injected into args[:callback_context].callback_url
└── trigger_ref   : Hash|nil  # whatever call() returned (e.g. { remote_saga_id: "..." })
```

**Storage**: Redis key `ruby_reactor:remote:<execution_id>:<step_name>`, TTL = `config.context_ttl`.

`trigger_ref` is the `Success` value returned by the user's `call` method — the gem stores it for observability (dashboard can show `remote_saga_id` if the user returns it).

---

### 3. `CrossServiceResult`

The payload delivered to the local saga when the callback arrives. Available in subsequent steps as the step's result value.

```text
CrossServiceResult
├── status  : Symbol      # :success | :failure
├── payload : Hash        # data returned by the remote (user-defined shape)
└── error   : String|nil  # failure message (when status = :failure)
```

**Validation**: `RemoteStepConfig.validate_payload` schema (if defined) is applied to `payload` before the step is marked complete. Same mechanism as `interrupt`'s `validate_payload`.

---

### 4. `CallbackContext`

Value object built by the gem and injected as `args[:callback_context]` before the user's `call` method runs. Contains all routing information the remote service needs to call back.

```text
CallbackContext
├── callback_url  : String   # "#{callback_host}/ruby_reactor/callback/#{execution_id}/#{step_name}"
├── execution_id  : String   # local saga's context_id
└── step_name     : String   # name of the waiting remote step
```

**Usage in step**:

```ruby
def self.call(args, _context)
  cb = args[:callback_context]

  # HTTP: use callback_url directly
  MyHTTP.post(remote_url, inputs: { ... }, callback_url: cb.callback_url)

  # Kafka / gRPC: use execution_id + step_name as routing key
  KafkaProducer.produce("triggers",
    inputs: { ... },
    callback_routing: { execution_id: cb.execution_id, step_name: cb.step_name })

  Success()
end
```

**Configuration** (only new gem-level config needed):

```ruby
RubyReactor.configure do |config|
  config.callback_host = "https://orders.internal"
end
```

---

## State Transitions for a `remote` Step

```text
[ready]
  │  DAG dependency satisfied
  ▼
[call() executing]
  │  User's code runs — HTTP, gRPC, queue, anything
  │
  ├─ Failure ──────────────► [failed] → local compensation chain
  │
  └─ Success
       │
       ▼
[waiting / paused]    ← InterruptResult written; local saga suspended
  │
  ├─[timeout]──────────────► [timed_out] → local compensation chain
  │
  └─[callback received at /ruby_reactor/callback/:id/:step]
       │
       ├─ status=success ──► [completed] → next local step gets CrossServiceResult
       │
       └─ status=failure ──► [failed]    → local compensation chain
```

---

## Redis Key Layout (new keys)

```text
ruby_reactor:remote:<execution_id>:<step_name>
  TTL: context_ttl
  Value: JSON CrossServiceContext
  Purpose: observability; cleared when step completes
```

No trigger-mapping key is needed. The callback URL encodes `execution_id` and `step_name` directly, so the router can resume without a lookup table.

---

## Entity Relationships

```text
RubyReactor::Configuration
  └── callback_host : String            # base URL for callback_url generation

ReactorClass.steps
  └── [step_name] : RemoteStepConfig
        └── impl  ──► RemoteStep subclass (or run_block)

Context (Redis)
  └── intermediate_results[step_name] ──► CrossServiceResult  (on completion)
  └── ruby_reactor:remote:*           ──► CrossServiceContext  (while waiting)
```

---

## Observability Fields (dashboard + logs)

The local web dashboard step view gains these fields for `remote` step type:

- `type`: `"remote"`
- `triggered_at`: ISO8601 timestamp (from `CrossServiceContext`)
- `callback_url`: host+path only (redacted in UI)
- `trigger_ref`: the `Success` value from `call()` — e.g. `{ remote_saga_id: "..." }` if user returns it
- `status`: one of the state machine values above

Structured log on `call()` Success (step pausing):

```json
{ "event": "remote_step_triggered", "execution_id": "...", "step": "...", "triggered_at": "..." }
```

Structured log on callback received:

```json
{ "event": "remote_step_callback", "execution_id": "...", "step": "...",
  "status": "success", "duration_ms": 1234 }
```
