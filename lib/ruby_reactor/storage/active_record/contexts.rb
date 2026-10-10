# frozen_string_literal: true

module RubyReactor
  module Storage
    class ActiveRecordAdapter
      # Reactor contexts, correlation ids and the context scans (011 DM §2, §9;
      # R-08, R-09).
      module Contexts
        TERMINAL_STATUSES = %w[completed failed halted aborted cancelled].freeze
        INDEXABLE_INPUT = [String, Integer, Float, TrueClass, FalseClass, NilClass].freeze

        # Last writer wins, like Redis SET. The query columns are projected from
        # the context; `started_at` and `created_at` are written once.
        def store_context(context_id, serialized_context, reactor_class_name)
          check_context_size!(serialized_context)
          data = JSON.parse(serialized_context)
          now = Time.current
          status = determine_status(data)
          attrs = {
            storage_name: reactor_class_name.to_s, reactor_class: (data["reactor_class"] || reactor_class_name).to_s,
            status: status, parent_context_id: data["parent_context_id"], root_context_id: data["root_context_id"],
            correlation_id: data["correlation_id"]&.to_s, dispatched_child: dispatched_child?(data) || false,
            context: serialized_context, updated_at: now
          }
          with_db do
            write_row(Execution, { id: context_id }, attrs,
                      insert_only: { started_at: parse_time(data["started_at"]) || now, created_at: now })
            unfinished = Execution.where(id: context_id, finished_at: nil)
            unfinished.update_all(finished_at: now) if TERMINAL_STATUSES.include?(status)
            index_inputs(context_id, data)
          end
        end

        def retrieve_context(context_id, reactor_class_name)
          json = with_db { Execution.where(id: context_id, storage_name: reactor_class_name.to_s).pick(:context) }
          json && JSON.parse(json)
        end

        def find_context_by_id(context_id)
          json = with_db { Execution.where(id: context_id).pick(:context) }
          json && JSON.parse(json)
        end

        def delete_context(context_id, reactor_class_name)
          with_db do
            deleted = Execution.where(id: context_id, storage_name: reactor_class_name.to_s).delete_all
            ExecutionInput.where(execution_id: context_id).delete_all if deleted.positive?
            deleted
          end
        end

        def expire(_key, _seconds)
          nil
        end

        def store_correlation_id(correlation_id, context_id, reactor_class_name)
          key = { storage_name: reactor_class_name.to_s, correlation_digest: Coordination.digest(correlation_id) }
          with_db do
            CorrelationId.insert!(key.merge(correlation_id: correlation_id.to_s, context_id: context_id))
          rescue ::ActiveRecord::RecordNotUnique
            return if CorrelationId.where(key).pick(:context_id) == context_id

            raise Error::ValidationError, "Correlation ID '#{correlation_id}' already exists"
          end
          nil
        end

        def retrieve_context_id_by_correlation_id(correlation_id, reactor_class_name)
          with_db do
            CorrelationId.where(storage_name: reactor_class_name.to_s,
                                correlation_digest: Coordination.digest(correlation_id)).pick(:context_id)
          end
        end

        def delete_correlation_id(correlation_id, reactor_class_name)
          with_db do
            CorrelationId.where(storage_name: reactor_class_name.to_s,
                                correlation_digest: Coordination.digest(correlation_id)).delete_all
          end
        end

        # The sweeper's view: only runs written within `context_ttl` — exactly
        # what Redis would still hold — so keeping history never revives work
        # stranded longer ago (R-08). `statuses:` (the sweeper's) is applied in
        # SQL, before the cap, so finished runs can't crowd a fresh strand out
        # on a busy app (review F4). `pattern` is a Redis glob; unused here.
        def scan_reactors(pattern: nil, count: 50, include_dispatched_children: false, statuses: nil) # rubocop:disable Lint/UnusedMethodArgument
          scope = recent(Execution)
          scope = scope.where(status: statuses) if statuses
          scope = top_level(scope, include_dispatched_children)
          rows_for(with_db { scope.order(:updated_at).limit(count).pluck(:context) })
        end

        # The dashboard's view: all history, newest first, keyset-paged. The
        # cursor is opaque; "0" starts, and ends, the walk.
        def scan_reactors_page(pattern: nil, cursor: "0", count: 50, include_dispatched_children: false) # rubocop:disable Lint/UnusedMethodArgument
          page(top_level(Execution.all, include_dispatched_children), cursor, count)
        end

        # The dashboard's filtered listing over all history (R-18). Filters:
        # reactor_class, status, from/to (on started_at) and inputs
        # ({ name => value }, equality on the indexed top-level inputs).
        def query_executions(filters:, cursor: "0", count: 50)
          scope = top_level(Execution.all, false)
          scope = scope.where(reactor_class: filters[:reactor_class].to_s) if filters[:reactor_class]
          scope = scope.where(status: filters[:status].to_s) if filters[:status]
          scope = scope.where(started_at: filters[:from]..) if filters[:from]
          scope = scope.where(started_at: ..filters[:to]) if filters[:to]
          (filters[:inputs] || {}).each do |name, value|
            scope = scope.where(ExecutionInput.where("#{ExecutionInput.table_name}.execution_id = " \
                                                     "#{Execution.table_name}.id")
                                              .where(name: name.to_s, value: value.to_s).arel.exists)
          end
          page(scope, cursor, count)
        end

        private

        def page(scope, cursor, count)
          if (position = decode_cursor(cursor))
            started_at, id = position
            scope = scope.where("started_at < ? OR (started_at = ? AND id < ?)", started_at, started_at, id)
          end
          records = with_db do
            scope.order(started_at: :desc, id: :desc).limit(count + 1).pluck(:started_at, :id, :context)
          end
          more = records.size > count
          records = records.first(count)
          next_cursor = more ? encode_cursor(records.last[0], records.last[1]) : "0"
          { reactors: rows_for(records.map(&:last)), cursor: next_cursor }
        end

        def rows_for(contexts)
          contexts.filter_map do |json|
            data = JSON.parse(json)
            reactor_row(data) if data["reactor_class"]
          end
        end

        def top_level(scope, include_dispatched_children)
          return scope.where(parent_context_id: nil) unless include_dispatched_children

          scope.where("parent_context_id IS NULL OR dispatched_child = ?", true)
        end

        def recent(model)
          model.where("updated_at > ?", Time.current - RubyReactor.configuration.context_ttl)
        end

        def encode_cursor(started_at, id)
          ["#{started_at.utc.iso8601(6)}|#{id}"].pack("m0").tr("+/", "-_")
        end

        def decode_cursor(cursor)
          return nil if cursor.nil? || cursor.to_s == "0"

          started_at, id = cursor.to_s.tr("-_", "+/").unpack1("m0").split("|", 2)
          [Time.iso8601(started_at), id]
        rescue ArgumentError
          raise Error::ValidationError, "Invalid cursor '#{cursor}'"
        end

        def parse_time(value)
          value && Time.parse(value.to_s)
        rescue ArgumentError
          nil
        end

        # The dashboard's input index (R-11): top-level scalar inputs of 255
        # characters or fewer, never the reactor's `redact: true` ones. Written
        # on every store; inputs don't change, so repeats skip as duplicates.
        def index_inputs(context_id, data)
          rows = indexable_inputs(data).map { |name, value| { execution_id: context_id, name: name, value: value } }
          ExecutionInput.insert_all(rows) if rows.any?
        end

        def indexable_inputs(data)
          reactor_class = RubyReactor::Context.resolve_reactor_class(data["reactor_class"])
          return {} unless reactor_class.respond_to?(:inputs) && data["inputs"].is_a?(Hash)

          redacted = reactor_class.inputs.select { |_, config| config[:redact] }.keys.map(&:to_s)
          ContextSerializer.deserialize_value(data["inputs"]).each_with_object({}) do |(name, value), indexed|
            next if redacted.include?(name.to_s) || INDEXABLE_INPUT.none? { |type| value.is_a?(type) }

            text = value.nil? ? "null" : value.to_s
            indexed[name.to_s] = text if text.length <= 255
          end
        end

        # MySQL rejects statements larger than max_allowed_packet; fail with the
        # serializer's own error instead of a driver error (R-10).
        def check_context_size!(serialized)
          limit = max_packet_bytes
          return if limit.nil? || serialized.bytesize < limit

          raise Error::ContextTooLargeError,
                "Context size #{serialized.bytesize} bytes exceeds the database's max_allowed_packet (#{limit} bytes)"
        end

        # Cached per pool: re-pointing the adapter at another database (tests,
        # reconfiguration) must not reuse another engine's answer.
        def max_packet_bytes
          pool = Record.connection_pool
          return @max_packet.last if @max_packet&.first.equal?(pool)

          bytes = with_db do |conn|
            # Headroom for the rest of the statement and escaping.
            conn.select_value("SELECT @@max_allowed_packet").to_i / 2 if conn.adapter_name.match?(/mysql|trilogy/i)
          end
          @max_packet = [pool, bytes]
          bytes
        end
      end
    end
  end
end
