# frozen_string_literal: true

class MultipleRequestsReactor < RubyReactor::Reactor
  input :request_id do
    required(:request_id).filled(:integer)
  end

  step :call_service_1 do
    argument :request_id, input(:request_id)
    run do |_args, _context|
      raise "Webmock stopping the request in test env"
    end
  end

  step :call_service_2 do
    argument :request_id, input(:request_id)
    run do |_args, _context|
      raise "Webmock stopping the request in test env"
    end
  end

  step :call_service_3 do
    argument :request_id, input(:request_id)
    run do |_args, _context|
      raise "Webmock stopping the request in test env"
    end
  end

  step :unify_results do
    argument :request_id, input(:request_id)
    argument :service_1_result, result(:call_service_1)
    argument :service_2_result, result(:call_service_2)
    argument :service_3_result, result(:call_service_3)
    run do |args, _context|
      Success({
                request_id: args[:request_id],
                service_1_result: args[:service_1_result],
                service_2_result: args[:service_2_result],
                service_3_result: args[:service_3_result]
              })
    end
  end
end
