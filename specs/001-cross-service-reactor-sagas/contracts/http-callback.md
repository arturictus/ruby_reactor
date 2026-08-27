# Contract: HTTP Callback Endpoint

**Direction**: Remote service → Local service

**Route**: `POST /ruby_reactor/callback/:execution_id/:step_name`

Implemented by `RubyReactor::Web::Router` in the local service. The remote calls this URL when its work completes (success or failure).

The `callback_url` delivered in the trigger body resolves to this endpoint with the `execution_id` and `step_name` already embedded in the path.

---

## Request

### Headers

```
Content-Type: application/json
```

No auth by default. The execution_id + step_name tuple acts as a bearer token (unforgeable without knowledge of the local context ID). For stricter security, HMAC signing can be added as a transport option.

### Path Parameters

| Parameter      | Type   | Description                                     |
| -------------- | ------ | ----------------------------------------------- |
| `execution_id` | String | The local saga's context ID.                    |
| `step_name`    | String | The name of the waiting `remote` step.          |

### Body

```json
{
  "status":  "success",
  "payload": {
    "transaction_id": "txn_789",
    "charged_amount": 9900
  }
}
```

Or on failure:

```json
{
  "status":  "failure",
  "error":   "Insufficient funds",
  "payload": {
    "decline_code": "insufficient_funds"
  }
}
```

| Field     | Type                     | Required | Description                                                          |
| --------- | ------------------------ | -------- | -------------------------------------------------------------------- |
| `status`  | `"success"` \| `"failure"` | Yes    | Outcome of the remote work.                                          |
| `payload` | Object                   | No       | Result data (success) or supplementary failure context (failure).    |
| `error`   | String                   | No       | Human-readable failure message. Required when `status = "failure"`.  |

---

## Response

### 200 OK — saga resumed

```json
{ "resumed": true }
```

### 404 Not Found — unknown execution_id or step

```json
{ "error": "Reactor not found" }
```

Happens when:

- The local saga has already completed (stale callback)
- The `execution_id` was purged from Redis (TTL expired)

### 422 Unprocessable Entity — payload validation failed

```json
{
  "error":  "Payload validation failed",
  "fields": { "transaction_id": ["is missing"] }
}
```

Returned when the `RemoteStepConfig.validate_payload` schema rejects the callback body. The local saga's step is marked as failed and compensation runs.

### 409 Conflict — duplicate callback

When the step is already completed (idempotency guard hit), the router returns:

```json
{ "resumed": false, "reason": "already_completed" }
```

with status `200` (not an error — the callback was valid, just redundant).

---

## Resume Behaviour

On receiving a valid callback:

1. Router deserialises the local reactor context from Redis
2. Writes `payload` into `context.intermediate_results[step_name]`
3. If `status = "failure"`, wraps payload in a `Failure` result
4. Calls `reactor_class.continue(id: execution_id, step_name: step_name, payload: payload)`
5. Local saga resumes from the waiting step

If `validate_payload` is defined on the step, validation runs before `continue`. Validation failure marks the step as failed (not as a router error).

---

## Non-RubyReactor Remote — Sending the Callback

Any HTTP client can call this endpoint. Minimal Ruby example:

```ruby
require "net/http"
require "json"

uri = URI(callback_url)
Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") do |http|
  req = Net::HTTP::Post.new(uri, "Content-Type" => "application/json")
  req.body = JSON.generate(status: "success", payload: { transaction_id: "txn_789" })
  http.request(req)
end
```

No RubyReactor knowledge required. The remote only needs the `callback_url` it received in the trigger body.

---

## For RubyReactor-Powered Remotes

When the remote service also runs RubyReactor, the callback is sent automatically by a completion middleware hook registered during router setup. The remote developer makes no changes to their reactor — the hook fires transparently after any saga run triggered via `/ruby_reactor/trigger`.
