# frozen_string_literal: true

module RubyReactor
  module Storage
    class ActiveRecordAdapter
      # Map operations: metadata, counters, the element index and result slots
      # (011 DM §5–§7). Every Redis key of one map becomes a column of its
      # `ruby_reactor_map_operations` row; NULL stands for "key absent".
      module Maps
        # rubocop:disable Metrics/ParameterLists
        def initialize_map_operation(map_id, count, parent_reactor_class_name, reactor_class_info:,
                                     strict_ordering: true, parent_context_id: nil, step_name: nil,
                                     parent_is_map_element: false,
                                     outer_map_id: nil, outer_index: nil, owner_context_id: nil,
                                     owner_reactor_class_name: nil, batch_size: nil, atomic: nil)
          # Same metadata as RedisAdapter#initialize_map_operation.
          metadata = {
            map_id: map_id, count: count, strict_ordering: strict_ordering, reactor_class_info: reactor_class_info,
            parent_context_id: parent_context_id, parent_reactor_class_name: parent_reactor_class_name,
            step_name: step_name, parent_is_map_element: parent_is_map_element, outer_map_id: outer_map_id,
            outer_index: outer_index, owner_context_id: owner_context_id,
            owner_reactor_class_name: owner_reactor_class_name, batch_size: batch_size, atomic: atomic,
            created_at: Time.now.to_i
          }
          with_db do
            ensure_map(map_id, parent_reactor_class_name)
            map_scope(map_id, parent_reactor_class_name)
              .update_all(counter: count, metadata: JSON.generate(metadata), updated_at: Time.current)
          end
        end
        # rubocop:enable Metrics/ParameterLists

        def retrieve_map_metadata(map_id, reactor_class_name)
          json = with_db { map_scope(map_id, reactor_class_name).pick(:metadata) }
          json && JSON.parse(json)
        end

        # The map sweeper's input, within the R-08 window.
        def scan_maps(count: 1000)
          with_db { recent(MapOperation).where.not(metadata: nil).order(:updated_at).limit(count).pluck(:metadata) }
            .map { |json| JSON.parse(json) }
        end

        def set_map_counter(map_id, count, reactor_class_name)
          set_map_column(map_id, reactor_class_name, :counter, count)
        end

        def increment_map_counter(map_id,
                                  reactor_class_name)
          add_to_map_column(map_id, reactor_class_name, :counter, 1)
        end

        def decrement_map_counter(map_id,
                                  reactor_class_name)
          add_to_map_column(map_id, reactor_class_name, :counter, -1)
        end

        def decrement_map_counter_by(map_id, amount, reactor_class_name)
          add_to_map_column(map_id, reactor_class_name, :counter, -amount)
        end

        def set_last_queued_index(map_id, index, reactor_class_name)
          set_map_column(map_id, reactor_class_name, :last_queued_index, index)
        end

        def increment_last_queued_index(map_id, reactor_class_name)
          add_to_map_column(map_id, reactor_class_name, :last_queued_index, 1)
        end

        def set_map_offset(map_id, offset, reactor_class_name)
          set_map_column(map_id, reactor_class_name, :dispatch_offset, offset)
        end

        def set_map_offset_if_not_exists(map_id, offset, reactor_class_name)
          claim_map_column(map_id, reactor_class_name, :dispatch_offset, offset)
        end

        # A String, like Redis GET; nil when never set.
        def retrieve_map_offset(map_id, reactor_class_name)
          with_db { map_scope(map_id, reactor_class_name).pick(:dispatch_offset) }&.to_s
        end

        def increment_map_offset(map_id, increment, reactor_class_name)
          add_to_map_column(map_id, reactor_class_name, :dispatch_offset, increment)
        end

        # The first failure wins.
        def store_map_failed_context_id(map_id, context_id, reactor_class_name)
          claim_map_column(map_id, reactor_class_name, :failed_context_id, context_id)
        end

        def retrieve_map_failed_context_id(map_id, reactor_class_name)
          with_db { map_scope(map_id, reactor_class_name).pick(:failed_context_id) }
        end

        # Claimed once, by the collector that found the map settled.
        def claim_map_owner_signal(map_id, reactor_class_name)
          claim_map_column(map_id, reactor_class_name, :owner_signalled_at, Time.current)
        end

        # Re-dispatching index i overwrites slot i, never duplicates it.
        def store_map_result(map_id, index, serialized_result, reactor_class_name, strict_ordering: true) # rubocop:disable Lint/UnusedMethodArgument
          with_db do
            id = ensure_map(map_id, reactor_class_name)
            MapResult.upsert({ map_operation_id: id, element_index: index.to_i, result: serialized_result.to_json })
          end
        end

        def retrieve_map_results(map_id, reactor_class_name, strict_ordering: true) # rubocop:disable Lint/UnusedMethodArgument
          parse_all(with_db { results_scope(map_id, reactor_class_name).order(:element_index).pluck(:result) })
        end

        def retrieve_map_results_batch(map_id, reactor_class_name, offset:, limit:, strict_ordering: true) # rubocop:disable Lint/UnusedMethodArgument
          parse_all(with_db do
            results_scope(map_id, reactor_class_name).where(element_index: offset...(offset + limit))
                                                     .order(:element_index).pluck(:result)
          end)
        end

        def count_map_results(map_id, reactor_class_name)
          with_db { results_scope(map_id, reactor_class_name).count }
        end

        def missing_map_indices(map_id, count, reactor_class_name)
          (0...count).to_a - with_db { results_scope(map_id, reactor_class_name).pluck(:element_index) }
        end

        # Aligned with `indexes`; nil where a slot is missing.
        def retrieve_map_result_slots(map_id, reactor_class_name, indexes)
          return [] if indexes.empty?

          by_index = with_db do
            results_scope(map_id, reactor_class_name).where(element_index: indexes.map(&:to_i))
                                                     .pluck(:element_index, :result).to_h
          end
          indexes.map { |index| (raw = by_index[index.to_i]) && JSON.parse(raw) }
        end

        # Appends at `element_count`, under the map row lock: positions never
        # shift, which 009's tail-anchored rollback relies on (R-12).
        def store_map_element_context_id(map_id, context_id, reactor_class_name)
          with_locked_map(map_id, reactor_class_name) do |map|
            MapElement.insert!({ map_operation_id: map.id, position: map.element_count, context_id: context_id })
            MapOperation.where(id: map.id).update_all(element_count: map.element_count + 1)
            map.element_count + 1
          end
        end

        def retrieve_map_element_context_ids(map_id, reactor_class_name)
          with_db { elements_scope(map_id, reactor_class_name).order(:position).pluck(:context_id) }
        end

        # LINDEX semantics, negative indexes included.
        def retrieve_map_element_context_id(map_id, reactor_class_name, index: -1)
          total = count_map_element_context_ids(map_id, reactor_class_name)
          position = index.negative? ? total + index : index
          return nil if position.negative? || position >= total

          with_db { elements_scope(map_id, reactor_class_name).where(position: position).pick(:context_id) }
        end

        def count_map_element_context_ids(map_id, reactor_class_name)
          with_db { map_scope(map_id, reactor_class_name).pick(:element_count) }.to_i
        end

        # Ids at tail positions `position...position + count`, tail first; the
        # same window arithmetic as RedisMapRollback.
        def retrieve_map_element_context_ids_from_tail(map_id, reactor_class_name, position, count, total:)
          stop = total - 1 - position
          return [] if stop.negative?

          start = [total - position - count, 0].max
          with_db do
            elements_scope(map_id, reactor_class_name).where(position: start..stop)
                                                      .order(position: :desc).pluck(:context_id)
          end
        end

        private

        def map_scope(map_id,
                      reactor_class_name)
          MapOperation.where(storage_name: reactor_class_name.to_s, map_id: map_id)
        end

        def results_scope(map_id, reactor_class_name)
          MapResult.where(map_operation_id: map_scope(map_id, reactor_class_name).select(:id))
        end

        def elements_scope(map_id, reactor_class_name)
          MapElement.where(map_operation_id: map_scope(map_id, reactor_class_name).select(:id))
        end

        # The map's row id, creating the row (all keys absent) on first use.
        def ensure_map(map_id, reactor_class_name)
          now = Time.current
          MapOperation.insert_all([{ storage_name: reactor_class_name.to_s, map_id: map_id, created_at: now,
                                     updated_at: now }])
          map_scope(map_id, reactor_class_name).pick(:id)
        end

        def with_locked_map(map_id, reactor_class_name)
          with_db do
            Record.transaction do
              ensure_map(map_id, reactor_class_name)
              yield map_scope(map_id, reactor_class_name).lock.first
            end
          end
        end

        def set_map_column(map_id, reactor_class_name, column, value)
          with_db do
            ensure_map(map_id, reactor_class_name)
            map_scope(map_id, reactor_class_name).update_all(column => value)
          end
        end

        # INCRBY: returns the post-change value.
        def add_to_map_column(map_id, reactor_class_name, column, amount)
          with_locked_map(map_id, reactor_class_name) do |map|
            updated = map[column].to_i + amount.to_i
            MapOperation.where(id: map.id).update_all(column => updated)
            updated
          end
        end

        # SET NX: true only for the caller that filled the column.
        def claim_map_column(map_id, reactor_class_name, column, value)
          with_db do
            ensure_map(map_id, reactor_class_name)
            map_scope(map_id, reactor_class_name).where(column => nil).update_all(column => value) == 1
          end
        end

        def parse_all(rows) = rows.map { |json| JSON.parse(json) }
      end
    end
  end
end
