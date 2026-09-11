# Future improvements for review

## Guard

I want to add another hook feature to the step: `guard`
A guard concept is to execute after validations and before run.
example:

```
class SendEmail 
    include RubyReactor::Step
    input :email, string, format?: /\A[^@\s]+@[^@\s]+\z/
    def self.guard(args, context)
        fail!("Prevent spamming") if  EmailService.sent_today?(args[:email])
        success! # optional
    end
    def self.run(args, context)
        # do the 
    end
end
```    