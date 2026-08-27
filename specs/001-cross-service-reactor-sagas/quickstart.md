# Quickstart Validation Guide: Cross-Service Reactor Sagas

**Phase 1 output** — runnable scenarios that prove the feature works end-to-end.

See [data-model.md](./data-model.md) for entity definitions and [contracts/](./contracts/) for the callback HTTP API.

---

## Prerequisites

```bash
# Redis running (required for all scenarios)
docker compose up -d redis

# Sidekiq running (required for async scenarios)
bundle exec sidekiq -r ./spec/support/remote_reactors.rb
```

---

## How `remote` works

`remote` = `step` (user's trigger code) + `interrupt` (gem's pause/resume).

The gem injects `args[:callback_context]` before `call` runs — a value object with `callback_url`, `execution_id`, and `step_name`. The user picks the fields the remote needs. When the remote POSTs to `callback_url`, the local saga resumes. The user's HTTP client (Faraday, HTTParty, etc.) is used directly in `call` — the gem does not wrap it.

---

## Scenario 1 — RubyReactor-to-RubyReactor

**Goal**: Local saga triggers a remote RubyReactor saga and resumes with its result.

### Setup

```ruby
# Remote reactor (lives in the payment service)
class PaymentReactor
  include RubyReactor::Reactor

  input :amount
  input :currency

  step :charge do
    run { |args, _ctx| Success({ transaction_id: "txn_#{args[:amount]}" }) }
  end

  returns :charge
end

# Configuration (local service initializer)
RubyReactor.configure do |config|
  config.callback_host = "https://orders.internal"
end

# Local step — user writes the HTTP call with their own client
class ChargePayment
  include RubyReactor::RemoteStep

  def self.call(args, _context)
    cb = args[:callback_context]
    # cb.callback_url => "https://orders.internal/ruby_reactor/callback/<id>/charge_payment"
    # cb.execution_id => local saga context_id (useful for logging)
    # cb.step_name    => "charge_payment"
    result = Faraday.post(
      "https://payment.internal/ruby_reactor/trigger",
      JSON.generate(
        reactor_name: "PaymentReactor",
        inputs:       { amount: args[:order_total], currency: "USD" },
        callback_url: cb.callback_url
      ),
      "Content-Type" => "application/json"
    )
    body = JSON.parse(result.body, symbolize_names: true)
    result.status == 202 ? Success(body) : Failure("trigger failed: #{result.status}")
  end

  def self.compensate(_reason, _args, _ctx) = Success()
end

# Local reactor
class OrderReactor
  include RubyReactor::Reactor

  input :order_total

  step :create_order do
    run { |args, _ctx| Success({ order_id: "ord_#{args[:order_total]}" }) }
  end

  remote :charge_payment, ChargePayment do
    wait_for :create_order
    argument :order_total, from(:order_total)
  end

  step :confirm_order do
    wait_for :charge_payment
    run do |_args, ctx|
      txn = ctx.get_result(:charge_payment)
      Success({ confirmed: true, transaction_id: txn[:transaction_id] })
    end
  end

  returns :confirm_order
end
```

### Run (single-process with stub)

```ruby
# Stub the outbound HTTP call; deliver the callback inline
stub_remote_http(:charge_payment) do |callback_url, _payload|
  HTTP.post(callback_url,
    json: { status: "success", payload: { transaction_id: "txn_9900" } })
end

result = OrderReactor.run(order_total: 9900)
expect(result).to be_success
expect(result.value[:transaction_id]).to eq "txn_9900"
```

### Expected outcome

- `create_order` runs
- `ChargePayment.call` fires (HTTP stubbed); local saga pauses
- Stub delivers callback to `/ruby_reactor/callback/:id/charge_payment`
- Saga resumes; `confirm_order` runs with `transaction_id`

---

## Scenario 2 — Generic Remote (Non-RubyReactor)

**Goal**: Local saga triggers a generic service that knows nothing about RubyReactor.

```ruby
class ArrangeShipment
  include RubyReactor::RemoteStep

  def self.call(args, _context)
    cb = args[:callback_context]
    # Shipping service speaks its own API — user adapts
    result = ShippingClient.create_shipment(
      order_id:     args[:order_id],
      items:        args[:items],
      callback_url: cb.callback_url   # remote must POST here when done
    )
    result.ok? ? Success({ shipment_ref: result.ref }) : Failure(result.error)
  end

  def self.compensate(_reason, _args, _ctx) = Success()
end
```

The shipping service receives `callback_url` and POSTs back when the shipment is arranged:

```http
POST https://orders.internal/ruby_reactor/callback/ctx_abc/arrange_shipment
Content-Type: application/json

{ "status": "success", "payload": { "tracking_number": "1Z999AA10123456784" } }
```

No RubyReactor knowledge required in the shipping service.

---

## Scenario 3 — Remote Saga Failure → Local Compensation

**Goal**: When remote signals failure, local saga compensates correctly.

```ruby
stub_remote_http(:charge_payment) do |callback_url, _payload|
  HTTP.post(callback_url,
    json: { status: "failure", error: "Insufficient funds",
            payload: { decline_code: "insufficient_funds" } })
end

result = OrderReactor.run(order_total: 9900)

expect(result).to be_failure
expect(result.error).to include("Insufficient funds")
# Confirm create_order compensation ran (check undo_stack or side-effect log)
```

---

## Scenario 4 — Crash Recovery

**Goal**: Saga survives process restart while waiting for callback.

```ruby
# 1. Run until pause
result = OrderReactor.run(order_total: 9900)
expect(result).to be_a(RubyReactor::InterruptResult)
execution_id = result.execution_id

# 2. Simulate restart — reload context from Redis
reactor = OrderReactor.find(execution_id)
expect(reactor.context.current_step).to eq :charge_payment

# 3. Deliver callback (as if remote called back after restart)
OrderReactor.continue(
  id: execution_id,
  step_name: :charge_payment,
  payload: { status: "success", payload: { transaction_id: "txn_999" } }
)

# 4. Verify completion
reactor.reload
expect(reactor.context.status).to eq :completed
```

---

## Scenario 5 — Dashboard Observability

```ruby
result = OrderReactor.run(order_total: 9900)
execution_id = result.execution_id

# Query dashboard API
get "/api/reactors/#{execution_id}"
```

Expected step entry:

```json
{
  "name": "charge_payment",
  "type": "remote",
  "triggered_at": "2026-06-24T10:00:00Z",
  "callback_url": "https://orders.internal/ruby_reactor/callback/...",
  "trigger_ref": { "remote_saga_id": "ctx_xyz" },
  "status": "waiting"
}
```

---

## Scenario 6 — Two Parallel Remote Steps (DAG)

```ruby
class FulfillOrder
  include RubyReactor::Reactor

  input :order_id

  remote :arrange_shipment, ArrangeShipment do
    argument :order_id, from(:order_id)
  end

  remote :send_confirmation, SendConfirmation do
    argument :order_id, from(:order_id)
  end

  step :done do
    wait_for :arrange_shipment, :send_confirmation
    run do |_args, ctx|
      Success({
        tracking: ctx.get_result(:arrange_shipment)[:tracking_number],
        email_sent: ctx.get_result(:send_confirmation)[:sent]
      })
    end
  end

  returns :done
end
```

Both remote steps fire. `done` runs only when both callbacks arrive.

---

## Running the Suite

```bash
# Unit (stub transport, inline Sidekiq)
bundle exec rspec spec/remote_step_spec.rb

# Integration (real Redis, stub HTTP)
bundle exec rspec spec/integration/cross_service_trigger_spec.rb
bundle exec rspec spec/integration/cross_service_callback_spec.rb

# HTTP end-to-end (two Rack processes)
bundle exec rspec spec/integration/http_end_to_end_spec.rb
```
