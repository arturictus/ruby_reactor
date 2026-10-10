# Contract: Dashboard API

The changes are additive. Requests without filters behave exactly as today on both adapters.

## `GET /api/capabilities` (new)

```json
{ "execution_query": true }
```

`execution_query` is `storage_adapter.respond_to?(:query_executions)`. It is `false` on Redis. The GUI renders the filter bar only when it is `true` (FR-022).

## `GET /api/reactors` (extended)

| param | type | notes |
|---|---|---|
| `limit` | int | unchanged: default 50, capped at 500 |
| `cursor` | string | unchanged; opaque, `"0"` = first page |
| `class` | string | exact reactor class name |
| `status` | string | one of `pending running paused completed failed rolling_back halted aborted cancelled` |
| `from`, `to` | ISO-8601 | inclusive bounds on `started_at` |
| `input[<name>]` | string | equality on an indexed top-level input. Repeat the param for several inputs (AND). |

- **No filter params**: unchanged. Calls `scan_reactors_page`; the body is a bare array and `X-Next-Cursor` is the header.
- **Any filter param on AR**: calls `query_executions`. The body has the same bare-array shape and fields (`id, class, status, created_at, failure`). The order is `started_at DESC, id DESC`, and `X-Next-Cursor` is an opaque keyset cursor (`"0"` = end).
- **Any filter param on Redis**: `422 {"error": "filters require the active_record storage adapter"}`.
- **A filter on a redacted input, or an input that is not indexed**: matches nothing. The API doesn't distinguish the two cases, so redacted inputs can't be probed (FR-021).
- **Invalid `status` or date**: `400 {"error": "…"}`.

## `GET /api/reactors/:id` (behavior change)

`inputs` is shown with every input declared `redact: true` replaced by `"[REDACTED]"`, on both adapters (FR-021). The stored context is unchanged; only the API view masks values.
