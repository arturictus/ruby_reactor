class FormInterruptReactorReproduction < RubyReactor::Reactor
  input :user_name
  input :fail_at, optional: true do
    optional(:fail_at).maybe(:symbol)
  end

  step :prepare_application do
    argument :user_name, input(:user_name)
    argument :fail_at, input(:fail_at)
    run do |args, _|
      raise "Failure triggered for prepare_application" if args[:fail_at] == :prepare_application

      Success({
                application_id: SecureRandom.hex(6),
                name: args[:user_name],
                timestamp: Time.now
              })
    end
  end

  interrupt :wait_for_user_input do
    wait_for :prepare_application

    correlation_id do |context|
      context.result(:prepare_application)[:application_id]
    end
  end

  interrupt :wait_for_approval do
    wait_for :prepare_application
    max_attempts 2

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
      raise "Failure triggered for finalize_application" if args[:fail_at] == :finalize_application

      final_record = args[:application].merge(
        additional_info: args[:user_input][:bio],
        status: "complete"
      )
      Success(final_record)
    end
  end

  returns :finalize_application
end
