# frozen_string_literal: true

module RubyReactor
  module Map
    class ResultEnumerator
      include Enumerable

      DEFAULT_BATCH_SIZE = 1000

      attr_reader :map_id, :reactor_class_name, :strict_ordering, :batch_size

      def initialize(map_id, reactor_class_name, strict_ordering: true, batch_size: DEFAULT_BATCH_SIZE)
        @map_id = map_id
        @reactor_class_name = reactor_class_name
        @strict_ordering = strict_ordering
        @batch_size = batch_size
        @storage = RubyReactor.configuration.storage_adapter
      end

      def each
        return enum_for(:each) unless block_given?

        offset = 0
        loop do
          results = @storage.retrieve_map_results_batch(
            @map_id,
            @reactor_class_name,
            offset: offset,
            limit: @batch_size,
            strict_ordering: @strict_ordering
          )

          break if results.empty?

          results.each do |result|
            if result.is_a?(Hash) && result.key?("_error")
              yield RubyReactor::Failure.new(result["_error"])
            else
              yield RubyReactor::Success.new(ContextSerializer.deserialize_value(result))
            end
          end

          offset += results.size

          # Optimization: if we got less than batch_size, we are likely done (if data is static)
          # But in async maps, results might be filling up?
          # For 'collect', we assume map is DONE so results are static.
          break if results.size < @batch_size
        end
      end

      def successes
        lazy.select { |result| result.is_a?(RubyReactor::Success) }.map(&:value)
      end

      def failures
        lazy.select { |result| result.is_a?(RubyReactor::Failure) }.map(&:error)
      end
    end
  end
end
