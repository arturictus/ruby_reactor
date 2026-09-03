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

        if @strict_ordering
          count.times do |i|
            yield self[i]
          end
        else
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

            results.each { |result| yield wrap_result(result) }

            offset += results.size
            break if results.size < @batch_size
          end
        end
      end

      def count
        @count ||= @storage.count_map_results(@map_id, @reactor_class_name)
      end
      alias size count
      alias length count

      def empty?
        count.zero?
      end

      def any?
        !empty?
      end

      def [](index)
        index += count if index.negative?
        return nil if index.negative? || index >= count

        results = @storage.retrieve_map_results_batch(
          @map_id,
          @reactor_class_name,
          offset: index,
          limit: 1,
          strict_ordering: @strict_ordering
        )

        return nil if results.empty?

        wrap_result(results.first)
      end

      def first
        self[0]
      end

      def last
        self[-1]
      end

      def successes
        lazy.grep(RubyReactor::Success).map(&:value)
      end

      def failures
        lazy.grep(RubyReactor::Failure).map(&:error)
      end

      private

      def wrap_result(result)
        if result.is_a?(Hash) && result.key?("_error")
          # `backtrace: []` is load-bearing: without it Failure falls back to
          # `caller`, so a bare-message element failure would carry the stack of
          # whoever happened to materialize the enumerator (the JSON encoder, in
          # the dashboard's case) instead of the stack of the step that failed.
          RubyReactor::Failure.new(result["_error"], backtrace: [])
        else
          RubyReactor::Success.new(ContextSerializer.deserialize_value(result))
        end
      end
    end
  end
end
