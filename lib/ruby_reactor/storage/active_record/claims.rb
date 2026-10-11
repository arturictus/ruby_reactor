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

        # Compare-and-delete: only the run holding the claim can release it.
        def release_idempotency_key(key, context_id, reactor_class_name)
          with_db { idempotency_scope(key, reactor_class_name).where(context_id: context_id).delete_all == 1 }
        end

        # Compare-and-set: take over a claim from a run seen dead (review F1).
        def reclaim_idempotency_key(key, from_context_id, to_context_id, reactor_class_name)
          with_db do
            claim = idempotency_scope(key, reactor_class_name).where(context_id: from_context_id)
            claim.update_all(context_id: to_context_id, created_at: Time.current) == 1
          end
        end

        private

        def idempotency_scope(key, reactor_class_name)
          IdempotencyKey.where(storage_name: reactor_class_name.to_s, key_digest: Coordination.digest(key))
        end

        def ensure_resume(context_id, reactor_class_name, step_name)
          key = { storage_name: reactor_class_name.to_s, context_id: context_id, step_name: step_name.to_s }
          InterruptResume.insert_all([key])
          InterruptResume.where(key)
        end
      end
    end
  end
end
