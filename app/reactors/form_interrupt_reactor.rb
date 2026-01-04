class FormInterruptReactor < RubyReactor::Reactor
  input :user_name
  input :fail_at, optional: true do
    optional(:fail_at).maybe(:symbol)
  end

  step :prepare_application do
    argument :user_name, input(:user_name)
    argument :fail_at, input(:fail_at)
    run do |args, _|
      if args[:fail_at] == :prepare_application
        raise "Failure triggered for prepare_application"
      else
        Success({
          application_id: SecureRandom.hex(6),
          name: args[:user_name],
          timestamp: Time.now
        })
      end
    end
  end

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



  interrupt :wait_for_user_input do
    wait_for :prepare_application
    
    # We pause here. The user will be redirected to a form to enter additional info.
    # The form submission will resume this reactor using the reactor_id (default resumption, no correlation_id needed explicitly if using reactor_id)
    # But for demo, let's say we use application_id as correlation key
    # {"key": "value"}
    correlation_id do |context|
      context.result(:prepare_application)[:application_id]
    end
  end

  interrupt :wait_for_approval do
    wait_for :prepare_application
    
    # We pause here. The user will be redirected to a form to enter additional info.
    # The form submission will resume this reactor using the reactor_id (default resumption, no correlation_id needed explicitly if using reactor_id)
    # But for demo, let's say we use application_id as correlation key
    # {"user": "admin", "approved": true}
    correlation_id do |context|
      "#{context.result(:prepare_application)[:application_id]}_approval"
    end

    validate do
      required(:user).filled(:string)
      required(:approved).filled(:bool)
    end
  end

  step :finalize_application do
    argument :application, result(:prepare_application)
    argument :user_input, result(:wait_for_user_input)
    argument :approval, result(:wait_for_approval)
    argument :fail_at, input(:fail_at)

    run do |args, _|
      if args[:fail_at] == :finalize_application
        raise "Failure triggered for finalize_application"
      else
        final_record = args[:application].merge(
          additional_info: args[:user_input][:bio],
          status: "complete"
        )
        Success(final_record)
      end
    end
  end

  step :async_step_after do
    async true
    argument :user_input, result(:wait_for_user_input)
    argument :fail_at, input(:fail_at)
    run do |args, _|
      if args[:fail_at] == :async_step_after
        raise "Failure triggered for async_step_after"
      else
        Success("Async step after completed")
      end
    end
  end

  returns :finalize_application
end
