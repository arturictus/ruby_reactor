# frozen_string_literal: true

module RubyReactor
  module Utils
    class BacktraceLocation
      # Ruby 3.x backtraces use single-quoted method names; older formats use backticks.
      LINE_PATTERN = /^(.+?):(\d+)(?::in .*)?$/

      def self.parse(line)
        match = line.match(LINE_PATTERN)
        return nil unless match

        [match[1], match[2].to_i]
      end

      def self.internal_path?(file_path)
        file_path.start_with?(RubyReactor.internal_lib_path)
      end

      def self.extract(backtrace)
        return [nil, nil] unless backtrace.is_a?(Array) && backtrace.any?

        skip_internal = ENV["RUBY_REACTOR_DEBUG"] != "true"

        backtrace.each do |line|
          file_path, line_number = parse(line)
          next unless file_path
          next if skip_internal && internal_path?(file_path)

          return [file_path, line_number]
        end

        parse(backtrace.first) || [nil, nil]
      end
    end
  end
end
