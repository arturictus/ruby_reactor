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
- [ ] Update `ruby_reactor.gemspec` to add Sidekiq and Redis dependencies
- [ ] Create initial Sidekiq worker class structure
- [ ] Set up basic Sidekiq configuration for the gem

### DSL Extensions for Async Support
- [ ] Extend Reactor DSL with `async` class method
- [ ] Extend Step DSL with `async:` option in step builder
- [ ] Add `async?` methods to Reactor and StepConfig classes
- [ ] **Test:** Unit tests for DSL extensions

### Retry Configuration DSL
- [ ] Implement `retry` method in StepBuilder with max_attempts, backoff, base_delay options
- [ ] Add `idempotent` method to StepBuilder
- [ ] Implement reactor-level `retry_defaults` class method
- [ ] Create StepConfig retry_config attribute handling
- [ ] **Test:** Unit tests for retry configuration parsing

### Core Classes Setup
- [ ] Create `RetryContext` class with step_attempts tracking
- [ ] Add retry_context to Context class initialization
- [ ] Implement basic serialization structure in Context
- [ ] Create `RubyReactor::RetryQueuedResult` class
- [ ] **Test:** Unit tests for new classes and basic serialization

---

## Phase 2: Context Serialization & Deserialization

### Enhanced Context Serialization
- [ ] Implement `serialize_for_retry` method in Context
- [ ] Add `deserialize_from_retry` class method in Context
- [ ] Handle complex object serialization (Time, BigDecimal, custom objects)
- [ ] Implement ContextSerializer utility class
- [ ] Add execution metadata preservation (job_id, started_at, reactor_class)

### Retry Context Serialization
- [ ] Serialize step_attempts hash
- [ ] Preserve current_step, failure_reason, next_retry_at
- [ ] Handle error object serialization safely
- [ ] Implement deserialization with proper type restoration
- [ ] **Test:** Integration tests for full context round-trip serialization

### Error Handling & Validation
- [ ] Add context size validation (Redis limits)
- [ ] Implement compression for large contexts if needed
- [ ] Add schema versioning for forward compatibility
- [ ] Handle deserialization errors gracefully
- [ ] **Test:** Edge case tests for serialization limits and error conditions

---

## Phase 3: Non-Blocking Executor Implementation

### Retry Logic Foundation
- [ ] Implement `calculate_backoff_delay` method with exponential/linear/fixed strategies
- [ ] Add `can_retry_step?` method to RetryContext
- [ ] Create `increment_attempt_for_step` method
- [ ] Update `execute_step_with_retry` to use new retry context

### Job Requeuing Mechanism
- [ ] Implement `requeue_job_for_step_retry` method
- [ ] Add proper logging for retry attempts and delays
- [ ] Integrate with Sidekiq's `perform_in` for delayed execution
- [ ] Update retry context before requeuing
- [ ] **Test:** Unit tests for backoff calculations and requeuing logic

### Execution Resume Logic
- [ ] Implement `resume_execution` method in Executor
- [ ] Add `resume_from_failed_step` method
- [ ] Create `execute_remaining_steps` after successful retry
- [ ] Handle final failure scenarios
- [ ] **Test:** Integration tests for execution resumption scenarios

---

## Phase 4: Enhanced Sidekiq Worker

### Worker Configuration
- [ ] Update RubyReactorWorker with proper sidekiq_options
- [ ] Configure retry settings for infrastructure failures only
- [ ] Implement `sidekiq_retries_exhausted` handler
- [ ] Add proper error logging and monitoring

### Worker Execution Logic
- [ ] Update `perform` method to handle serialized contexts
- [ ] Integrate context deserialization
- [ ] Call executor.resume_execution with proper context
- [ ] Handle unexpected errors appropriately
- [ ] **Test:** Worker integration tests with mocked Sidekiq

### Async Handoff Implementation
- [ ] Implement full reactor async (all execution in worker)
- [ ] Implement step-level async (handoff at first async step)
- [ ] Ensure sequential execution in single worker
- [ ] Return AsyncResult from reactor.run when appropriate
- [ ] **Test:** End-to-end async execution tests

---

## Phase 5: Testing & Validation

### Unit Test Suite
- [ ] Test retry configuration parsing and validation
- [ ] Test context serialization/deserialization
- [ ] Test backoff delay calculations
- [ ] Test retry context state management
- [ ] Test executor retry logic

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

- [ ] Zero blocked worker threads during retry delays
- [ ] Successful retry execution after context serialization
- [ ] Full visibility into retry attempts and timing
- [ ] Backward compatibility with existing sync reactors
- [ ] Linear scaling with worker pool size
- [ ] Comprehensive test coverage (>90%)
- [ ] Performance improvement over blocking approach

---

## Implementation Timeline

**Week 1-2:** Phase 1 (Core Infrastructure)
**Week 3:** Phase 2 (Serialization)
**Week 4:** Phase 3 (Executor & Worker)
**Week 5:** Phase 4 (Testing)
**Week 6:** Phase 5-6 (Documentation & Validation)

**Regular Testing Checkpoints:**
- After each phase completion
- Before merging to main branch
- Performance validation after implementation
- Integration testing with real Sidekiq setup
