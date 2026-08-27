# Contract: HTTP Trigger (Optional Convenience Endpoint)

**Direction**: Local service → Remote service (when remote is RubyReactor-powered)

**Route**: `POST /ruby_reactor/trigger`

This endpoint is an **optional convenience** implemented by `RubyReactor::Web::Router`. A remote RubyReactor service can mount it so that it auto-starts the named reactor and fires the callback on completion — zero glue code required.

For generic remotes (non-RubyReactor), the user calls whatever endpoint the remote exposes, passing `callback_url` from `args[:callback_url]`. The remote does not need to implement this contract.

---

## Request

### Headers

```http
Content-Type: application/json
Authorization: Bearer <token>    # optional — handled by the user's HTTP client
```

### Body

```json
{
  "reactor_name": "PaymentReactor",
  "inputs": {
    "order_id": "ord_123",
    "amount":   9900,
    "currency": "USD"
  },
  "callback_url": "https://orders.internal/ruby_reactor/callback/ctx_abc/charge_payment"
}
```

| Field          | Type         | Required | Description                                                                 |
| -------------- | ------------ | -------- | --------------------------------------------------------------------------- |
| `reactor_name` | String       | Yes      | Ruby constant name of the remote reactor to start.                          |
| `inputs`       | Object       | Yes      | Inputs passed to the remote reactor.                                        |
| `callback_url` | String (URL) | Yes      | Where to POST the result when the remote saga completes.                    |

The `callback_url` value comes from `args[:callback_context].callback_url` injected by the gem — the user passes it through unchanged.

---

## Response

### 202 Accepted

```json
{ "remote_saga_id": "ctx_xyz", "status": "accepted" }
```

The user's `call` method may capture `remote_saga_id` and return it in `Success`:

```ruby
def self.call(args, _context)
  cb = args[:callback_context]
  result = Faraday.post("https://payment.internal/ruby_reactor/trigger",
                        JSON.generate(reactor_name: "PaymentReactor",
                                      inputs: { amount: args[:order_total] },
                                      callback_url: cb.callback_url),
                        "Content-Type" => "application/json")
  body = JSON.parse(result.body, symbolize_names: true)
  result.status == 202 ? Success(body) : Failure("trigger failed: #{result.status}")
end
```

The returned `Success` value is stored as `trigger_ref` in `CrossServiceContext` for observability.

### 422 Unprocessable Entity

```json
{ "error": "Input validation failed", "fields": { "amount": ["must be greater than 0"] } }
```

### 404 Not Found

```json
{ "error": "Reactor 'UnknownReactor' not found" }
```

---

## Completion Callback (remote → local)

When the remote RubyReactor saga completes, the router fires:

```http
POST <callback_url>
Body: { "status": "success", "payload": { ... } }
```

This is handled automatically by the router's completion middleware. The remote developer makes no changes to their reactor.

---

## Generic Remote — No Contract Required

For a non-RubyReactor remote, the user's `call` method calls any endpoint the remote exposes. The only requirement: the remote must eventually POST to `callback_url` with `{ status, payload }`. See [http-callback.md](./http-callback.md) for the callback contract.
