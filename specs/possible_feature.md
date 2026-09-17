# Future improvements for review

## Guard

I want to add another hook feature to the step: `guard`
A guard concept is to execute after validations and before run.
example:

```ruby
class SendEmail < RubyReactor::Step
  input :email, :string, format?: /\A[^@\s]+@[^@\s]+\z/

  def guard
    fail!("Prevent spamming") if EmailService.sent_today?(inputs[:email])
    success! # optional
  end

  def run
    # do the work
  end
end
```    