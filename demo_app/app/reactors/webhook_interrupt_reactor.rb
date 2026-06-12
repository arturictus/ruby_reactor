class WebhookInterruptReactor < RubyReactor::Reactor
  input :provider_id
  input :fail_at, :symbol, optional: true

  step :async_step_before do
    async true
    argument :fail_at, input(:fail_at)
    run do |args, _|
      if args[:fail_at] == :async_step_before
        raise "Failure triggered for async_step_before"
      else
        Success("Async step before completed")
      end
    end
  end

  step :initiate_request do
    argument :provider_id, input(:provider_id)
    argument :fail_at, input(:fail_at)
    run do |args, _|
      if args[:fail_at] == :initiate_request
        raise "Failure triggered for initiate_request"
      else
        # Simulate sending a request to an external provider
        # They will call us back with this ID
        external_id = "req_#{args[:provider_id]}_#{SecureRandom.hex(4)}"
        Success(external_id)
      end
    end
  end

  interrupt :wait_for_webhook do
    wait_for :initiate_request
    
    # We expect the payload from webhook to be { status: "approved" }
    # correlation_id matching logic:
    # We will resume this reactor when a webhook comes with `external_id` matching result of initiate_request
    # {"status": "approved"}
    correlation_id do |context|
      context.result(:initiate_request)
    end
    validate_payload do
      required(:status).filled(:string)
    end
  end

  step :process_response do
    argument :webhook_data, result(:wait_for_webhook)
    argument :fail_at, input(:fail_at)
    
    run do |args, _|
      if args[:fail_at] == :process_response
        raise "Failure triggered for process_response"
      elsif args[:webhook_data]["status"] == "approved"
        Success("Request successfully approved via webhook")
      else
        Failure("Request rejected via webhook")
      end
    end
  end

  step :async_step_after do
    async true
    argument :webhook_data, result(:wait_for_webhook)
    argument :fail_at, input(:fail_at)
    run do |args, _|
      if args[:fail_at] == :async_step_after
        raise "Failure triggered for async_step_after"
      else
        Success("Async step after completed")
      end
    end
  end

  returns :process_response
end
