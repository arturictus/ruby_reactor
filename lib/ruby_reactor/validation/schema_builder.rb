# frozen_string_literal: true

require "dry-validation"

module RubyReactor
  module Validation
    class SchemaBuilder
      def self.build_from_block(&block)
        Dry::Schema.Params(&block)
      end

      def self.build_contract_from_block(&block)
        Class.new(Dry::Validation::Contract, &block).new
      end
    end
  end
end
