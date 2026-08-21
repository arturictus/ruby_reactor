# frozen_string_literal: true

require "open3"

# The ORCHESTRATION lane: a real worker consuming a real queue.
#
# The in-memory fakes cannot express this feature's core behavior. A caller
# blocked in the FR-005 notified wait is the thing that would have to call
# `drain_async_jobs`, so under a fake queue the awaited job never runs and every
# such example times out instead of passing. Constitution Principle III forbids
# mocked queue state on async orchestration paths for the same reason.
#
# Two backends, both real:
#
#   :active_job — the `:async` adapter, a genuine thread-pool queue runner
#                 (NOT the `:test` fake).
#   :sidekiq    — a live `sidekiq` process against the test Redis, booted once
#                 per example group. If it cannot start, examples are skipped
#                 with a reason rather than silently degrading to a fake.
module RealAsyncBackend
  BOOT_TIMEOUT = 25
  WORKER_WAIT_TIMEOUT = 20

  class << self
    def start_sidekiq!
      return @sidekiq if @sidekiq&.fetch(:pid) && process_alive?(@sidekiq[:pid])

      pid = spawn(
        { "RUBY_REACTOR_TEST_REDIS_URL" => REDIS_TEST_URL },
        "bundle", "exec", "sidekiq",
        "-r", File.expand_path("sidekiq_boot.rb", __dir__),
        "-q", "default", "-c", "2",
        out: "log/sidekiq-live.out", err: "log/sidekiq-live.err"
      )
      @sidekiq = { pid: pid }
      wait_until_consuming(pid) ? @sidekiq : nil
    rescue Errno::ENOENT, StandardError
      nil
    end

    def stop_sidekiq!
      return unless @sidekiq

      Process.kill("TERM", @sidekiq[:pid])
      Process.waitpid(@sidekiq[:pid])
    rescue Errno::ESRCH, Errno::ECHILD
      nil
    ensure
      @sidekiq = nil
    end

    # "Consuming" means the process registered itself in Sidekiq's process set —
    # a stronger signal than "the pid exists", which a crashing boot also gives.
    def wait_until_consuming(pid)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + BOOT_TIMEOUT
      redis = Redis.new(url: REDIS_TEST_URL)

      while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
        return false unless process_alive?(pid)
        return true if redis.scard("processes").to_i.positive?

        sleep 0.25
      end
      false
    ensure
      redis&.close
    end

    def process_alive?(pid)
      Process.kill(0, pid)
      true
    rescue Errno::ESRCH
      false
    end
  end
end

RSpec.shared_context "a real async worker" do |backend|
  let(:real_async_backend) { backend }

  before(:context) do
    if backend == :sidekiq
      FileUtils.mkdir_p("log")
      @live_sidekiq = RealAsyncBackend.start_sidekiq!
    end
  end

  after(:context) do
    RealAsyncBackend.stop_sidekiq! if backend == :sidekiq
  end

  around do |example|
    original_adapter = ActiveJob::Base.queue_adapter
    original_timeout = RubyReactor.configuration.async_wait_timeout
    # Short enough that a genuinely broken path fails fast, long enough to
    # absorb real worker pickup latency.
    RubyReactor.configuration.async_wait_timeout = 10
    ActiveJob::Base.queue_adapter = :async if backend == :active_job
    example.run
  ensure
    ActiveJob::Base.queue_adapter = original_adapter
    RubyReactor.configuration.async_wait_timeout = original_timeout
    Sidekiq::Testing.fake!
  end

  before do
    skip "live sidekiq worker unavailable" if backend == :sidekiq && @live_sidekiq.nil?

    # Real dispatch, not a fake queue: the client must actually push to the
    # test Redis the live worker is consuming.
    Sidekiq::Testing.disable!
    allow(RubyReactor.configuration).to receive(:async_router).and_return(AsyncBackends::BACKENDS.fetch(backend))
  end
end

module RealAsyncBackends
  def for_each_real_async_backend(&block)
    AsyncBackends::BACKENDS.each_key do |backend|
      context "with a real #{backend} worker" do
        include_context "a real async worker", backend

        instance_eval(&block)
      end
    end
  end
end

RSpec.configure do |config|
  config.extend RealAsyncBackends
end
