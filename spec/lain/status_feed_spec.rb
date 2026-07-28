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

  # The two records Approval::Queue writes around one gated call: the park
  # (T4's Telemetry::ApprovalPending) and the decision (the Pending itself,
  # whose #to_journal is the id-less "approval_decision" record).
  def approval_park(tool: "bash", tool_use_id: "tu_1")
    Lain::Telemetry::ApprovalPending.new(requester: "agent", tool:, tool_use_id:)
  end

  def approval_decision(tool: "bash", tool_use_id: "tu_1", verdict: true)
    effect = Lain::Effect::ToolCall.new(tool_use_id:, name: tool, input: {})
    pending = Lain::Approval::Queue::Pending.new(effect:, requester: "agent", clock: -> { 0.0 })
    pending.decide(verdict, surface: "tty")
    pending
  end

  # A RunClock whose clock does not move, so an example pinning the
  # publish-only-when-changed guard (or comparing #state against the file it
  # just wrote) never races a real monotonic second boundary through the
  # published durations.
  def frozen_run_clock(at: 1000.0) = Lain::RunClock.new(clock: -> { at })

  def compaction_record
    Lain::Telemetry::Compaction.new(trigger: "token_threshold", cache_state: :cold, tokens_before: 100,
                                    tokens_after: 10, cost_saved: nil, cost_spent: nil, model: nil)
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

  # T7: the one state a human is actually asked to ACT on. The park record
  # (T4) and the decision record are written by Approval::Queue around the
  # same gated call and both ride the tee this sink sits in -- but the
  # decision carries NO tool_use_id, so the pair is counted, never keyed.
  describe "approvals_pending" do
    it "reports one pending approval once a tool call parks awaiting a verdict" do
      feed = described_class.new(path:)

      feed << approval_park(tool_use_id: "tu_1")

      expect(published["approvals_pending"]).to eq(1)
    end

    it "reports no pending approvals once the parked call is decided" do
      feed = described_class.new(path:)
      feed << approval_park(tool_use_id: "tu_1")

      feed << approval_decision(tool_use_id: "tu_1")

      expect(published["approvals_pending"]).to eq(0)
    end

    it "counts each concurrently parked call, since two gated fibers park independently" do
      feed = described_class.new(path:)

      feed << approval_park(tool_use_id: "tu_1")
      feed << approval_park(tool_use_id: "tu_2")

      expect(published["approvals_pending"]).to eq(2)
    end

    # The queue's `degrade` path writes a journal_error INSTEAD of the park
    # when the announcement write raises, and a cancelled requester can orphan
    # a park outright -- so a decision with no counted park is reachable, and
    # a negative count would be a nonsense reading on a status bar.
    it "floors at zero when a decision arrives with no counted park" do
      feed = described_class.new(path:)

      feed << approval_decision(tool_use_id: "tu_never_announced")

      expect(published["approvals_pending"]).to eq(0)
    end

    # Approval::Queue#degrade's stand-in record, verbatim. The park or the
    # decision HAPPENED; only its evidence failed to serialize, and the record
    # names which class it stood in for. Counting it is what keeps a lost
    # DECISION from leaving the published count high for the life of the run --
    # the one half of the broken pair that never heals on its own.
    def degraded(entry_class)
      { "type" => "journal_error", "error" => "IOError: closed stream", "entry_class" => entry_class.name }
    end

    it "counts a park whose announcement could not be journaled" do
      feed = described_class.new(path:)

      feed << degraded(Lain::Telemetry::ApprovalPending)

      expect(published["approvals_pending"]).to eq(1)
    end

    it "clears a park whose decision could not be journaled, which would otherwise never heal" do
      feed = described_class.new(path:)
      feed << approval_park

      feed << degraded(Lain::Approval::Queue::Pending)

      expect(published["approvals_pending"]).to eq(0)
    end

    it "ignores a journal_error raised over anything else" do
      feed = described_class.new(path:)
      feed << approval_park

      feed << degraded(Lain::Telemetry::TurnUsage)

      expect(published["approvals_pending"]).to eq(1)
    end

    # Async::Stop descends from Exception, NOT StandardError, so a stop
    # delivered inside the announcement write escapes record_evidence outright:
    # neither record is written and nothing is orphaned. Pinned because the
    # class doc makes that claim, and it is the reason the degrade path -- not
    # cancellation -- is the one that actually breaks the pair.
    it "is the degrade path, not cancellation, that can break the pair" do
      expect(Async::Stop.ancestors).not_to include(StandardError)
    end
  end

  # T7/T5: the run's own measures, published as PLAIN DURATIONS beside the one
  # absolute deadline (cache_deadline) -- a renderer ticks the deadline
  # locally, but elapsed/idle/since_compaction are monotonic readings, never
  # wall-clock instants.
  describe "the run's own measures" do
    it "reports the elapsed and idle seconds, and no compaction age when nothing has compacted" do
      now = 0.0
      run_clock = Lain::RunClock.new(clock: -> { now })
      feed = described_class.new(path:, run_clock:)
      now = 60.0
      run_clock.record_input

      now = 90.0
      feed << spawn_event("a")

      expect(published.values_at("elapsed", "idle", "since_compaction")).to eq([90, 30, nil])
    end

    # RunClock's own `#<<` moves only on a Telemetry::Compaction, and this sink
    # is where the fan-out reaches it: the feed publishes the clock's readings,
    # so the feed is what feeds it.
    it "reports the compaction age once a compaction record reaches the feed" do
      now = 0.0
      run_clock = Lain::RunClock.new(clock: -> { now })
      feed = described_class.new(path:, run_clock:)

      feed << compaction_record
      now = 45.0
      feed << spawn_event("a")

      expect(published["since_compaction"]).to eq(45)
    end

    # The compaction's AGE is a measure, and the publish guard compares only
    # #observed -- so without the compaction COUNT in there, the record would
    # move nothing compared, earn no write, and the file would go on saying
    # "never compacted".
    it "publishes the compaction on the record itself, not on the next unrelated event" do
      feed = described_class.new(path:)
      feed << spawn_event("a")

      feed << compaction_record

      expect(published["compactions"]).to eq(1)
      expect(published["since_compaction"]).to eq(0)
    end

    it "counts a second compaction, so a repeat is a change and not a no-op" do
      feed = described_class.new(path:)

      feed << compaction_record
      feed << compaction_record

      expect(published["compactions"]).to eq(2)
    end
  end

  # T7/T6: how full the live model's window the last turn left it, derived
  # from the SAME TurnUsage record the cache deadline slides on -- the record
  # names both the tokens and the model, so no live Agent is consulted.
  describe "occupancy" do
    def sized_turn_usage(input_tokens:, model: "claude-opus-4-8")
      Lain::Telemetry::TurnUsage.new(
        digest: "blake3:turn", model:, stop_reason: :end_turn,
        usage: { "input_tokens" => input_tokens, "output_tokens" => 5,
                 "cache_read_input_tokens" => 0, "cache_creation_input_tokens" => 0 }
      )
    end

    it "reports 0.5 for a turn filling half the model's context window" do
      feed = described_class.new(path:)

      feed << sized_turn_usage(input_tokens: 500_000)

      expect(published["occupancy"]).to eq(0.5)
    end

    it "counts every token billed on the way in, cached or not -- Usage#total_input_tokens" do
      feed = described_class.new(path:)

      feed << Lain::Telemetry::TurnUsage.new(
        digest: "blake3:turn", model: "claude-opus-4-8", stop_reason: :end_turn,
        usage: { "input_tokens" => 100_000, "output_tokens" => 5,
                 "cache_read_input_tokens" => 300_000, "cache_creation_input_tokens" => 100_000 }
      )

      expect(published["occupancy"]).to eq(0.5)
    end

    it "is nil before any turn -- absence, not an empty context" do
      feed = described_class.new(path:)

      feed << spawn_event("a")

      expect(published["occupancy"]).to be_nil
    end

    it "resolves the denominator through an injected ContextWindow book, not a hardcoded table" do
      feed = described_class.new(path:, context_window: Lain::ContextWindow.new(windows: { "tiny" => 1000 }))

      feed << sized_turn_usage(input_tokens: 250, model: "tiny-local")

      expect(published["occupancy"]).to eq(0.25)
    end

    # A status line must never cost a turn: this sink rides the same JournalTee
    # the durable record does, and JournalTee re-raises a sink's failure.
    # ContextWindow is deliberately LOUD about a blank model, so absence is the
    # only reading left here.
    it "reports absence, never a raise, when the record names no model at all" do
      feed = described_class.new(path:)

      expect { feed << sized_turn_usage(input_tokens: 10, model: nil) }.not_to raise_error
      expect(published["occupancy"]).to be_nil
    end

    # The rescue above is NOT what guards an unknown model: ContextWindow.default
    # answers one with its 8,192-token conservative fallback rather than raising,
    # which is every Ollama id and most Bedrock ids. So a ratio above 1.0 is a
    # NORMAL published value, and the renderer is what clamps it (see up_spec).
    it "publishes a ratio above 1.0 for a model measured against the conservative fallback" do
      feed = described_class.new(path:)

      feed << sized_turn_usage(input_tokens: 20_000, model: "qwen3:4b")

      expect(published["occupancy"]).to eq(20_000.fdiv(Lain::ContextWindow::CONSERVATIVE_FALLBACK))
      expect(published["occupancy"]).to be > 1.0
    end

    # TurnUsage's guard checks digest and stop_reason but not usage, and
    # Canonical.normalize(nil) is nil -- so the record below is constructible,
    # and indexing it inside a JournalTee sink would unwind into the agent loop
    # and cost the turn. (Pre-dates this field: slide_cache_deadline indexed it
    # too. Found by a review probe.)
    it "derives nothing, and raises nothing, from a record whose usage is nil" do
      feed = described_class.new(path:)
      feed << sized_turn_usage(input_tokens: 500_000)

      blank = Lain::Telemetry::TurnUsage.new(digest: "blake3:t2", model: "claude-opus-4-8",
                                             stop_reason: :end_turn, usage: nil)

      expect { feed << blank }.not_to raise_error
      expect(published["occupancy"]).to eq(0.5)
    end

    # INPUT_TOKEN_FIELDS restates Usage#total_input_tokens against the JOURNALED
    # hash. They agree today and nothing structural holds them together, so this
    # is the pin: both the field NAMES (fetch, not [], so a rename fails loudly)
    # and the sum.
    it "sums exactly the fields Usage#total_input_tokens does, so the two cannot drift apart" do
      usage = Lain::Usage.new(input_tokens: 3, output_tokens: 7,
                              cache_creation_input_tokens: 11, cache_read_input_tokens: 13)
      journaled = usage.to_h.transform_keys(&:to_s)

      summed = described_class::INPUT_TOKEN_FIELDS.sum { |field| journaled.fetch(field) }

      expect(summed).to eq(usage.total_input_tokens)
    end
  end

  # The examples above hand this sink its records directly, which is the unit
  # question: what does it derive? This one asks the wiring question the ACs
  # are actually written about -- does a real parked approval REACH it? -- by
  # standing up the production path (Chronicle -> wrap_tee -> Switchboard ->
  # Approval::Queue) and parking a real gated call on it. That path runs
  # through four objects this class never names, and a break in any of them
  # would leave every example above green and the HUD blank.
  describe "riding the run's real fan-out" do
    it "reports the park while a gated call waits, and clears it on the verdict" do
      feed = described_class.new(path:)
      queue = queue_over_a_real_chronicle(feed)
      effect = Lain::Effect::ToolCall.new(tool_use_id: "tu_1", name: "bash", input: { "command" => "ls" })

      Sync do |task|
        gated = task.async { queue.call(effect, nil) }
        task.sleep(0.05)
        expect(published["approvals_pending"]).to eq(1)

        queue.each.first.approve(surface: "tty")
        gated.wait
      end

      expect(published["approvals_pending"]).to eq(0)
    end

    it "publishes the occupancy and compaction age of records sent down the chronicle's telemetry leg" do
      feed = described_class.new(path:)
      telemetry = chronicle_teed_to(feed).telemetry_kwargs.fetch(:journal)

      telemetry << Lain::Telemetry::TurnUsage.new(
        digest: "blake3:t", model: "claude-opus-4-8", stop_reason: :end_turn,
        usage: { "input_tokens" => 500_000, "output_tokens" => 1,
                 "cache_read_input_tokens" => 0, "cache_creation_input_tokens" => 0 }
      )
      telemetry << Lain::Telemetry::Compaction.new(trigger: "token_threshold", cache_state: :cold,
                                                   tokens_before: 10, tokens_after: 1,
                                                   cost_saved: nil, cost_spent: nil)

      expect(published["occupancy"]).to eq(0.5)
      expect(published["since_compaction"]).to eq(0)
    end

    # Exactly ChatLaunch#open_chronicle's order: the chronicle opens, the feed
    # joins its tee, and only then does anything that journals get built.
    def chronicle_teed_to(feed)
      record = File.join(@dir, "session.ndjson")
      chronicle = Lain::CLI::Chronicle.new(journal: Lain::Journal.new(io: File.open(record, "ab")),
                                           journal_path: record)
      chronicle.wrap_tee(feed)
      chronicle.wrap_memory(Lain::Memory::Recorder.new)
      chronicle
    end

    def queue_over_a_real_chronicle(feed)
      Lain::CLI::Switchboard.for(chronicle: chronicle_teed_to(feed), options: {},
                                 model: "claude-opus-4-8").approvals
    end
  end

  # T7's two NON-GOALS, pinned so a later change cannot make either worse
  # without a spec saying so: the live inbox over-count (the :turn that would
  # retire a question never reaches this sink -- see the class doc) and the
  # fleet undercount (identical spawns share one content address, by design).
  describe "the two known defects, unchanged by the wider state" do
    it "reports inbox_count and fleet exactly as it did before the new fields" do
      feed = described_class.new(path:)

      feed << message_event("q1", to: "human")
      feed << spawn_event("same")
      feed << spawn_event("same")

      expect(published["inbox_count"]).to eq(1)
      expect(published["fleet"]).to eq([spawn_event("same").digest])
    end

    it "still renders cache, fleet and inbox through /status, which names only the keys it knows" do
      feed = described_class.new(path:)
      feed << message_event("q1", to: "human")
      feed << spawn_event("a")
      feed << approval_park

      env = Struct.new(:status).new(feed)

      # `.text` because /status answers with a Renderable now, not a String. The
      # words are what this example is about -- that a reader naming only three
      # keys is untouched by the five this card added.
      expect(Lain::CLI::Command::Status.new.call(nil, env).text).to eq(
        "status:\n  cache ○ cold (no cache activity yet)\n  fleet 1\n  inbox 1"
      )
    end
  end

  describe "state (public reader, T13)" do
    it "answers the SAME derivation #<< publishes, without touching the file -- Command::Env's live seam" do
      feed = described_class.new(path:, run_clock: frozen_run_clock)

      feed << spawn_event("a")
      feed << message_event("q1", to: "human")

      expect(feed.state).to eq(published)
    end

    # #state reads a running clock, so it is a snapshot, not a change token --
    # a renderer redrawing on `state != @last` would redraw once a second
    # forever. #observed is the token, and it is what the publish guard
    # compares: the same failure Occupancy::None documents one layer down,
    # made with a clock instead of an absence.
    it "moves on its own between two calls with no event between them" do
      now = 0.0
      feed = described_class.new(path:, run_clock: Lain::RunClock.new(clock: -> { now }))
      feed << spawn_event("a")
      before = feed.state

      now = 1.0

      expect(feed.state).not_to eq(before)
    end

    it "answers an UNCHANGED #observed across that same second, so a renderer has something to compare" do
      now = 0.0
      feed = described_class.new(path:, run_clock: Lain::RunClock.new(clock: -> { now }))
      feed << spawn_event("a")
      before = feed.observed

      now = 1.0

      expect(feed.observed).to eq(before)
      expect(feed.state).to include(before)
    end

    it "names every published key across the two halves, so #state stays the whole struct" do
      feed = described_class.new(path:)

      feed << turn_usage(cache_read: 1)

      expect(feed.state.keys).to match_array(published.keys)
    end
  end

  describe "publishing" do
    it "writes valid, complete JSON with every published field on every event" do
      feed = described_class.new(path:)

      feed << turn_usage(cache_read: 1)

      expect(published.keys).to contain_exactly("cache_deadline", "fleet", "inbox_count", "approvals_pending",
                                                "occupancy", "compactions", "elapsed", "idle", "since_compaction")
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

    # The guard compares #observed alone. A clock is not a change: comparing it
    # would earn a write+rename every second an event happened to land in, on a
    # run where nothing a reader cares about moved at all.
    it "still skips the write when only the clock moved between two identical events" do
      now = 0.0
      feed = described_class.new(path:, run_clock: Lain::RunClock.new(clock: -> { now }))
      feed << spawn_event("a")
      allow(File).to receive(:write).and_call_original

      now = 90.0
      feed << spawn_event("a")

      expect(File).not_to have_received(:write)
    end

    # ... but a publish the observed state DID earn carries measures read at
    # that instant, not the stale ones from the last write.
    it "stamps the durations at write time, so a publish is never a replay of an older clock" do
      now = 0.0
      feed = described_class.new(path:, run_clock: Lain::RunClock.new(clock: -> { now }))
      feed << spawn_event("a")

      now = 90.0
      feed << spawn_event("b")

      expect(published["elapsed"]).to eq(90)
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
