class FormInterruptReactor < RubyReactor::Reactor
  input :user_name

  step :prepare_application do
    argument :user_name, input(:user_name)
    run do |args, _|
      Success({
        application_id: SecureRandom.hex(6),
        name: args[:user_name],
        timestamp: Time.now
      })
    end
  end

  interrupt :wait_for_user_input do
    wait_for :prepare_application
    
    # We pause here. The user will be redirected to a form to enter additional info.
    # The form submission will resume this reactor using the reactor_id (default resumption, no correlation_id needed explicitly if using reactor_id)
    # But for demo, let's say we use application_id as correlation key
    correlation_id do |context|
      context.result(:prepare_application)[:application_id]
    end
  end

  step :finalize_application do
    argument :application, result(:prepare_application)
    argument :user_input, result(:wait_for_user_input)

    run do |args, _|
      final_record = args[:application].merge(
        additional_info: args[:user_input][:bio],
        status: "complete"
      )
      Success(final_record)
    end
  end

  returns :finalize_application
end
