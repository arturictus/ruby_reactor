# RubyReactor Sidekiq Integration - Non-Blocking Retry Implementation Plan

## Overview
This implementation plan outlines the steps to integrate Sidekiq with RubyReactor, implementing a non-blocking retry mechanism that requeues jobs instead of blocking worker threads. The implementation includes two async execution models (full reactor async and step-level async) with sophisticated retry capabilities.

**📋 Reference Documentation:**
For detailed implementation specifications, code examples, and architecture decisions, refer to:
- [`tasks/sidekiq_integration_not_blocking_queue.md`](sidekiq_integration_not_blocking_queue.md) - Complete technical specification with code samples

**Key Principles:**
- Sequential execution (no parallel steps)
- Non-blocking retries via job requeuing
- Single worker model for async execution
- Step-level retry configuration
- Regular testing throughout implementation

---

## Phase 1: Core Infrastructure Setup

### Dependencies & Configuration
- [x] Update `ruby_reactor.gemspec` to add Sidekiq and Redis dependencies
- [x] Create initial Sidekiq worker class structure
- [x] Set up basic Sidekiq configuration for the gem

### DSL Extensions for Async Support
- [x] Extend Reactor DSL with `async` class method
- [x] Extend Step DSL with `async:` option in step builder
- [x] Add `async?` methods to Reactor and StepConfig classes
- [x] **Test:** Unit tests for DSL extensions

### Retry Configuration DSL
- [x] Implement `retry` method in StepBuilder with max_attempts, backoff, base_delay options
- [x] Add `idempotent` method to StepBuilder
- [x] Implement reactor-level `retry_defaults` class method
- [x] Create StepConfig retry_config attribute handling
- [x] **Test:** Unit tests for retry configuration parsing

### Core Classes Setup
- [x] Create `RetryContext` class with step_attempts tracking
- [x] Add retry_context to Context class initialization
- [x] Implement basic serialization structure in Context
- [x] Create `RubyReactor::RetryQueuedResult` class
- [x] **Test:** Unit tests for new classes and basic serialization

---

## Phase 2: Context Serialization & Deserialization

### Enhanced Context Serialization
- [x] Implement `serialize_for_retry` method in Context
- [x] Add `deserialize_from_retry` class method in Context
- [x] Handle complex object serialization (Time, BigDecimal, custom objects)
- [x] Implement ContextSerializer utility class
- [x] Add execution metadata preservation (job_id, started_at, reactor_class)

### Retry Context Serialization
- [x] Serialize step_attempts hash
- [x] Preserve current_step, failure_reason, next_retry_at
- [x] Handle error object serialization safely
- [x] Implement deserialization with proper type restoration
- [x] **Test:** Integration tests for full context round-trip serialization

### Error Handling & Validation
- [x] Add context size validation (Redis limits)
- [x] Implement compression for large contexts if needed
- [x] Add schema versioning for forward compatibility
- [x] Handle deserialization errors gracefully
- [x] **Test:** Edge case tests for serialization limits and error conditions

---

## Phase 3: Non-Blocking Executor Implementation

### Retry Logic Foundation
- [x] Implement `calculate_backoff_delay` method with exponential/linear/fixed strategies
- [x] Add `can_retry_step?` method to RetryContext
- [x] Create `increment_attempt_for_step` method
- [x] Update `execute_step_with_retry` to use new retry context

### Job Requeuing Mechanism
- [x] Implement `requeue_job_for_step_retry` method
- [x] Add proper logging for retry attempts and delays
- [x] Integrate with Sidekiq's `perform_in` for delayed execution
- [x] Update retry context before requeuing
- [x] **Test:** Unit tests for backoff calculations and requeuing logic

### Execution Resume Logic
- [x] Implement `resume_execution` method in Executor
- [x] Add `resume_from_failed_step` method
- [x] Create `execute_remaining_steps` after successful retry
- [x] Handle final failure scenarios
- [x] **Test:** Integration tests for execution resumption scenarios

---

## Phase 4: Enhanced Sidekiq Worker

### Worker Configuration
- [x] Update RubyReactorWorker with proper sidekiq_options
- [x] Configure retry settings for infrastructure failures only
- [x] Implement `sidekiq_retries_exhausted` handler
- [x] Add proper error logging and monitoring

### Worker Execution Logic
- [x] Update `perform` method to handle serialized contexts
- [x] Integrate context deserialization
- [x] Call executor.resume_execution with proper context
- [x] Handle unexpected errors appropriately
- [x] **Test:** Worker integration tests with mocked Sidekiq

### Async Handoff Implementation
- [x] Implement full reactor async (all execution in worker)
- [x] Implement step-level async (handoff at first async step)
- [x] Ensure sequential execution in single worker
- [x] Return AsyncResult from reactor.run when appropriate
- [x] **Test:** End-to-end async execution tests

---

## Phase 5: Testing & Validation

### Unit Test Suite
- [x] Test retry configuration parsing and validation
- [x] Test context serialization/deserialization
- [x] Test backoff delay calculations
- [x] Test retry context state management
- [x] Test executor retry logic

### Integration Test Suite
- [ ] Test full reactor async execution flow
- [ ] Test step-level async handoff
- [ ] Test retry scenarios with different backoff strategies
- [ ] Test compensation and rollback in async context
- [ ] Test idempotent step handling

### Performance & Load Testing
- [ ] Compare blocking vs non-blocking retry performance
- [ ] Test worker utilization during retries
- [ ] Validate scalability with concurrent jobs
- [ ] Test memory usage with large context serialization

### Monitoring & Observability
- [ ] Implement comprehensive logging for retry attempts
- [ ] Add metrics for retry success/failure rates
- [ ] Create dashboards for retry queue monitoring
- [ ] Set up alerts for retry storm conditions

---

## Phase 6: Documentation & Examples

### API Documentation
- [ ] Document async reactor usage patterns
- [ ] Document step-level async configuration
- [ ] Document retry configuration options
- [ ] Create migration guide from sync to async

### Example Implementations
- [ ] Create complete OrderProcessingReactor example
- [ ] Create PaymentProcessingReactor example
- [ ] Create InventoryManagementReactor example
- [ ] Include retry configuration examples

### Operational Documentation
- [ ] Document monitoring and alerting setup
- [ ] Create troubleshooting guide for common issues
- [ ] Document performance tuning recommendations
- [ ] Create capacity planning guidelines

---

## Risk Mitigation & Rollback Plan

### Risk Assessment
- [ ] Identify context size limits and mitigation strategies
- [ ] Plan for serialization complexity handling
- [ ] Design circuit breakers for retry storms
- [ ] Create state consistency validation

### Rollback Strategy
- [ ] Ensure backward compatibility with existing sync reactors
- [ ] Create feature flags for gradual rollout
- [ ] Plan for data migration if needed
- [ ] Test rollback procedures

---

## Success Criteria

- [x] Zero blocked worker threads during retry delays
- [x] Successful retry execution after context serialization
- [x] Full visibility into retry attempts and timing
- [x] Backward compatibility with existing sync reactors
- [x] Linear scaling with worker pool size
- [x] Comprehensive test coverage (>90%)
- [x] Performance improvement over blocking approach

---

## Implementation Timeline

**Week 1-2:** Phase 1 (Core Infrastructure) ✅
**Week 3:** Phase 2 (Serialization) ✅
**Week 4:** Phase 3 (Executor & Worker) ✅
**Week 5:** Phase 4 (Testing) ✅
**Week 6:** Phase 5-6 (Documentation & Validation)

**Regular Testing Checkpoints:**
- [x] After each phase completion
- [x] Before merging to main branch
- [ ] Performance validation after implementation
- [ ] Integration testing with real Sidekiq setup
