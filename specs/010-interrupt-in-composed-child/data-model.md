# Data Model: Interrupt Inside a Composed Child

No new storage keys or records. One new `private_data` flag; everything else is derived from state
that is already stored.

## Root context (stored row, unchanged shape)

| Field | While paused inside a child | Notes |
| --- | --- | --- |
| `status` | `paused` | Set by `update_context_status` on the root's `InterruptResult`. |
| `current_step` | the compose step name (e.g. `:fulfil`) | Set by the `ResultHandler` interrupt arm (R-03). |
| `composed_contexts[:fulfil]` | `{ name:, type: :composed, context: <child> }` | Child embedded as today. |
| `undo_stack` | ends with the compose step, `result: Success(nil)` | Partial-run entry (R-04). It is replaced, not duplicated, when the compose completes. |
| `private_data[:interrupt_attempts]` | keyed by `:"fulfil.approve"` (a Symbol) for a nested interrupt | Root-level interrupts keep their own name as the key (R-06). |

## Child context (embedded in the root, and its own observability row)

| Field | While paused | Notes |
| --- | --- | --- |
| `status` | `paused` | As today, set by the child's executor. |
| `current_step` | the interrupt (e.g. `:approve`), or the next compose one level down | |
| `intermediate_results[:approve]` | the payload, once `continue` accepted it | Written to the embedded child, never the observability row. |
| `private_data[:composed]` | `true` | **New.** Set when the compose step creates the child; refuses a direct `continue` (R-07). |

## Step path (value object, not stored)

`Array` of two or more step names: the compose steps from the root, then the interrupt. It is
normalized to Symbols on input. A one-element array is the same as the bare name.

## State transitions (root)

```text
running ──child reaches interrupt──▶ paused
paused ──continue(path, valid payload)──▶ running ──▶ completed | failed | paused (next interrupt)
paused ──continue(path, payload, resume: :background)──▶ running (worker) ──▶ …
paused ──continue(path, invalid payload, attempts exhausted)──▶ undo ──▶ failed
paused ──undo──▶ cancelled        paused ──cancel──▶ cancelled
```

The child mirrors `paused → running → completed` inside the root and is never resumed on its own.
