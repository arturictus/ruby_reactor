# frozen_string_literal: true

require "spec_helper"
require "ruby_reactor/web/api"

# 011 FR-020, API §5: the dashboard API shows where a run waits, where each
# step ran, and the hops it took.
RSpec.describe "dashboard API queues", type: :reactor do
  include RSpecMixin

  def detail(id)
    get "/reactors/#{id}"
    JSON.parse(last_response.body)
  end

  def started(reactor_class)
    test_reactor(reactor_class, {}, process_jobs: false).tap(&:run)
  end

  it "shows the queue a waiting run waits on, and nothing once it finished" do
    subject = started(QueueFixtures::Main)
    id = subject.reactor_instance.context.context_id
    QueueProbe.next_job.perform!

    waiting = detail(id)["waiting_on"]
    expect(waiting["queue"]).to eq("stripe")
    expect(Time.iso8601(waiting["since"])).to be_within(5).of(Time.now)

    drain_async_jobs
    expect(detail(id)["waiting_on"]).to be_nil
  end

  it "names each step's queue and the hops in the trace" do
    subject = started(QueueFixtures::Main)
    id = subject.reactor_instance.context.context_id
    drain_async_jobs

    steps = detail(id)["steps"]
    runs = steps.select { |entry| entry["type"] == "run" }.to_h { |entry| [entry["step"], entry["queue"]] }
    expect(runs).to include("second" => "main", "third" => "main")
    hops = steps.select { |entry| entry["type"] == "queue_hop" }
    expect(hops.map { |hop| hop.slice("at", "from", "to", "direction") }).to eq(
      [{ "at" => "bank_deposit", "from" => "main", "to" => "stripe", "direction" => "forward" },
       { "at" => "third", "from" => "stripe", "to" => "main", "direction" => "forward" }]
    )
  end

  it "names the queue of an async_step's run and of its reference" do
    subject = started(QueueFixtures::MainSteps)
    id = subject.reactor_instance.context.context_id
    drain_async_jobs

    json = detail(id)
    email_run = json["steps"].find { |entry| entry["type"] == "run" && entry["step"] == "email" }
    expect(email_run["queue"]).to eq("emails")
    expect(json.dig("composed_contexts", "email", "record", "queue")).to eq("emails")
  end
end
