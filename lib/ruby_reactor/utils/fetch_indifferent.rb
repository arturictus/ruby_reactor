# frozen_string_literal: true

module RubyReactor
  module Utils
    # Presence-aware symbol/string lookup: a supplied `false` is returned as
    # `false`, never swallowed by an `a || b` fallback into `nil`.
    class FetchIndifferent
      def self.call(hash, key)
        hash.key?(key.to_sym) ? hash[key.to_sym] : hash[key.to_s]
      end
    end
  end
end
