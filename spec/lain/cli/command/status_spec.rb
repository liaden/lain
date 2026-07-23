# frozen_string_literal: true

# T13: /status reads Command::Env's `status` reader DIRECTLY (the live
# StatusFeed instance ChatLaunch threads through Wiring), never
# `.lain/state.json` -- so this spec never touches a file, which is also
# the AC's --no-journal proof: a StatusFeed with nothing published still
# answers #state honestly (zeros/empty), and this command renders that
# without erroring.
RSpec.describe Lain::CLI::Command::Status do
  around do |example|
    Dir.mktmpdir do |dir|
      @dir = dir
      example.run
    end
  end

  def feed_path = File.join(@dir, "state.json")

  def env_with(status:) = build_command_env(status:)

  def spawn_event(id) = Lain::Event.new(kind: :spawn, payload_digest: "blake3:spawn-#{id}", from: "parent", to: nil)

  def question_event(id)
    Lain::Event.new(kind: :message, payload_digest: "blake3:q-#{id}", from: "orchestrator",
                    to: "human")
  end

  def turn_usage(cache_read: 0)
    Lain::Telemetry::TurnUsage.new(
      digest: "blake3:turn", model: "claude-x", stop_reason: :end_turn,
      usage: { "input_tokens" => 10, "output_tokens" => 5,
               "cache_read_input_tokens" => cache_read, "cache_creation_input_tokens" => 0 }
    )
  end

  let(:now) { Time.utc(2026, 7, 23, 12, 0, 0) }
  let(:clock) { -> { now } }
  let(:command) { described_class.new(clock:) }

  it "renders an honest zero/empty state -- --no-journal, where state.json never exists" do
    feed = Lain::StatusFeed.new(path: feed_path, clock:)

    text = command.call("", env_with(status: feed))

    expect(text).to include("fleet 0", "inbox 0")
  end

  it "renders warm while the published deadline has not passed" do
    feed = Lain::StatusFeed.new(path: feed_path, clock:)
    feed << turn_usage(cache_read: 10)

    expect(command.call("", env_with(status: feed))).to include("warm")
  end

  it "renders cold once the deadline is behind the clock" do
    ticking = now
    feed = Lain::StatusFeed.new(path: feed_path, clock: -> { ticking })
    feed << turn_usage(cache_read: 10)
    ticking += Lain::StatusFeed::DEFAULT_CACHE_PROFILE[:ttl] + 1

    cold_command = described_class.new(clock: -> { ticking })
    expect(cold_command.call("", env_with(status: feed))).to include("cold")
  end

  it "renders fleet size and inbox count from the live feed's own derivation" do
    feed = Lain::StatusFeed.new(path: feed_path, clock:)
    feed << spawn_event("a")
    feed << spawn_event("b")
    feed << question_event("1")

    text = command.call("", env_with(status: feed))

    expect(text).to include("fleet 2", "inbox 1")
  end

  it "answers a one-line usage and returns rendered text without printing" do
    feed = Lain::StatusFeed.new(path: feed_path, clock:)

    text = nil
    expect { text = command.call("", env_with(status: feed)) }.not_to output.to_stdout
    expect(text).to be_a(String)
    expect(command.usage).to start_with("/status")
  end
end
