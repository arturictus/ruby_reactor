# Implementation Plan: Cross-Service Reactor Sagas

**Branch**: `external_reactors` | **Date**: 2026-06-24 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/001-cross-service-reactor-sagas/spec.md`

---

## Summary

Enable a local RubyReactor saga to trigger a saga in a remote RubyReactor-powered microservice as a named step, pause execution until the remote saga signals completion, then resume with the result — preserving saga pattern integrity, crash recovery, and observability throughout.

The mechanism builds directly on the existing interrupt (pause/resume) machinery. The new `remote` DSL keyword fuses `step` (user's outbound trigger code) with `interrupt` (gem's pause/resume lifecycle). The gem injects `args[:callback_url]` before `call` runs; the user passes it to the remote using whatever HTTP/gRPC/queue client they already have. A lightweight Rack router (`/ruby_reactor/callback`) handles the inbound completion signal and resumes the local saga.

---

## Technical Context

**Language/Version**: Ruby >= 3.0.0 (per constitution constraint)

**Primary Dependencies**:

- Sidekiq (async workers, existing)
- Redis (state, locks, existing)
- Roda (web API, existing — `lib/ruby_reactor/web/api.rb`)
- dry-validation (schema validation, existing)
- No new gem dependencies — user brings their own HTTP client

**Storage**: Redis (existing `Storage::RedisAdapter`)

**Testing**: RSpec with real Redis and real Sidekiq inline mode (per constitution Principle III)

**Target Platform**: Ruby gem, host-agnostic (Rack-compatible hosts for HTTP transport)

**Project Type**: Ruby gem — all new code via `lib/`, reachable through `require "ruby_reactor"`

**Performance Goals**: Cross-service step overhead should not exceed a round-trip HTTP call + one Redis write; no polling loops

**Constraints**:

- No new gem dependencies; user supplies their own HTTP/gRPC/queue client in `call`
- Gem stays protocol-agnostic — no transport adapter layer
- Remote service author makes zero changes to their reactor definition (FR-006, SC-006)
- All new code gem-first: no Rails/Sinatra coupling (Constitution Principle I)

**Scale/Scope**: One new DSL keyword, one new transport abstraction layer, one registry, one router endpoint; MINOR semver bump

---

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

- **I. Gem-First Design** ✅ PASS — all code in `lib/`, HTTP transport behind adapter, Rack-mountable router, no Rails coupling
- **II. Saga Pattern Integrity** ✅ PASS — remote step pauses local saga via interrupt pattern, resumes on callback, compensation declared on step; local saga never coordinates remote compensation
- **III. Test-First / Real Infrastructure** ✅ PASS — integration tests hit real Redis; real HTTP or stub transport; no Sidekiq mock for async paths
- **IV. Observability by Default** ✅ PASS — step stores remote service ID + remote saga reference in context, dashboard extended for `remote` step type, structured log on trigger and callback
- **V. YAGNI / SemVer** ✅ PASS — one transport (HTTP) ships; gRPC/Kafka/pubsub adapters added only when a second real use case exists; MINOR bump

**Post-Design Re-check**: See research.md and data-model.md for confirmed compliance.

---

## Project Structure

### Documentation (this feature)

```text
specs/001-cross-service-reactor-sagas/
├── plan.md              ← this file
├── research.md          ← Phase 0: design decisions
├── data-model.md        ← Phase 1: entities & data shapes
├── quickstart.md        ← Phase 1: validation guide
├── contracts/
│   ├── router.md        ← RubyReactor::Web::Router spec (mount, routes, completion hook)
│   ├── http-trigger.md  ← POST /ruby_reactor/trigger
│   └── http-callback.md ← POST /ruby_reactor/callback/:execution_id/:step_name
└── tasks.md             ← Phase 2 (speckit-tasks)
```

### Source Code (repository root)

```text
lib/ruby_reactor/
├── remote_step.rb                      # Module: include RubyReactor::RemoteStep
├── remote_callback_middleware.rb       # Fires callback_url on remote saga completion
├── dsl/
│   ├── remote_builder.rb               # `remote` DSL keyword builder
│   └── remote_step_config.rb           # Config object (extends StepConfig); adds remote?
├── web/
│   └── router.rb                       # Rack app: /callback + optional /trigger routes
└── configuration.rb                    # Extended: callback_host, callback_sender accessors

spec/
├── remote_step_spec.rb
├── integration/
│   ├── cross_service_trigger_spec.rb
│   └── cross_service_callback_spec.rb
└── support/
    ├── remote_reactors.rb
    └── stub_remote_http.rb  # Test helper: stub outbound + deliver callback
```

**Structure Decision**: Single-project gem layout. All new files under `lib/ruby_reactor/` and `spec/`. No new top-level directories. No transport adapter layer.

---

## Complexity Tracking

No constitution violations. All gates pass.
