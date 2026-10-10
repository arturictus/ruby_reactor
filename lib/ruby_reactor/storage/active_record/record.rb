# frozen_string_literal: true

module RubyReactor
  module Storage
    class ActiveRecordAdapter
      # Abstract base for every storage model. The adapter calls
      # `establish_connection` on it, which gives reactor storage its own pool:
      # its writes commit independently of any host transaction (011 R-02).
      class Record < ::ActiveRecord::Base
        self.abstract_class = true
      end
    end
  end
end
