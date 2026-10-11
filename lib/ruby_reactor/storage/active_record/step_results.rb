# frozen_string_literal: true

module RubyReactor
  module Storage
    class ActiveRecordAdapter
      # Durable `async_step` outcomes, keyed by (context, step) (011 DM §4).
      module StepResults
        def store_step_result(context_id, step_name, record, reactor_class_name)
          now = Time.current
          status = (record["status"] || record[:status]).to_s
          with_db do
            key = { storage_name: reactor_class_name.to_s, context_id: context_id, step_name: step_name.to_s }
            write_row(StepResult, key, { status: status, record: JSON.generate(record), updated_at: now },
                      insert_only: { created_at: now })
          end
        end

        def retrieve_step_result(context_id, step_name, reactor_class_name)
          json = with_db do
            StepResult.where(storage_name: reactor_class_name.to_s, context_id: context_id, step_name: step_name.to_s)
                      .pick(:record)
          end
          json && JSON.parse(json)
        end

        # StepSweeper's input, within the R-08 window. `status:` (its
        # "dispatched") is applied before the cap, so completed records can't
        # crowd a lost unit out (review F4).
        def scan_step_results(count: 1000, status: nil)
          scope = recent(StepResult)
          scope = scope.where(status: status) if status
          rows = with_db { scope.order(:updated_at).limit(count).pluck(:record) }
          rows.map { |json| JSON.parse(json) }
        end
      end
    end
  end
end
