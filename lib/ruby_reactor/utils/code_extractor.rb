# frozen_string_literal: true

module RubyReactor
  module Utils
    class CodeExtractor
      def self.extract(file_path, line_number, radius: 2)
        return nil unless file_path && line_number && File.exist?(file_path)

        lines = File.readlines(file_path)
        total_lines = lines.size
        target_index = line_number - 1

        return nil if target_index < 0 || target_index >= total_lines

        start_index = [0, target_index - radius].max
        end_index = [total_lines - 1, target_index + radius].min

        snippet = []
        (start_index..end_index).each do |i|
          snippet << {
            line_number: i + 1,
            content: lines[i].chomp,
            target: i == target_index
          }
        end

        snippet
      rescue StandardError => e
        # Fail gracefully if file reading fails
        nil
      end
    end
  end
end
