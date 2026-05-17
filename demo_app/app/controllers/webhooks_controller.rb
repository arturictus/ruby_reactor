class WebhooksController < ApplicationController
  skip_before_action :verify_authenticity_token

  def receive
    # The webhook provider sends back the request_id we sent them, and a status
    request_id = params[:request_id]
    status = params[:status]

    # Resume the reactor waiting for this request_id
    result = WebhookInterruptReactor.continue_by_correlation_id(
      correlation_id: request_id, 
      payload: { status: status },
      step_name: :wait_for_webhook
    )

    if result
      render json: { message: "Reactor resumed", result: result.to_h }, status: :ok
    else
      render json: { message: "No paused reactor found for this ID" }, status: :not_found
    end
  end
end
