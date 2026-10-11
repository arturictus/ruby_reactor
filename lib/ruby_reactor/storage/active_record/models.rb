# frozen_string_literal: true

module RubyReactor
  module Storage
    class ActiveRecordAdapter
      # One model per table (specs/011 data-model.md). Kept to the table name and
      # key: the adapter modules hold all behavior.
      class Schema < Record
        self.table_name = "ruby_reactor_schema"
      end

      class Execution < Record
        self.table_name = "ruby_reactor_executions"
      end

      class ExecutionInput < Record
        self.table_name = "ruby_reactor_execution_inputs"
        self.primary_key = %i[execution_id name]
      end

      class StepResult < Record
        self.table_name = "ruby_reactor_step_results"
      end

      class MapOperation < Record
        self.table_name = "ruby_reactor_map_operations"
      end

      class MapElement < Record
        self.table_name = "ruby_reactor_map_elements"
        self.primary_key = %i[map_operation_id position]
      end

      class MapResult < Record
        self.table_name = "ruby_reactor_map_results"
        self.primary_key = %i[map_operation_id element_index]
      end

      class MapRollback < Record
        self.table_name = "ruby_reactor_map_rollbacks"
      end

      class MapRollbackOutcome < Record
        self.table_name = "ruby_reactor_map_rollback_outcomes"
        self.primary_key = %i[map_rollback_id position]
      end

      class CorrelationId < Record
        self.table_name = "ruby_reactor_correlation_ids"
        self.primary_key = %i[storage_name correlation_digest]
      end

      class InterruptResume < Record
        self.table_name = "ruby_reactor_interrupt_resumes"
        self.primary_key = %i[storage_name context_id step_name]
      end

      class PeriodMarker < Record
        self.table_name = "ruby_reactor_period_markers"
        self.primary_key = :key_digest
      end

      class IdempotencyKey < Record
        self.table_name = "ruby_reactor_idempotency_keys"
        self.primary_key = %i[storage_name key_digest]
      end

      class CoordinationEntry < Record
        self.table_name = "ruby_reactor_coordination"
        self.primary_key = :key_digest
      end

      MODELS = [Schema, Execution, ExecutionInput, StepResult, MapOperation, MapElement, MapResult, MapRollback,
                MapRollbackOutcome, CorrelationId, InterruptResume, PeriodMarker, IdempotencyKey,
                CoordinationEntry].freeze
    end
  end
end
