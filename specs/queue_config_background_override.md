# `queue` setup per Reactor and Step

We want to be able to select the `queue` in which the reactor will execute.

This would enable teams to manage resources as they are used to currently do 
with sidekiq and active_job.


example:

```ruby
RubyReactor.configure do |rr|
   rr.queue_name = :default
end
class MyReactor < RubyReactor::Reactor
  queue :my_specific_queue
  background after: :first
  step :first
  step :second
  step :third
end
```

This reactor should execute in `:my_specific_queue` instead of `:default`

The complication arises when we start combining compose, asyncs and maps.

example:

```ruby
RubyReactor.configure do |rr|
   rr.queue_name = :default
end
class StripeBankDeposit < RubyReactor::Reactor
  queue :stripe
  background after: :one
  step :one
  step :two
end
class MyReactor < RubyReactor::Reactor
  queue :my_specific_queue
  background after: :first
  step :first 
  step :second do
    wait_for(:first)
  end
  compose :bank_deposit, StripeBankDeposit do
    wait_for(:first)
  end
  step :third do
    wait_for(:bank_deposit)
  end
end
```

What should we do here?

Option 1: queue dispatch is respected

- my_reactor.second.queue: :my_specific_queue
- my_reactor.bank_deposit.queue: :stripe
- my_reactor.third.queue: :my_specific_queue

That would mean splitting what before was a single background job to multiple dispatches per queue, which could compromise reliability and consistency guarantees

Option 2: Only first dispatch is respected

- my_reactor.second.queue: :my_specific_queue
- my_reactor.bank_deposit.queue: :stripe
- my_reactor.third.queue: :stripe

This would render the configuration missleading and not usefull.


This could get complicated when allowing steps and maps to configure the `queue`.

example:

```ruby
RubyReactor.configure do |rr|
   rr.queue_name = :default
end
class StripeBankDeposit < RubyReactor::Reactor
  queue :stripe
  background after: :one
  step :one
  step :two
end

class Email < RubyReactor::Step
  queue :emails
end

class AnotherStep < RubyReactor::Step
  queue :another_one
end

class MyReactor < RubyReactor::Reactor
  queue :my_specific_queue
  background after: :first
  step :first 
  step :second do
    wait_for(:first)
  end
  compose :bank_deposit, StripeBankDeposit do
    wait_for(:first)
  end
  step :third do
    wait_for(:bank_deposit)
  end

  step :another, AnotherStep do
    wait_for(:third)
  end

  async_step :email, Email do
    wait_for(:third)
  end
end

class ManyReactor < RubyReactor::Reactor
  queue :many_queue

  background after: :first
  step :first 
  step :second do
    wait_for(:first)
  end
  map :do_deposit, ManyReactor do
    wait_for(:first)
  end
  step :third do
    wait_for(:do_deposit)
  end
end
```

We would prefer Option 1, each queue declaration is respected but as always the reliability guaranties is the most important feature.

# Override background

Imagine this scenario

```ruby
class MyWorker
  include Sidekiq::Worker

  def perform(params)
    MyReactor.run(params)
  end
end
```

Or

```ruby
class KafkaConsumer
  def consume(elem)
    MyReactor.run(params)
    mark_consumed(elem)
  end
end
```

There are cases where the background declaration have to be skipped or modified.
Here is an approach that we can investigate an or evaluate

```ruby
class KafkaConsumer
  def consume(elem)
    MyReactor.brackground(false).run(params)
    mark_consumed(elem)
  end
end
```

or

```ruby
class KafkaConsumer
  def consume(elem)
    result = MyReactor.brackground(after: :confirm_order).run(params)
    if result.success?
      mark_consumed(elem)
    else
      # we will have to retry this event at least in this example
    end
  end
end
```

Because it's not the same executing the request in a controller that we need to return some kind operation registered given the http constraints than starting the execution from a background process like the sidekiq process

