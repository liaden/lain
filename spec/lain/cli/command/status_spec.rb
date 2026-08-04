# frozen_string_literal: true

require "pastel"

# T13: /status reads Command::Env's `status` reader DIRECTLY (the live
# StatusFeed instance ChatLaunch threads through Wiring), never
# `.lain/state.json` -- so this spec never touches a file, which is also
# the AC's --no-journal proof: a StatusFeed with nothing published still
# answers #state honestly (zeros/empty), and this command renders that
# without erroring.
#
# T9: it answers a {Lain::Renderable} now, not a String -- the WORDS are
# unchanged (asserted through #text), and the warm/cold marker names a token
# instead of being swallowed by the one colour render_response used to paint
# every command's answer.
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

    rendered = command.call("", env_with(status: feed))

    expect(rendered.text).to include("fleet 0", "inbox 0")
  end

  it "renders warm while the published deadline has not passed" do
    feed = Lain::StatusFeed.new(path: feed_path, clock:)
    feed << turn_usage(cache_read: 10)

    expect(command.call("", env_with(status: feed)).text).to include("warm")
  end

  it "renders cold once the deadline is behind the clock" do
    ticking = now
    feed = Lain::StatusFeed.new(path: feed_path, clock: -> { ticking })
    feed << turn_usage(cache_read: 10)
    ticking += Lain::StatusFeed::DEFAULT_CACHE_PROFILE[:ttl] + 1

    cold_command = described_class.new(clock: -> { ticking })
    expect(cold_command.call("", env_with(status: feed)).text).to include("cold")
  end

  it "renders fleet size and inbox count from the live feed's own derivation" do
    feed = Lain::StatusFeed.new(path: feed_path, clock:)
    feed << spawn_event("a")
    feed << spawn_event("b")
    feed << question_event("1")

    rendered = command.call("", env_with(status: feed))

    expect(rendered.text).to include("fleet 2", "inbox 1")
  end

  it "answers a one-line usage and returns a renderable without printing" do
    feed = Lain::StatusFeed.new(path: feed_path, clock:)

    rendered = nil
    expect { rendered = command.call("", env_with(status: feed)) }.not_to output.to_stdout
    expect(rendered).to be_a(Lain::Renderable)
    expect(command.usage).to start_with("/status")
  end

  describe "the renderable it answers" do
    # A hand-rolled stand-in rather than a real StatusFeed: this asserts the
    # command reads only the three keys it NAMES, so T7 widening the published
    # state with new keys cannot break it.
    def feed_publishing(state) = Struct.new(:state).new(state)

    def wide_state(cache_deadline:)
      { "cache_deadline" => cache_deadline, "fleet" => %w[a b], "inbox_count" => 3,
        "elapsed" => 42, "idle" => 7, "window_used" => 0.5 }
    end

    it "names the warm token on the cache segment, and nothing else" do
      feed = feed_publishing(wide_state(cache_deadline: (now + 60).iso8601))

      rendered = command.call("", env_with(status: feed))

      expect(rendered.select { |segment| segment.token == :warm }.map(&:text))
        .to eq(["#{described_class::WARM} warm"])
    end

    it "names the cold token once the deadline has passed" do
      feed = feed_publishing(wide_state(cache_deadline: (now - 60).iso8601))

      rendered = command.call("", env_with(status: feed))

      expect(rendered.map(&:token)).to include(:cold)
      expect(rendered.map(&:token)).not_to include(:warm)
    end

    it "keeps rendering against a state that grew keys it never named" do
      feed = feed_publishing(wide_state(cache_deadline: nil))

      expect(command.call("", env_with(status: feed)).text).to include("fleet 2", "inbox 3")
    end

    it "renders more than one token -- the words are never one flat colour" do
      feed = feed_publishing(wide_state(cache_deadline: nil))

      expect(command.call("", env_with(status: feed)).map(&:token).uniq.size).to be > 1
    end

    it "says the same words a String return said" do
      feed = feed_publishing(wide_state(cache_deadline: (now + 60).iso8601))

      expect(command.call("", env_with(status: feed)).text)
        .to eq("status:\n  cache #{described_class::WARM} warm\n  fleet 2\n  inbox 3")
    end

    # Naming a token is not the same as the theme registering one: an
    # unregistered token raises {Theme::UnknownToken} at PAINT time, which no
    # assertion on #text or #token can see. These two paint for real, through
    # the shipped vocabulary, and the cold one matters most -- cold with no
    # deadline is what a fresh session renders, so an unregistered :cold would
    # blow up the FIRST /status on a colour terminal with the suite still green.
    describe "painted through the shipped theme" do
      let(:colored) { Pastel.new(enabled: true) }
      let(:theme) { Lain::Frontend::Theme.new(pastel: colored, detect: -> { 256 }) }

      it "paints the default cold state -- a fresh session's very first /status" do
        feed = feed_publishing(wide_state(cache_deadline: nil))

        painted = command.call("", env_with(status: feed)).paint(theme)

        expect(painted).to include(colored.dim("#{described_class::COLD} cold (no cache activity yet)"))
      end

      it "paints the warm state" do
        feed = feed_publishing(wide_state(cache_deadline: (now + 60).iso8601))

        painted = command.call("", env_with(status: feed)).paint(theme)

        expect(painted).to include(colored.green("#{described_class::WARM} warm"))
      end
    end
  end
end
