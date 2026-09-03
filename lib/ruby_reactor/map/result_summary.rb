# frozen_string_literal: true

module RubyReactor
  module Map
    # A map's result set is unbounded, so the API describes it instead of
    # inlining it. Inlining meant the JSON encoder materialized the lazy
    # ResultEnumerator itself — one storage read per element — and rendered every
    # element failure as an opaque blob with no count of how many there were.
    class ResultSummary
      # How many failed elements are described in full. The rest are only
      # counted — a map failing 50k elements must not produce a 50k-entry
      # response.
      SAMPLE_LIMIT = 25

      # Sampled failures are a list, not a detail view, and the same summary is
      # echoed in intermediate_results, the execution trace and the undo stack —
      # full traces on each would triple a large payload.
      BACKTRACE_FRAMES = 10

      # ponytail: one windowed read of the whole map; paginate if maps grow past
      # what fits in a single response.
      def self.build(enumerator)
        total = enumerator.count
        results = RubyReactor.configuration.storage_adapter.retrieve_map_results_batch(
          enumerator.map_id, enumerator.reactor_class_name, offset: 0, limit: total
        )
        # Slots are index-keyed and the window starts at 0, so a full read means
        # position == element index. A short read means the map is still filling
        # in and gaps would shift positions — then indices are omitted.
        failures = collect_failures(results, indexed: results.size == total)

        {
          "_type" => "map_results",
          "total" => total,
          "succeeded" => total - failures[:count],
          "failed" => failures[:count],
          "failures" => failures[:sample],
          "failures_truncated" => failures[:count] > failures[:sample].size
        }
      end

      def self.collect_failures(results, indexed:)
        count = 0
        sample = []

        results.each_with_index do |raw, position|
          next unless raw.is_a?(Hash) && raw.key?("_error")

          count += 1
          next if sample.size >= SAMPLE_LIMIT

          entry = ContextSerializer.simplify_for_api(Failure.new(raw["_error"], backtrace: []))
          entry["backtrace"] = Array(entry["backtrace"]).first(BACKTRACE_FRAMES)
          entry["index"] = position if indexed
          sample << entry
        end

        { count: count, sample: sample }
      end
      private_class_method :collect_failures
    end
  end
end
