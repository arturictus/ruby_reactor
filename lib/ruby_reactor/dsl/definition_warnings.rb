# frozen_string_literal: true

module RubyReactor
  module Dsl
    # Definition-time warnings for the DSL builders, printed once per
    # declaration site for the process. The including builder sets `@reactor`.
    module DefinitionWarnings
      def self.deprecation_sites
        @deprecation_sites ||= Set.new
      end

      private

      def warn_deprecation(site, message)
        warn_definition(site, "DEPRECATION:", "#{message} Removal no earlier than the next MAJOR.")
      end

      def warn_definition(site, prefix, message)
        location = "#{site.path}:#{site.lineno}"
        return unless DefinitionWarnings.deprecation_sites.add?(location)

        warn ["[RubyReactor]", prefix, location, reactor_label, message].compact.join(" ")
      end

      def reactor_label
        @reactor&.name || @reactor.inspect
      end
    end
  end
end
