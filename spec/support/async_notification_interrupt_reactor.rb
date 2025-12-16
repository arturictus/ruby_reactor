# frozen_string_literal: true

class AsyncNotificationInterruptReactor < RubyReactor::Reactor
  def self.trace
    @trace ||= []
  end

  step :retrieve_context do
    run do |_args, context|
      context.reactor_class.trace << :retrieve_context
      Success({ user_id: 123 })
    end
  end

  step :send_notifications do
    async true
    argument :user_id, result(:retrieve_context)
    run do |args, context|
      context.reactor_class.trace << :send_notifications
      # Simulate sending notifications
      # args[:user_id] is the value directly because retrieve_context returns { user_id: 123 }
      # Wait, retrieve_context returns Success({ user_id: 123 }).
      # result(:retrieve_context) resolves to { user_id: 123 }.
      # argument :user_id, result(:retrieve_context) means args[:user_id] = { user_id: 123 }
      # We probably want a transform or access the value properly.

      # Let's fix the argument source to grab the specific key or fix the interpolation.
      # Ideally: argument :user_id, result(:retrieve_context), transform: ->(res) { res[:user_id] }

      Success("notifications_sent_to_#{args[:user_id][:user_id]}")
    end
  end

  interrupt :manager_approval do
    wait_for :send_notifications

    validate do
      required(:status).filled(:string, eql?: "approved")
    end
  end

  step :process_approval do
    async true
    argument :notification_status, result(:send_notifications)
    argument :approval_payload, result(:manager_approval)

    run do |args, context|
      context.reactor_class.trace << :process_approval
      Success("processed_#{args[:approval_payload][:status]}_after_#{args[:notification_status]}")
    end
  end

  returns :process_approval
end
