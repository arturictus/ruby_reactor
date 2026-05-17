class PartialAsyncReactor < RubyReactor::Reactor
  input :user_id

  step :validate_user do
    argument :user_id, input(:user_id)
    run do |args|
      puts "PartialAsyncReactor: Validating user #{args[:user_id]} synchronously"
      if args[:user_id].present?
        Success(args[:user_id])
      else
        Failure("Invalid user")
      end
    end
  end

  step :heavy_processing do
    async true
    argument :user_id, result(:validate_user)
    
    run do |args|
      puts "PartialAsyncReactor: Processing user #{args[:user_id]} in background job"
      sleep 2
      Success("Heavy processing complete")
    end
  end

  step :notify_completion do
    argument :result, result(:heavy_processing)
    
    run do |args|
      puts "PartialAsyncReactor: Notification sent. Result: #{args[:result]}"
      Success("Done")
    end
  end

  returns :notify_completion
end
