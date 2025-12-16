# frozen_string_literal: true

module RubyReactor
  class InterruptResult
    attr_reader :execution_id, :correlation_id, :status, :timeout_at, :intermediate_results

    def initialize(execution_id:, correlation_id: nil, timeout_at: nil, intermediate_results: {})
      @execution_id = execution_id
      @correlation_id = correlation_id
      @status = :paused
      @timeout_at = timeout_at
      @intermediate_results = intermediate_results
    end

    def paused?
      true
    end
  end
end
