# frozen_string_literal: true

module RubyReactor
  module Storage
    class ActiveRecordAdapter
      # One fan-out map's distributed rollback (009 DM §5, 011 DM §8). A
      # rollback row with NULL metadata stands for "not started".
      module MapRollbacks
        # Creates the metadata only if no rollback of this map started (I-3).
        # `[created, metadata]`: a second start finds the first one's records.
        def start_map_rollback(map_id, reactor_class_name, **meta)
          fields = meta.merge(map_id: map_id, parent_reactor_class_name: reactor_class_name, started_at: Time.now.to_i)
          created = with_db do
            ensure_rollback(map_id, reactor_class_name)
            rollback_scope(map_id, reactor_class_name).where(metadata: nil)
                                                      .update_all(metadata: JSON.generate(fields)) == 1
          end
          [created, retrieve_map_rollback_metadata(map_id, reactor_class_name)]
        end

        def retrieve_map_rollback_metadata(map_id, reactor_class_name)
          json = with_db { rollback_scope(map_id, reactor_class_name).pick(:metadata) }
          json && JSON.parse(json)
        end

        # Claims the next `count` positions (R-02), clipped to the total.
        def claim_map_rollback_positions(map_id, reactor_class_name, count)
          with_db do
            Record.transaction do
              rollback = locked_rollback(map_id, reactor_class_name)
              stop = rollback.claimed_offset + count
              ActiveRecordAdapter::MapRollback.where(id: rollback.id).update_all(claimed_offset: stop)
              total = (rollback.metadata && JSON.parse(rollback.metadata)["total"]).to_i
              (stop - count)...[stop, total].min
            end
          end
        end

        def retrieve_map_rollback_offset(map_id, reactor_class_name)
          with_db { rollback_scope(map_id, reactor_class_name).pick(:claimed_offset) }.to_i
        end

        # The first outcome for a position wins: a duplicate delivery must not
        # replace a `failed` outcome with its own `undone`.
        def store_map_rollback_outcome(map_id, reactor_class_name, position, outcome)
          index = outcome["index"] || outcome[:index]
          kind = (outcome["outcome"] || outcome[:outcome]).to_s
          with_db do
            MapRollbackOutcome.insert!({ map_rollback_id: ensure_rollback(map_id, reactor_class_name),
                                         position: position.to_i, element_index: index&.to_i, kind: kind,
                                         outcome: JSON.generate(outcome) })
            true
          rescue ::ActiveRecord::RecordNotUnique
            false
          end
        end

        def count_map_rollback_outcomes(map_id, reactor_class_name)
          with_db { outcomes_scope(map_id, reactor_class_name).count }
        end

        def stored_map_rollback_positions(map_id, reactor_class_name)
          with_db { outcomes_scope(map_id, reactor_class_name).pluck(:position) }
        end

        def map_rollback_outcome_stored?(map_id, reactor_class_name, position)
          with_db { outcomes_scope(map_id, reactor_class_name).exists?(position: position.to_i) }
        end

        # Yields `position, outcome` in bounded reads.
        def each_map_rollback_outcome(map_id, reactor_class_name)
          after = -1
          loop do
            batch = with_db do
              outcomes_scope(map_id, reactor_class_name).where("position > ?", after)
                                                        .order(:position).limit(500).pluck(:position, :outcome)
            end
            break if batch.empty?

            batch.each { |position, json| yield position, JSON.parse(json) }
            after = batch.last.first
          end
        end

        # One boolean per index: whether a rollback job saw that element (R-09).
        def map_rollback_indexes_seen(map_id, reactor_class_name, indexes)
          seen = with_db do
            outcomes_scope(map_id, reactor_class_name).where(element_index: indexes.map(&:to_i))
                                                      .distinct.pluck(:element_index)
          end
          indexes.map { |index| seen.include?(index.to_i) }
        end

        def mark_map_rollback_handed_off(map_id, reactor_class_name)
          with_db do
            ensure_rollback(map_id, reactor_class_name)
            rollback_scope(map_id, reactor_class_name).update_all(handed_off: true)
          end
        end

        def map_rollback_handed_off?(map_id, reactor_class_name)
          with_db { rollback_scope(map_id, reactor_class_name).pick(:handed_off) } == true
        end

        def claim_map_rollback_signal(map_id, reactor_class_name)
          with_db do
            ensure_rollback(map_id, reactor_class_name)
            rollback_scope(map_id,
                           reactor_class_name).where(signalled_at: nil).update_all(signalled_at: Time.current) == 1
          end
        end

        # Progress for the dashboard (R-15), or nil when this map never rolled back.
        def map_rollback_summary(map_id, reactor_class_name)
          meta = retrieve_map_rollback_metadata(map_id, reactor_class_name)
          return nil unless meta

          settled, failed = with_db do
            scope = outcomes_scope(map_id, reactor_class_name)
            [scope.count, scope.where(kind: RedisMapRollback::FAILED_OUTCOMES).count]
          end
          total = meta["total"].to_i
          { total: total, settled: settled, outstanding: total - settled, failed: failed }
        end

        # Every started map rollback, for Map::Sweeper (S-5), within the R-08 window.
        def scan_map_rollbacks(count: 1000)
          rows = with_db do
            recent(ActiveRecordAdapter::MapRollback).where.not(metadata: nil).order(:updated_at).limit(count)
                                                    .pluck(:metadata)
          end
          rows.map { |json| JSON.parse(json) }
        end

        private

        def rollback_scope(map_id, reactor_class_name)
          ActiveRecordAdapter::MapRollback.where(storage_name: reactor_class_name.to_s, map_id: map_id)
        end

        def outcomes_scope(map_id, reactor_class_name)
          MapRollbackOutcome.where(map_rollback_id: rollback_scope(map_id, reactor_class_name).select(:id))
        end

        def ensure_rollback(map_id, reactor_class_name)
          now = Time.current
          ActiveRecordAdapter::MapRollback.insert_all([{ storage_name: reactor_class_name.to_s, map_id: map_id,
                                                         created_at: now, updated_at: now }])
          rollback_scope(map_id, reactor_class_name).pick(:id)
        end

        def locked_rollback(map_id, reactor_class_name)
          ensure_rollback(map_id, reactor_class_name)
          rollback_scope(map_id, reactor_class_name).lock.first
        end
      end
    end
  end
end
