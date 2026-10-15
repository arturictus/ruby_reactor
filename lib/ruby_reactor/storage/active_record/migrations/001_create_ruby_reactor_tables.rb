# frozen_string_literal: true

# RubyReactor ActiveRecord storage, schema version 1 (specs/011 data-model.md).
# Released migrations are append-only: never edit this file, add 00N_… instead.
class CreateRubyReactorTables < ActiveRecord::Migration[8.0]
  # MySQL picks LONGTEXT/MEDIUMTEXT from these limits (R-10); PostgreSQL and
  # SQLite text columns are unbounded and ignore them.
  LONG_TEXT = 1_073_741_823 # PostgreSQL caps text limits at 1 GB - 1
  MEDIUM_TEXT = 16_777_215

  def up
    # The installed schema version is this column's DEFAULT, not a row: defaults
    # survive db/schema.rb loads and truncation (R-16). Later migrations bump it
    # with change_column_default.
    create_table :ruby_reactor_schema do |t|
      t.integer :version, null: false, default: 1
    end

    create_table :ruby_reactor_executions, id: { type: :string, limit: 36 } do |t|
      t.string :storage_name, null: false
      t.string :reactor_class, null: false
      t.string :status, limit: 20, null: false
      t.string :parent_context_id, limit: 36
      t.string :root_context_id, limit: 36
      t.string :correlation_id
      t.boolean :dispatched_child, null: false, default: false
      t.text :context, limit: LONG_TEXT, null: false
      t.datetime :started_at, precision: 6
      t.datetime :finished_at, precision: 6
      t.timestamps precision: 6
    end
    add_index :ruby_reactor_executions, :parent_context_id
    add_index :ruby_reactor_executions, :updated_at
    add_index :ruby_reactor_executions, %i[status updated_at]
    add_index :ruby_reactor_executions, %i[started_at id]
    add_index :ruby_reactor_executions, %i[reactor_class started_at]
    add_index :ruby_reactor_executions, %i[status started_at]

    create_table :ruby_reactor_execution_inputs, primary_key: %i[execution_id name] do |t|
      t.string :execution_id, limit: 36, null: false
      t.string :name, null: false
      t.string :value, limit: 255, null: false
    end
    add_index :ruby_reactor_execution_inputs, %i[name value execution_id], name: "index_rr_execution_inputs_lookup"

    create_table :ruby_reactor_step_results do |t|
      t.string :storage_name, null: false
      t.string :context_id, limit: 36, null: false
      t.string :step_name, null: false
      t.string :status, limit: 20, null: false
      t.text :record, limit: LONG_TEXT, null: false
      t.timestamps precision: 6
    end
    add_index :ruby_reactor_step_results, %i[storage_name context_id step_name], unique: true,
                                                                              name: "index_rr_step_results_key"
    add_index :ruby_reactor_step_results, :updated_at

    create_table :ruby_reactor_map_operations do |t|
      t.string :storage_name, null: false
      t.string :map_id, null: false
      t.text :metadata, limit: LONG_TEXT
      t.bigint :counter
      t.bigint :dispatch_offset
      t.bigint :last_queued_index
      t.string :failed_context_id, limit: 36
      t.datetime :owner_signalled_at, precision: 6
      t.bigint :element_count, null: false, default: 0
      t.timestamps precision: 6
    end
    add_index :ruby_reactor_map_operations, %i[storage_name map_id], unique: true, name: "index_rr_map_operations_key"
    add_index :ruby_reactor_map_operations, :updated_at

    create_table :ruby_reactor_map_elements, primary_key: %i[map_operation_id position] do |t|
      t.bigint :map_operation_id, null: false
      t.bigint :position, null: false
      t.string :context_id, limit: 36, null: false
    end

    create_table :ruby_reactor_map_results, primary_key: %i[map_operation_id element_index] do |t|
      t.bigint :map_operation_id, null: false
      t.bigint :element_index, null: false
      t.text :result, limit: LONG_TEXT, null: false
    end

    create_table :ruby_reactor_map_rollbacks do |t|
      t.string :storage_name, null: false
      t.string :map_id, null: false
      t.text :metadata, limit: LONG_TEXT
      t.bigint :claimed_offset, null: false, default: 0
      t.boolean :handed_off, null: false, default: false
      t.datetime :signalled_at, precision: 6
      t.timestamps precision: 6
    end
    add_index :ruby_reactor_map_rollbacks, %i[storage_name map_id], unique: true, name: "index_rr_map_rollbacks_key"
    add_index :ruby_reactor_map_rollbacks, :updated_at

    create_table :ruby_reactor_map_rollback_outcomes, primary_key: %i[map_rollback_id position] do |t|
      t.bigint :map_rollback_id, null: false
      t.bigint :position, null: false
      t.bigint :element_index
      t.string :kind, limit: 30, null: false
      t.text :outcome, null: false
    end
    add_index :ruby_reactor_map_rollback_outcomes, %i[map_rollback_id element_index],
              name: "index_rr_map_rollback_outcomes_index"

    create_table :ruby_reactor_correlation_ids, primary_key: %i[storage_name correlation_digest] do |t|
      t.string :storage_name, null: false
      t.string :correlation_digest, limit: 64, null: false
      t.text :correlation_id, null: false
      t.string :context_id, limit: 36, null: false
    end

    create_table :ruby_reactor_interrupt_resumes, primary_key: %i[storage_name context_id step_name] do |t|
      t.string :storage_name, null: false
      t.string :context_id, limit: 36, null: false
      t.string :step_name, null: false
      t.text :payload, limit: LONG_TEXT
      t.integer :attempts, null: false, default: 0
    end

    create_table :ruby_reactor_period_markers, id: false do |t|
      t.string :key_digest, limit: 64, null: false, primary_key: true
      t.text :key, null: false
      t.string :context_id, limit: 36
      t.datetime :claimed_at, precision: 6, null: false
    end

    create_table :ruby_reactor_idempotency_keys, primary_key: %i[storage_name key_digest] do |t|
      t.string :storage_name, null: false
      t.string :key_digest, limit: 64, null: false
      t.text :key, null: false
      t.string :context_id, limit: 36, null: false
      t.datetime :created_at, precision: 6, null: false
    end

    create_table :ruby_reactor_coordination, id: false do |t|
      t.string :key_digest, limit: 64, null: false, primary_key: true
      t.text :key, null: false
      t.text :value, limit: MEDIUM_TEXT
      t.bigint :expires_at_ms
    end
    add_index :ruby_reactor_coordination, :expires_at_ms
  end

  def down
    %i[ruby_reactor_coordination ruby_reactor_idempotency_keys ruby_reactor_period_markers
       ruby_reactor_interrupt_resumes ruby_reactor_correlation_ids ruby_reactor_map_rollback_outcomes
       ruby_reactor_map_rollbacks ruby_reactor_map_results ruby_reactor_map_elements ruby_reactor_map_operations
       ruby_reactor_step_results ruby_reactor_execution_inputs ruby_reactor_executions
       ruby_reactor_schema].each { |table| drop_table table }
  end
end
