# frozen_string_literal: true

# StatusFeed is one small state struct -- cache warmth, fleet, inbox count --
# published to `.lain/state.json` for the tmux status-right / TTY prompt /
# nvim lualine renderers ROADMAP describes (planning/interface-integration.md
# § "One state feed, three renderers"). It rides {Lain::CLI::JournalTee} as
# just another `#<<` sink (see spec/lain/cli/journal_tee_spec.rb for the
# fan-out mechanics); this spec covers what it derives and how it publishes.
RSpec.describe Lain::StatusFeed do
  def turn_usage(digest: "blake3:turn", cache_read: 0, cache_creation: 0)
    Lain::Telemetry::TurnUsage.new(
      digest:, model: "claude-x", stop_reason: :end_turn,
      usage: { "input_tokens" => 10, "output_tokens" => 5,
               "cache_read_input_tokens" => cache_read, "cache_creation_input_tokens" => cache_creation }
    )
  end

  def spawn_event(id)
    Lain::Event.new(kind: :spawn, payload_digest: "blake3:spawn-#{id}", from: "parent", to: nil)
  end

  def message_event(id, to: "human", from: "orchestrator")
    Lain::Event.new(kind: :message, payload_digest: "blake3:msg-#{id}", from:, to:)
  end

  def turn_event(causal_parents:)
    base = Lain::Event.turn(role: "assistant", content: [{ "type" => "text", "text" => "ok" }])
    Lain::Event.new(kind: :turn, payload_digest: base.payload_digest, body: base.body, causal_parents:)
  end

  around do |example|
    Dir.mktmpdir("status-feed-spec") do |dir|
      @dir = dir
      example.run
    end
  end

  def path = File.join(@dir, "state.json")

  def published = JSON.parse(File.read(path))

  describe "cache_deadline" do
    it "is nil before any cache activity is observed" do
      feed = described_class.new(path:)

      feed << turn_usage(cache_read: 0, cache_creation: 0)

      expect(published["cache_deadline"]).to be_nil
    end

    it "pushes the absolute TTL deadline, not a countdown, when usage shows a cache read" do
      now = Time.utc(2026, 7, 17, 12, 0, 0)
      feed = described_class.new(path:, clock: -> { now })

      feed << turn_usage(cache_read: 128)

      expect(published["cache_deadline"]).to eq((now + described_class::DEFAULT_CACHE_PROFILE[:ttl]).iso8601)
    end

    it "also slides on a cache WRITE (cache_creation_input_tokens), not only a read" do
      now = Time.utc(2026, 7, 17, 12, 0, 0)
      feed = described_class.new(path:, clock: -> { now })

      feed << turn_usage(cache_creation: 4096)

      expect(published["cache_deadline"]).to eq((now + described_class::DEFAULT_CACHE_PROFILE[:ttl]).iso8601)
    end

    it "slides forward on a later warm turn rather than staying pinned to the first one" do
      t1 = Time.utc(2026, 7, 17, 12, 0, 0)
      t2 = t1 + 60
      now = t1
      feed = described_class.new(path:, clock: -> { now })
      feed << turn_usage(cache_read: 10)

      now = t2
      feed << turn_usage(cache_read: 10)

      expect(published["cache_deadline"]).to eq((t2 + described_class::DEFAULT_CACHE_PROFILE[:ttl]).iso8601)
    end

    # CAC-2: the scheduler must read a provider's actual cache mechanics, not
    # a fixed guess -- Anthropic's TTL differs from a future OpenAI-compatible
    # arm's, so pinning the ttl at 60 (not the 300s default) is what proves
    # the injected profile is actually consulted rather than the constant.
    it "derives the deadline from an injected cache_profile's ttl, not the hardcoded default" do
      now = Time.utc(2026, 7, 17, 12, 0, 0)
      feed = described_class.new(path:, clock: -> { now }, cache_profile: { ttl: 60 })

      feed << turn_usage(cache_read: 10)

      expect(published["cache_deadline"]).to eq((now + 60).iso8601)
    end

    it "leaves the deadline exactly where it was on a cache-cold turn -- sliding, not decaying" do
      warm_at = Time.utc(2026, 7, 17, 12, 0, 0)
      feed = described_class.new(path:, clock: -> { warm_at })
      feed << turn_usage(cache_read: 10)
      warm_deadline = published["cache_deadline"]

      feed << turn_usage(cache_read: 0, cache_creation: 0) # a later cold turn

      expect(published["cache_deadline"]).to eq(warm_deadline)
    end
  end

  describe "fleet" do
    it "reflects exactly the :spawn events observed, appended in order" do
      feed = described_class.new(path:)
      first = spawn_event("a")
      second = spawn_event("b")

      feed << first
      feed << second

      expect(published["fleet"]).to eq([first.digest, second.digest])
    end

    it "does not grow on a :message or :turn event -- only :spawn names a fleet member" do
      feed = described_class.new(path:)

      feed << message_event("q")
      feed << turn_event(causal_parents: [])

      expect(published["fleet"]).to eq([])
    end

    it "never reaches into an in-process registry: an untouched StatusFeed with no events published starts empty" do
      feed = described_class.new(path:)

      feed << turn_usage # any event that is not itself a spawn

      expect(published["fleet"]).to eq([])
    end

    # FIX 3 (review round): a review probe redelivered the identical :spawn
    # event twice (a plausible journal replay / resume-after-crash salvage)
    # and asked whether the fleet grows a phantom duplicate for one real
    # spawn. It must not -- fleet is keyed by digest, so a redelivery is a
    # no-op update, not a second entry. Two SEPARATELY CONSTRUCTED events with
    # the same content address the same real spawn, which is the point of
    # content addressing: dedup is by digest, never by Ruby object identity.
    it "dedups a redelivered :spawn by digest -- a journal replay never grows a phantom fleet entry" do
      feed = described_class.new(path:)

      feed << spawn_event("a")
      feed << spawn_event("a") # a fresh Event object, same content address

      expect(published["fleet"]).to eq([spawn_event("a").digest])
    end
  end

  describe "inbox_count" do
    it "counts :message events addressed to the human inbox that no committed turn has consumed" do
      feed = described_class.new(path:)
      question = message_event("q1", to: "human")

      feed << question

      expect(published["inbox_count"]).to eq(1)
    end

    it "ignores messages addressed elsewhere" do
      feed = described_class.new(path:)

      feed << message_event("w1", to: "worker")

      expect(published["inbox_count"]).to eq(0)
    end

    it "drops a message from the count once a committed turn names it a causal parent (Projection#pending's rule)" do
      feed = described_class.new(path:)
      question = message_event("q1", to: "human")
      feed << question

      feed << turn_event(causal_parents: [question.digest])

      expect(published["inbox_count"]).to eq(0)
    end

    # FIX 2 (review round): the shipped example above used a synthetic :turn
    # built straight from the question's digest. The REAL Tools::AskHuman#reply
    # shape is an A :message (from: "human", causal_parents: [Q.digest]) --
    # and Event::Projection#pending's own doc is explicit that a :message's
    # causal_parents is lineage, never consumption: "Consumption counts :turn
    # edges ONLY". So the human answering does NOT retire their own question;
    # only a LATER :turn (an assistant commit whose folded mailbox names Q) does.
    #
    # T13 investigated retiring on this A instead (the live over-count this
    # card's escalation trigger names -- see the class doc's T13 note for why
    # the underlying :turn Event genuinely never reaches this sink in
    # production) and reverted it: {Frontend::Neovim::InboxView}'s parity
    # spec pins this class and the nvim inbox view to agreeing at every step
    # on exactly this rule, and a correct fix needs a live Store this class
    # cannot see at its (pre-Agent) construction point -- escalated in the
    # T13 hand-back rather than fixed by breaking that parity.
    it "an AskHuman-shaped reply does not retire the question by itself; only a later :turn's causal_parents does" do
      feed = described_class.new(path:)
      asker = "orchestrator"
      question = Lain::Event.new(kind: :message, payload_digest: "blake3:q", from: asker, to: "human")
      feed << question
      expect(published["inbox_count"]).to eq(1)

      # Exactly Tools::AskHuman#reply's shape: the answer is FROM "human", TO
      # the asker, citing Q's digest as its causal parent -- and it is a
      # :message, not a :turn.
      answer = Lain::Event.new(kind: :message, payload_digest: "blake3:a", from: "human", to: asker,
                               causal_parents: [question.digest])
      feed << answer
      expect(published["inbox_count"]).to eq(1) # still pending: the human already answered, but nothing consumed it

      feed << turn_event(causal_parents: [question.digest]) # the assistant commit that actually folds Q in
      expect(published["inbox_count"]).to eq(0)
    end
  end

  describe "state (public reader, T13)" do
    it "answers the SAME derivation #<< publishes, without touching the file -- Command::Env's live seam" do
      feed = described_class.new(path:)

      feed << spawn_event("a")
      feed << message_event("q1", to: "human")

      expect(feed.state).to eq(published)
    end
  end

  describe "publishing" do
    it "writes valid, complete JSON with all three fields on every event" do
      feed = described_class.new(path:)

      feed << turn_usage(cache_read: 1)

      expect(published.keys).to contain_exactly("cache_deadline", "fleet", "inbox_count")
    end

    it "creates the destination directory (the project's .lain/) on demand" do
      nested = File.join(@dir, ".lain", "state.json")
      feed = described_class.new(path: nested)

      feed << turn_usage

      expect(File.read(nested)).not_to be_empty
    end

    it "replaces the file atomically: a write that fails mid-flight never corrupts the last good state" do
      # Two distinct clock ticks, not two calls to the real Time.now: derived
      # state must actually differ between the two pushes (a stale
      # cache_deadline within the same wall-clock second would otherwise
      # leave state unchanged and the second push would skip publishing
      # entirely -- see "publish only when changed" -- masking the very
      # failure this example exists to force).
      t1 = Time.utc(2026, 7, 17, 12, 0, 0)
      t2 = t1 + 1
      now = t1
      feed = described_class.new(path:, clock: -> { now })
      feed << turn_usage(cache_read: 1)
      good_bytes = File.read(path)

      now = t2
      allow(File).to receive(:write).and_raise(Errno::ENOSPC)
      expect { feed << turn_usage(cache_read: 2) }.to raise_error(Errno::ENOSPC)

      expect(File.read(path)).to eq(good_bytes)
    end

    it "leaves no leftover tmp file behind after a successful publish" do
      feed = described_class.new(path:)

      feed << turn_usage

      expect(Dir.children(@dir)).to eq(["state.json"])
    end

    # FIX 3 (review round): publishing unconditionally was part of the O(n^2)
    # shape -- a duplicate delivery or an unrecognized event still paid a
    # write+rename. Derived state is now compared before writing.
    it "skips the write+rename entirely when the derived state did not change" do
      feed = described_class.new(path:)
      feed << spawn_event("a")
      allow(File).to receive(:write).and_call_original

      feed << spawn_event("a") # redelivery: fleet dedups, so nothing actually changed

      expect(File).not_to have_received(:write)
    end

    it "returns self, so it chains the same way a Journal or Channel does" do
      feed = described_class.new(path:)

      expect(feed << turn_usage).to be(feed)
    end
  end

  # FIX 3 (review round): the O(n) Event::Projection fold that used to run on
  # EVERY `<<` made a session's total cost O(n^2) -- a reviewer measured 1k
  # events at 0.245s and 8k events at 8.554s. Pinned here as a cost-SHAPE
  # invariant rather than a wall-clock budget (flaky on shared/loaded CI
  # hardware): no full-log fold construct ever runs, and per-event memory
  # tracks only OUTSTANDING state (currently-pending / currently-spawned),
  # never the total count of events ever pushed.
  describe "incremental derivation (no O(n) refold per event)" do
    it "never constructs an Event::Projection -- the whole point of the incremental rewrite" do
      feed = described_class.new(path:)
      allow(Lain::Event::Projection).to receive(:new).and_call_original

      300.times do |i|
        question = message_event("bulk-#{i}", to: "human")
        feed << question
        feed << turn_event(causal_parents: [question.digest])
      end

      expect(Lain::Event::Projection).not_to have_received(:new)
    end

    it "keeps fleet/inbox_count bounded by OUTSTANDING state, not the total volume of events ever pushed" do
      feed = described_class.new(path:)

      1000.times { feed << spawn_event("same-subagent") } # one real spawn, redelivered 1000x
      1000.times do |i|
        question = message_event("retired-#{i}", to: "human")
        feed << question
        feed << turn_event(causal_parents: [question.digest]) # immediately retired
      end
      feed << message_event("outstanding", to: "human") # the one still-pending question

      expect(published["fleet"]).to eq([spawn_event("same-subagent").digest])
      expect(published["inbox_count"]).to eq(1)
    end
  end

  # FIX 3 side effect, not itself a fix: the reviewer's torn-read probe
  # confirmed the atomic-rename mechanism holds under a tight concurrent
  # write/read loop (it did not find a defect, unlike the other probes), kept
  # here as a permanent regression guard since it is cheap insurance on the
  # exact claim the "publishing" examples above make sequentially.
  it "a concurrent reader never observes partial/torn JSON across many rapid publishes" do
    feed = described_class.new(path:)
    feed << spawn_event("seed")

    stop = false
    reader_errors = []
    reader = Thread.new do
      until stop
        bytes = File.read(path)
        begin
          JSON.parse(bytes) unless bytes.empty?
        rescue JSON::ParserError => e
          reader_errors << e.message
        end
      end
    end

    500.times { |i| feed << spawn_event("spawn-#{i}") }
    stop = true
    reader.join

    expect(reader_errors).to eq([])
  end
end
