# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_10_10_160130) do
  create_table "orders", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "status"
    t.decimal "total"
    t.datetime "updated_at", null: false
    t.string "user_name"
  end

  create_table "products", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "name"
    t.decimal "price"
    t.integer "stock"
    t.datetime "updated_at", null: false
  end

  create_table "ruby_reactor_coordination", primary_key: "key_digest", id: { type: :string, limit: 64 }, force: :cascade do |t|
    t.bigint "expires_at_ms"
    t.text "key", null: false
    t.text "value", limit: 16777215
    t.index ["expires_at_ms"], name: "index_ruby_reactor_coordination_on_expires_at_ms"
  end

  create_table "ruby_reactor_correlation_ids", primary_key: ["storage_name", "correlation_digest"], force: :cascade do |t|
    t.string "context_id", limit: 36, null: false
    t.string "correlation_digest", limit: 64, null: false
    t.text "correlation_id", null: false
    t.string "storage_name", null: false
  end

  create_table "ruby_reactor_execution_inputs", primary_key: ["execution_id", "name"], force: :cascade do |t|
    t.string "execution_id", limit: 36, null: false
    t.string "name", null: false
    t.string "value", limit: 255, null: false
    t.index ["name", "value", "execution_id"], name: "index_rr_execution_inputs_lookup"
  end

  create_table "ruby_reactor_executions", id: { type: :string, limit: 36 }, force: :cascade do |t|
    t.text "context", limit: 1073741823, null: false
    t.string "correlation_id"
    t.datetime "created_at", null: false
    t.boolean "dispatched_child", default: false, null: false
    t.datetime "finished_at"
    t.string "parent_context_id", limit: 36
    t.string "reactor_class", null: false
    t.string "root_context_id", limit: 36
    t.datetime "started_at"
    t.string "status", limit: 20, null: false
    t.string "storage_name", null: false
    t.datetime "updated_at", null: false
    t.index ["parent_context_id"], name: "index_ruby_reactor_executions_on_parent_context_id"
    t.index ["reactor_class", "started_at"], name: "index_ruby_reactor_executions_on_reactor_class_and_started_at"
    t.index ["started_at", "id"], name: "index_ruby_reactor_executions_on_started_at_and_id"
    t.index ["status", "started_at"], name: "index_ruby_reactor_executions_on_status_and_started_at"
    t.index ["status", "updated_at"], name: "index_ruby_reactor_executions_on_status_and_updated_at"
    t.index ["updated_at"], name: "index_ruby_reactor_executions_on_updated_at"
  end

  create_table "ruby_reactor_idempotency_keys", primary_key: ["storage_name", "key_digest"], force: :cascade do |t|
    t.string "context_id", limit: 36, null: false
    t.datetime "created_at", null: false
    t.text "key", null: false
    t.string "key_digest", limit: 64, null: false
    t.string "storage_name", null: false
  end

  create_table "ruby_reactor_interrupt_resumes", primary_key: ["storage_name", "context_id", "step_name"], force: :cascade do |t|
    t.integer "attempts", default: 0, null: false
    t.string "context_id", limit: 36, null: false
    t.text "payload", limit: 1073741823
    t.string "step_name", null: false
    t.string "storage_name", null: false
  end

  create_table "ruby_reactor_map_elements", primary_key: ["map_operation_id", "position"], force: :cascade do |t|
    t.string "context_id", limit: 36, null: false
    t.bigint "map_operation_id", null: false
    t.bigint "position", null: false
  end

  create_table "ruby_reactor_map_operations", force: :cascade do |t|
    t.bigint "counter"
    t.datetime "created_at", null: false
    t.bigint "dispatch_offset"
    t.bigint "element_count", default: 0, null: false
    t.string "failed_context_id", limit: 36
    t.bigint "last_queued_index"
    t.string "map_id", null: false
    t.text "metadata", limit: 1073741823
    t.datetime "owner_signalled_at"
    t.string "storage_name", null: false
    t.datetime "updated_at", null: false
    t.index ["storage_name", "map_id"], name: "index_rr_map_operations_key", unique: true
    t.index ["updated_at"], name: "index_ruby_reactor_map_operations_on_updated_at"
  end

  create_table "ruby_reactor_map_results", primary_key: ["map_operation_id", "element_index"], force: :cascade do |t|
    t.bigint "element_index", null: false
    t.bigint "map_operation_id", null: false
    t.text "result", limit: 1073741823, null: false
  end

  create_table "ruby_reactor_map_rollback_outcomes", primary_key: ["map_rollback_id", "position"], force: :cascade do |t|
    t.bigint "element_index"
    t.string "kind", limit: 30, null: false
    t.bigint "map_rollback_id", null: false
    t.text "outcome", null: false
    t.bigint "position", null: false
    t.index ["map_rollback_id", "element_index"], name: "index_rr_map_rollback_outcomes_index"
  end

  create_table "ruby_reactor_map_rollbacks", force: :cascade do |t|
    t.bigint "claimed_offset", default: 0, null: false
    t.datetime "created_at", null: false
    t.boolean "handed_off", default: false, null: false
    t.string "map_id", null: false
    t.text "metadata", limit: 1073741823
    t.datetime "signalled_at"
    t.string "storage_name", null: false
    t.datetime "updated_at", null: false
    t.index ["storage_name", "map_id"], name: "index_rr_map_rollbacks_key", unique: true
    t.index ["updated_at"], name: "index_ruby_reactor_map_rollbacks_on_updated_at"
  end

  create_table "ruby_reactor_period_markers", primary_key: "key_digest", id: { type: :string, limit: 64 }, force: :cascade do |t|
    t.datetime "claimed_at", null: false
    t.string "context_id", limit: 36
    t.text "key", null: false
  end

  create_table "ruby_reactor_schema", force: :cascade do |t|
    t.integer "version", default: 1, null: false
  end

  create_table "ruby_reactor_step_results", force: :cascade do |t|
    t.string "context_id", limit: 36, null: false
    t.datetime "created_at", null: false
    t.text "record", limit: 1073741823, null: false
    t.string "status", limit: 20, null: false
    t.string "step_name", null: false
    t.string "storage_name", null: false
    t.datetime "updated_at", null: false
    t.index ["storage_name", "context_id", "step_name"], name: "index_rr_step_results_key", unique: true
    t.index ["updated_at"], name: "index_ruby_reactor_step_results_on_updated_at"
  end
end
