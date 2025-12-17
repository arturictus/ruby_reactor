class WebhookInterruptReactor < RubyReactor::Reactor
  input :provider_id

  step :initiate_request do
    argument :provider_id, input(:provider_id)
    run do |args, _|
      # Simulate sending a request to an external provider
      # They will call us back with this ID
      external_id = "req_#{args[:provider_id]}_#{SecureRandom.hex(4)}"
      Success(external_id)
    end
  end

  interrupt :wait_for_webhook do
    wait_for :initiate_request
    
    # We expect the payload from webhook to be { status: "approved" }
    # correlation_id matching logic:
    # We will resume this reactor when a webhook comes with `external_id` matching result of initiate_request
    correlation_id do |context|
      context.result(:initiate_request)
    end
  end

  step :process_response do
    argument :webhook_data, result(:wait_for_webhook)
    
    run do |args, _|
      if args[:webhook_data][:status] == "approved"
        Success("Request successfully approved via webhook")
      else
        Failure("Request rejected via webhook")
      end
    end
  end

  returns :process_response
end
