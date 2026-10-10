# frozen_string_literal: true

module RubyReactor
  module Storage
    class ActiveRecordAdapter
      # First-wins claims: interrupt resumes (010 DM §2–3) and run-level
      # idempotency keys (011 DM §10, §12; R-13).
      module Claims
        # The first resume of an interrupt wins; the claim is never deleted.
        def claim_interrupt_resume(context_id, reactor_class_name, step_name, serialized_payload)
          with_db do
            scope = ensure_resume(context_id, reactor_class_name, step_name)
            scope.where(payload: nil).update_all(payload: serialized_payload) == 1
          end
        end

        # `{ "step" => serialized_payload }` for the claimed ones among `step_names`.
        def retrieve_interrupt_resumes(context_id, reactor_class_name, step_names)
          names = Array(step_names).map(&:to_s)
          return {} if names.empty?

          with_db do
            InterruptResume.where(storage_name: reactor_class_name.to_s, context_id: context_id, step_name: names)
                           .where.not(payload: nil).pluck(:step_name, :payload).to_h
          end
        end

        # Invalid resume payloads counted per interrupt; returns the new count.
        def increment_interrupt_attempts(context_id, reactor_class_name, step_name)
          with_db do
            Record.transaction do
              scope = ensure_resume(context_id, reactor_class_name, step_name)
              attempts = scope.lock.pick(:attempts) + 1
              scope.update_all(attempts: attempts)
              attempts
            end
          end
        end

        # nil when this call claimed `key`; otherwise the run that holds it.
        def claim_idempotency_key(key, context_id, reactor_class_name)
          digest = Coordination.digest(key)
          with_db do
            IdempotencyKey.insert!({ storage_name: reactor_class_name.to_s, key_digest: digest, key: key.to_s,
                                     context_id: context_id, created_at: Time.current })
            nil
          rescue ::ActiveRecord::RecordNotUnique
            IdempotencyKey.where(storage_name: reactor_class_name.to_s, key_digest: digest).pick(:context_id)
          end
        end

        private

        def ensure_resume(context_id, reactor_class_name, step_name)
          key = { storage_name: reactor_class_name.to_s, context_id: context_id, step_name: step_name.to_s }
          InterruptResume.insert_all([key])
          InterruptResume.where(key)
        end
      end
    end
  end
end
