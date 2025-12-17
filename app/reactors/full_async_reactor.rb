class FullAsyncReactor < RubyReactor::Reactor
  async true

  input :param

  step :background_task_1 do
    argument :param, input(:param)
    run do |args|
      # logger is available in instance context
      puts "FullAsyncReactor: Step 1 running in background for param #{args[:param]}"
      sleep 1
      Success("Step 1 done")
    end
  end

  step :background_task_2 do
    argument :prev, result(:background_task_1)
    run do |args|
      puts "FullAsyncReactor: Step 2 running in background"
      Success("Step 2 done after #{args[:prev]}")
    end
  end

  returns :background_task_2
end
