# frozen_string_literal: true

# A step that owns its input contract. Every reactor that uses it gets exactly
# these rules, and none of them restates one: ValidatedSignupReactor and
# ValidatedSignupAsyncReactor only say where the values come from (here, the
# same-named reactor inputs, so not even an `argument` line).
class ValidatedUserStep < RubyReactor::Step
  input :name, :string, min_size?: 2
  input :email, :string
  input :age, :integer, gteq?: 18
  input :bio, :string, optional: true, default: "No bio provided", max_size?: 100
  input :marketing_opt_in, :bool

  def run
    Rails.logger.info "ValidatedUserStep: creating profile for #{inputs[:email]}"
    Success(inputs.merge(created_at: Time.current.iso8601))
  end
end
