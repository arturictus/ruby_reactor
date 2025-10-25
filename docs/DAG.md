# DAG Execution and Saga Patterns in RubyReactor

RubyReactor uses Directed Acyclic Graphs (DAGs) to manage step dependencies and implements saga patterns for reliable distributed transactions. This document explains how DAG execution works and how saga patterns ensure consistency across complex workflows.

## Directed Acyclic Graphs (DAGs)

A DAG is a graph with directed edges and no cycles, ensuring that step dependencies can be resolved in a deterministic order.

### DAG Structure

```mermaid
graph TD
    A[Step A] --> C[Step C]
    B[Step B] --> C
    C --> D[Step D]
    C --> E[Step E]
    D --> F[Step F]
    E --> F

    style A fill:#e1f5fe
    style B fill:#e1f5fe
    style C fill:#fff3e0
    style D fill:#e8f5e8
    style E fill:#e8f5e8
    style F fill:#ffebee
```

**Legend:**
- 🔵 Independent steps (can run in parallel)
- 🟡 Dependent steps (wait for prerequisites)
- 🟢 Ready to execute
- 🔴 Final step

### DAG Execution Algorithm

```mermaid
graph TD
    A[Start Execution] --> B[Build Dependency Graph]
    B --> C[Identify Ready Steps<br/>no unmet dependencies]
    C --> D{Ready Steps<br/>Available?}
    D -->|No| E[Execution Complete]
    D -->|Yes| F[Execute Ready Steps<br/>in Parallel]
    F --> G[Update Dependencies<br/>Mark steps complete]
    G --> H[Collect Results]
    H --> I{Execution<br/>Successful?}
    I -->|Yes| C
    I -->|No| J[Initiate Saga Compensation]
    J --> K[Execution Failed]
```

### Dependency Resolution

```mermaid
graph TD
    A[Step Dependencies] --> B[Topological Sort]
    B --> C[Execution Order<br/>A → B → C → D]
    C --> D[Parallel Execution<br/>Where Possible]

    subgraph "Level 1"
        A1[Independent Steps]
    end

    subgraph "Level 2"
        B1[Steps depending on Level 1]
    end

    subgraph "Level 3"
        C1[Steps depending on Level 2]
    end
```

## Saga Patterns

RubyReactor implements saga patterns to ensure consistency across distributed operations. Sagas provide transactional semantics for long-running business processes.

### Saga Execution Flow

```mermaid
graph TD
    A[Saga Initiated] --> B[Execute Step 1]
    B --> C{Step 1<br/>Success?}
    C -->|Yes| D[Execute Step 2]
    C -->|No| E[Compensation Started]
    D --> F{Step 2<br/>Success?}
    F -->|Yes| G[Execute Step 3]
    F -->|No| H[Compensate Step 1]
    G --> I{Step 3<br/>Success?}
    I -->|Yes| J[Saga Complete]
    I -->|No| K[Compensate Step 2<br/>Then Step 1]
    H --> L[Saga Failed]
    K --> L
    E --> L

    style A fill:#e3f2fd
    style J fill:#e8f5e8
    style L fill:#ffebee
```

### Compensation Strategies

#### Backward Recovery (Rollback)

```mermaid
graph TD
    A[Forward Execution] --> B[Step A Success]
    B --> C[Step B Success]
    C --> D[Step C Fails]
    D --> E[Start Compensation]
    E --> F[Compensate C]
    F --> G[Compensate B]
    G --> H[Compensate A]
    H --> I[Consistent State Restored]

    style A fill:#e3f2fd
    style I fill:#e8f5e8
    style D fill:#ffebee
```

#### Forward Recovery (Retry)

```mermaid
graph TD
    A[Step Fails] --> B{Can Retry?}
    B -->|Yes| C[Calculate Backoff]
    C --> D[Schedule Retry]
    D --> E[Retry Execution]
    E --> F{Retry<br/>Success?}
    F -->|Yes| G[Continue Saga]
    F -->|No| B
    B -->|No| H[Compensation Required]

    style G fill:#e8f5e8
    style H fill:#ffebee
```

## Complex Saga Scenarios

### Order Processing Saga

```mermaid
graph TD
    A[Order Submitted] --> B[Validate Order]
    B --> C{Valid?}
    C -->|No| D[Saga Failed]
    C -->|Yes| E[Reserve Inventory]
    E --> F{Reserved?}
    F -->|No| G[Saga Failed]
    F -->|Yes| H[Process Payment]
    H --> I{Payment OK?}
    I -->|No| J[Release Inventory<br/>Compensation]
    I -->|Yes| K[Update Order Status]
    K --> L[Send Confirmation]
    L --> M[Saga Complete]

    J --> D
    G --> D

    style A fill:#e3f2fd
    style M fill:#e8f5e8
    style D fill:#ffebee
```

### Payment Processing with Multiple Attempts

```mermaid
graph TD
    A[Payment Required] --> B[Attempt Primary Card]
    B --> C{Success?}
    C -->|Yes| D[Payment Complete]
    C -->|No| E[Attempt Backup Card]
    E --> F{Success?}
    F -->|Yes| D
    F -->|No| G[Notify Customer]
    G --> H[Manual Review Required]

    style A fill:#e3f2fd
    style D fill:#e8f5e8
    style H fill:#fff3e0
```

## DAG + Saga Integration

RubyReactor combines DAG execution with saga patterns for complex workflows:

```mermaid
graph TD
    subgraph "DAG Execution"
        A1[Build Graph] --> B1[Resolve Dependencies]
        B1 --> C1[Execute in Order]
    end

    subgraph "Saga Pattern"
        D1[Monitor Execution] --> E1{Step Fails?}
        E1 -->|No| F1[Continue]
        E1 -->|Yes| G1[Trigger Compensation]
    end

    subgraph "Retry Mechanism"
        H1[Failed Step] --> I1{Can Retry?}
        I1 -->|Yes| J1[Requeue Job]
        I1 -->|No| K1[Final Compensation]
    end

    C1 --> D1
    G1 --> H1
    J1 --> A1

    style F1 fill:#e8f5e8
    style K1 fill:#ffebee
```

## Execution States

### Step States

```mermaid
stateDiagram-v2
    [*] --> Pending
    Pending --> Running
    Running --> Completed
    Running --> Failed
    Failed --> Compensating
    Compensating --> Compensated
    Compensated --> [*]
    Failed --> Retrying
    Retrying --> Pending
```

### Saga States

```mermaid
stateDiagram-v2
    [*] --> Initiated
    Initiated --> Executing
    Executing --> Completed
    Executing --> Failing
    Failing --> Compensating
    Compensating --> Failed
    Failed --> [*]
    Completed --> [*]
```

## Error Handling Patterns

### Cascading Compensation

```mermaid
graph TD
    A[Root Cause Failure] --> B[Step N Fails]
    B --> C[Mark Step N for Compensation]
    C --> D[Stop Downstream Steps]
    D --> E[Execute Compensation Chain]
    E --> F[Step N-1 Compensation]
    F --> G[Step N-2 Compensation]
    G --> H[...continue to Step 1]
    H --> I[Consistent State Achieved]

    style A fill:#ffebee
    style I fill:#e8f5e8
```

### Partial Success Handling

```mermaid
graph TD
    A[Multi-Step Process] --> B[Step 1 Success]
    B --> C[Step 2 Success]
    C --> D[Step 3 Fails]
    D --> E{Essential<br/>Step?}
    E -->|Yes| F[Full Compensation Required]
    E -->|No| G[Partial Success Acceptable]
    G --> H[Continue with Successful Steps]
    H --> I[Manual Intervention for Failed Step]

    style G fill:#fff3e0
    style I fill:#fff3e0
```

## Performance Considerations

### Parallel Execution in DAGs

```mermaid
graph TD
    A[Level 1<br/>Parallel Steps] --> B[Level 2<br/>Parallel Steps]
    B --> C[Level 3<br/>Parallel Steps]

    subgraph "Level 1 (3 steps)"
        A1[Step A] & A2[Step B] & A3[Step C]
    end

    subgraph "Level 2 (2 steps)"
        B1[Step D] & B2[Step E]
    end

    subgraph "Level 3 (1 step)"
        C1[Step F]
    end

    A1 --> B1
    A2 --> B1
    A3 --> B2
    B1 --> C1
    B2 --> C1
```

### Saga Overhead

```mermaid
graph TD
    A[Normal Execution] --> B[Fast Path<br/>No Compensation]
    C[Saga Execution] --> D[State Tracking<br/>Compensation Logic]
    D --> E[Increased Complexity]

    A --> F[Better Performance]
    C --> G[Reliability Benefits]

    style F fill:#e8f5e8
    style G fill:#e8f5e8
```

## Monitoring and Observability

### Saga Metrics

```mermaid
graph TD
    A[Saga Metrics] --> B[Completion Rate]
    A --> C[Average Duration]
    A --> D[Compensation Frequency]
    A --> E[Retry Attempts]
    A --> F[Failure Patterns]

    B --> G[Business Health]
    C --> H[Performance Monitoring]
    D --> I[Reliability Insights]
    E --> J[Resilience Metrics]
    F --> K[Root Cause Analysis]
```

### DAG Execution Monitoring

```mermaid
graph TD
    A[DAG Monitoring] --> B[Step Dependencies]
    A --> C[Execution Order]
    A --> D[Parallel Execution]
    A --> E[Bottleneck Identification]

    B --> F[Dependency Health]
    C --> G[Execution Flow]
    D --> H[Concurrency Optimization]
    E --> I[Performance Tuning]
```

## Best Practices

### DAG Design

1. **Keep it Simple**: Minimize dependencies to maximize parallelism
2. **Clear Dependencies**: Make step relationships explicit
3. **Avoid Cycles**: Ensure DAG remains acyclic
4. **Test Execution Order**: Verify topological sort produces expected order

### Saga Implementation

1. **Idempotent Operations**: Design steps to be safely retryable
2. **Compensation Logic**: Always implement proper undo operations
3. **State Tracking**: Maintain sufficient state for compensation
4. **Timeout Handling**: Set appropriate timeouts for long-running sagas

### Error Handling

1. **Graceful Degradation**: Handle partial failures appropriately
2. **Circuit Breakers**: Prevent cascade failures
3. **Monitoring**: Track saga health and failure patterns
4. **Recovery Procedures**: Document manual recovery processes

## Implementation Examples

### Simple DAG with Saga

```ruby
class OrderProcessingReactor < RubyReactor::Reactor
  async true

  step :validate_order do
    run { validate_order_logic }
  end

  step :reserve_inventory do
    argument :order, result(:validate_order)
    run do |args, _context|
      reserve_inventory_logic(args[:order])
    end

    compensate do
      # Release reservation
      release_inventory_logic
    end
  end

  step :process_payment do
    argument :inventory_result, result(:reserve_inventory)
    run do |args, _context|
      process_payment_logic(args[:inventory_result])
    end

    compensate do
      # Refund payment
      refund_payment_logic
    end
  end

  step :confirm_order do
    argument :payment_result, result(:process_payment)
    run do |args, _context|
      confirm_order_logic(args[:payment_result])
    end
  end
end
```

### Complex DAG with Parallel Execution

```ruby
class ComplexWorkflowReactor < RubyReactor::Reactor
  async true

  # Level 1 - Independent steps
  step :validate_input do
    run { validate_input_logic }
  end

  step :check_permissions do
    run { check_permissions_logic }
  end

  # Level 2 - Depends on level 1
  step :process_data do
    argument :validation_result, result(:validate_input)
    argument :permissions_result, result(:check_permissions)
    run do |args, _context|
      process_data_logic(args[:validation_result], args[:permissions_result])
    end
  end

  # Level 3 - Parallel steps depending on level 2
  step :send_notification do
    argument :data_result, result(:process_data)
    run do |args, _context|
      send_notification_logic(args[:data_result])
    end
  end

  step :update_audit_log do
    argument :data_result, result(:process_data)
    run do |args, _context|
      update_audit_log_logic(args[:data_result])
    end
  end

  # Level 4 - Depends on level 3
  step :cleanup do
    argument :notification_result, result(:send_notification)
    argument :audit_result, result(:update_audit_log)
    run do |args, _context|
      cleanup_logic(args[:notification_result], args[:audit_result])
    end
  end
end
```

This DAG allows `send_notification` and `update_audit_log` to execute in parallel after `process_data` completes, demonstrating how RubyReactor maximizes concurrency while maintaining dependency ordering
