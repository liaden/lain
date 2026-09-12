# frozen_string_literal: true

# StatusFeed is one small state struct -- cache warmth, fleet, inbox count --
# published to `.lain/state.json` for the tmux status-right / TTY prompt /
# nvim lualine renderers ROADMAP describes (planning/interface-integration.md
# § "One state feed, three renderers"). It rides {Lain::CLI::JournalTee} as
# just another `#<<` sink (see spec/lain/cli/journal_tee_spec.rb for the
# fan-out mechanics); this spec covers what it derives and how it publishes.
RSpec.describe Lain::StatusFeed do
  def turn_usage(digest: "blake3:turn", cache_read: 0, cache_creation: 0, input: 10, output: 5)
    Lain::Telemetry::TurnUsage.new(
      digest:, model: "claude-x", stop_reason: :end_turn,
      usage: { "input_tokens" => input, "output_tokens" => output,
               "cache_read_input_tokens" => cache_read, "cache_creation_input_tokens" => cache_creation }
    )
  end

  # Answers `#usage` and names a model, but never says why a turn stopped --
  # because it is not a turn. It rides the same tee on the default-on
  # compaction route (Oracle::Recorded::Journaling).
  def oracle_answer(input: 9_000, output: 300)
    Lain::Telemetry::OracleAnswer.new(
      oracle_digest: "blake3:oracle", question: "summarise", answer: { "text" => "..." },
      model: "claude-x", usage: { "input_tokens" => input, "output_tokens" => output },
      wall_clock: 1.5
    )
  end

  def spawn_event(id)
    Lain::Event.new(kind: :spawn, payload_digest: "blake3:spawn-#{id}", from: "parent", to: nil)
  end

  # A one-shot's completion, shaped as Tools::Subagent::Lineage#message writes
  # one: the result, the child's final head and the terminal mark, citing the
  # :spawn among its causal parents.
  def spawn_completion(spawn)
    Lain::Event.new(kind: :message, payload_digest: "blake3:msg-completion",
                    body: { "result" => "the answer", "final" => "blake3:final",
                            "lifecycle" => Lain::StatusFeed::SpawnLifecycle::STOPPED },
                    causal_parents: [spawn.digest, "blake3:final"], from: "child", to: "parent")
  end

  # An actor's reply, shaped as Tools::Subagent::Actor#reply writes one: no
  # result key, only the mark, citing the address -- which IS the spawn digest.
  def actor_reply(spawn, lifecycle:)
    Lain::Event.new(kind: :message, payload_digest: "blake3:msg-#{lifecycle}",
                    body: { "text" => "from the child", "lifecycle" => lifecycle },
                    causal_parents: [spawn.digest, "blake3:head"], from: "child", to: "parent")
  end

  def message_event(id, to: "human", from: "orchestrator")
    Lain::Event.new(kind: :message, payload_digest: "blake3:msg-#{id}", from:, to:)
  end

  def turn_event(causal_parents:)
    base = Lain::Event.turn(role: "assistant", content: [{ "type" => "text", "text" => "ok" }])
    Lain::Event.new(kind: :turn, payload_digest: base.payload_digest, body: base.body, causal_parents:)
  end

  # The two records Approval::Queue writes around one gated call: the park
  # (the Telemetry::ApprovalPending) and the decision (the Pending itself,
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

  # The Source's own refusal record: a derivation the Messages API would have
  # rejected, carrying the consecutive streak that says whether this was one
  # awkward turn or a session that has stopped compacting.
  def derivation_refused(consecutive:)
    Lain::Compaction::Source::DerivationRefused.new(strategy: "spans", violations: "unanswered tool_use",
                                                    consecutive:)
  end

  # What a SUCCESSFUL derivation journals, on the same leg -- the record that
  # clears the streak.
  def context_derived
    Lain::Telemetry::ContextDerived.new(source_head: "blake3:src", derived_head: "blake3:drv",
                                        strategy: "spans", spans: [%w[blake3:a blake3:b]], cut: :offered,
                                        moved: 0, keep_last: 2)
  end

  def compaction_record
    Lain::Telemetry::Compaction.new(trigger: "token_threshold", cache_state: :cold, bytes_before: 100,
                                    bytes_after: 10, cost_saved: nil, cost_spent: nil, model: nil)
  end

  around do |example|
    Dir.mktmpdir("status-feed-spec") do |dir|
      @dir = dir
      example.run
    end
  end

  def text(body) = [{ "type" => "text", "text" => body }]

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

    # The scheduler must read a provider's actual cache mechanics, not
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

  # The ROUTING and what the feed publishes from it -- not the set itself. The
  # standing set, and the digest keying that makes a replay idempotent, belong
  # to {Lain::StatusFeed::Fleet} and are pinned in
  # spec/lain/status_feed/fleet_spec.rb. Every example here goes through the
  # feed's public surface on purpose: that is what makes them a check on the
  # delegation as well as on the derivation.
  describe "fleet" do
    it "reflects exactly the :spawn events observed, appended in order" do
      feed = described_class.new(path:)
      first = spawn_event("a")
      second = spawn_event("b")

      feed << first
      feed << second

      expect(published["fleet"]).to eq([first.digest, second.digest])
    end

    it "grows on neither an ordinary :message nor a :turn -- only a :spawn names a fleet member" do
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

    # A review probe redelivered the identical :spawn
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

    # The delegation on the OTHER side: until a spawn's completion could be
    # recognised, `fleet` was the one published field that was a set of
    # identities with an add path and no remove path.
    it "retires a spawn on the completion that names it, so a finished child leaves the roster" do
      feed = described_class.new(path:)
      launch = spawn_event("a")
      feed << launch

      feed << spawn_completion(launch)

      expect(published["fleet"]).to eq([])
    end

    it "keeps an actor that has only settled a turn -- settled rides every reply, not just the last" do
      feed = described_class.new(path:)
      launch = spawn_event("a")
      feed << launch

      feed << actor_reply(launch, lifecycle: Lain::StatusFeed::SpawnLifecycle::SETTLED)

      expect(published["fleet"]).to eq([launch.digest])
    end

    it "retires an actor on its farewell, which names the spawn digest it took as its address" do
      feed = described_class.new(path:)
      launch = spawn_event("a")
      feed << launch

      feed << actor_reply(launch, lifecycle: Lain::StatusFeed::SpawnLifecycle::STOPPED)

      expect(published["fleet"]).to eq([])
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

    # The shipped example above used a synthetic :turn
    # built straight from the question's digest. The REAL Tools::AskHuman#reply
    # shape is an A :message (from: "human", causal_parents: [Q.digest]) --
    # and Event::Projection#pending's own doc is explicit that a :message's
    # causal_parents is lineage, never consumption: "Consumption counts :turn
    # edges ONLY". So the human answering does NOT retire their own question;
    # only a LATER :turn (an assistant commit whose folded mailbox names Q) does.
    #
    # Retiring on this A instead was investigated once and REFUSED, and the
    # refusal still stands: {Frontend::Neovim::InboxView}'s parity spec pins
    # this class and the nvim inbox view to agreeing at every step on exactly
    # this rule, and retiring on a reply would break it. The live over-count
    # that made the question worth asking was a different defect with a
    # different fix -- the committed turn reaches this sink as a
    # {Lain::Telemetry::TurnUsage}, not as a :turn Event -- and it is fixed, in
    # the "retiring off the record the tee actually carries" group below.
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

    # Measured live 2026-08-25: the HUD said 2 while `lain://inbox` drew
    # one. The :turn Event every example above hands this feed NEVER REACHES IT
    # in a live chat -- SessionRecord::Scribe#catch_up appends committed turns
    # to the session journal, not to the tee -- so the count only ever climbed.
    # What the tee does carry for a commit is the Telemetry::TurnUsage naming
    # the head, and these examples drive that record, which is the one a live
    # chat actually delivers.
    describe "retiring off the record the tee actually carries" do
      let(:store) { Lain::Store.new }

      def stored_question(question: "which db?", from: "orchestrator")
        parent = Lain::Timeline.empty(store:).commit(role: :user, content: text("seed #{question}"))
        Lain::Event::ChainWriter.new.put(parent, kind: :message, from:, to: "human",
                                                 causal_parents: [], body: { "question" => question })
      end

      # The delivery commit's shape: a committed chain whose head turn cites
      # the questions it folded in.
      def commit_citing(*digests)
        Lain::Timeline.empty(store:)
                      .commit(role: :user, content: text("hi"))
                      .commit(role: :assistant, content: text("asking"), causal_parents: digests)
                      .head_digest
      end

      it "retires an answered question off the committed turn's usage record, not off a :turn Event" do
        feed = described_class.new(path:, store:)
        question = stored_question
        feed << question
        expect(published["inbox_count"]).to eq(1)

        feed << turn_usage(digest: commit_citing(question.digest))

        expect(published["inbox_count"]).to eq(0)
      end

      it "retires nothing for a commit that cited no question" do
        feed = described_class.new(path:, store:)
        feed << stored_question

        feed << turn_usage(digest: commit_citing)

        expect(published["inbox_count"]).to eq(1)
      end

      # ChatLaunch builds this feed before Wiring exists, so the run's Store is
      # bound later; until it is, a head names nothing this feed can resolve.
      it "counts a question that arrived before any Store was bound rather than raising on the commit" do
        feed = described_class.new(path:)
        question = stored_question
        feed << question
        head = commit_citing(question.digest)

        expect { feed << turn_usage(digest: head) }.not_to raise_error

        expect(published["inbox_count"]).to eq(1)
      end

      it "retires once the run's Store is bound -- the live chat's order, ChatLaunch builds and Wiring binds" do
        feed = described_class.new(path:)
        question = stored_question
        feed << question
        head = commit_citing(question.digest)

        feed.bind_store(store)
        feed << turn_usage(digest: head)

        expect(published["inbox_count"]).to eq(0)
      end

      # The chain walk is the only thing here that can fail, and it must fail
      # as a miss: this sink rides the JournalTee, which re-raises into the
      # agent loop, so a head the store cannot resolve may not cost the turn.
      it "treats a head the bound Store does not hold as a miss, never a raise" do
        feed = described_class.new(path:, store: Lain::Store.new)
        question = stored_question
        feed << question

        expect { feed << turn_usage(digest: commit_citing(question.digest)) }.not_to raise_error

        expect(published["inbox_count"]).to eq(1)
      end

      # Both carriers write the same standing `@consumed` set, so a replayed
      # log that delivers BOTH retires once and never goes negative.
      it "is idempotent across both carriers -- the usage record and a replayed :turn Event" do
        feed = described_class.new(path:, store:)
        question = stored_question
        feed << question

        feed << turn_usage(digest: commit_citing(question.digest))
        feed << turn_event(causal_parents: [question.digest])

        expect(published["inbox_count"]).to eq(0)
      end

      # The two derivations that ride this same record are the CONTRACTED ones
      # -- `run_tokens` is the published form of Accounting#usage -- so a walk
      # that cannot resolve the head must cost neither them nor the turn. The
      # head here names a stored BODY rather than a turn (ChainWriter puts one
      # per message), which the walk answers with a NoMethodError; the
      # accounting is derived AHEAD of the walk for that reason, and the walk
      # answers a miss rather than raising.
      it "still pays the turn's tokens when the head's chain cannot be walked at all" do
        feed = described_class.new(path:, store:)
        question = stored_question
        feed << question

        expect { feed << turn_usage(digest: question.payload_digest, input: 10, output: 5) }.not_to raise_error

        expect(published["run_tokens"]).to eq(15)
        expect(published["inbox_count"]).to eq(1)
      end

      # slide_cache_deadline and occupancy already rode this record; retirement
      # joined them and may not have disturbed either.
      it "leaves the cache deadline and the occupancy the same record already derived untouched" do
        now = Time.utc(2026, 8, 25, 12, 0, 0)
        feed = described_class.new(path:, store:, clock: -> { now })
        question = stored_question
        feed << question

        feed << turn_usage(digest: commit_citing(question.digest), cache_read: 128, input: 1_000)

        expect(published["cache_deadline"]).to eq((now + described_class::DEFAULT_CACHE_PROFILE[:ttl]).iso8601)
        expect(published["occupancy"]).to eq(1_128.fdiv(Lain::ContextWindow::CONSERVATIVE_FALLBACK))
      end
    end

    # A RELAYED question -- one a subagent asked, re-addressed to the human
    # under its parent's correlation -- is retired by the CHILD's own answering
    # turn, and that turn never reaches this tee: SessionRecord::Scribe keeps a
    # spawned chain's turns in the session file, because routing one costs the
    # child's whole transcript. So the count climbed forever, measured live: a
    # question the human had answered stayed listed for the rest of the session.
    #
    # What the Scribe promotes instead is the one fact this sink needs and a
    # turn record is not -- the digests that turn consumed -- as a
    # Telemetry::QuestionsConsumed. It is admitted BY CLASS, like every other
    # closed-vocabulary record here: a record that merely ANSWERED the right
    # methods would retire on one inbox surface and not the other, which is
    # exactly what the nvim view's parity spec exists to forbid.
    describe "retiring a relayed subagent question" do
      let(:store) { Lain::Store.new }

      def stored_question(question: "which db?", from: "orchestrator")
        parent = Lain::Timeline.empty(store:).commit(role: :user, content: text("seed #{question}"))
        Lain::Event::ChainWriter.new.put(parent, kind: :message, from:, to: "human",
                                                 causal_parents: [], body: { "question" => question })
      end

      def commit_citing(*digests)
        Lain::Timeline.empty(store:)
                      .commit(role: :user, content: text("hi"))
                      .commit(role: :assistant, content: text("asking"), causal_parents: digests)
                      .head_digest
      end

      # Built through the record's own `from_event`, over a real `:turn` Event,
      # so this drives the promotion the Scribe performs rather than a hand-made
      # value that could drift from it.
      def consumption(*digests) = Lain::Telemetry::QuestionsConsumed.from_event(turn_event(causal_parents: digests))

      it "drops a relayed question from the count once the child's turn publishes its consumption edges" do
        feed = described_class.new(path:)
        question = message_event("q1", to: "human")
        feed << question
        expect(published["inbox_count"]).to eq(1)

        feed << consumption(question.digest)

        expect(published["inbox_count"]).to eq(0)
      end

      # The run's own question has no relay hop and retires off its own
      # committed turn's usage record. Both carriers write the one standing
      # consumed set, so driving both through ONE feed is what shows the new arm
      # settles the relayed question WITHOUT disturbing the parent's.
      it "leaves the run's own question retiring off its committed turn, in the same feed" do
        feed = described_class.new(path:, store:)
        relayed = message_event("q1", to: "human")
        own = stored_question
        feed << relayed
        feed << own
        expect(published["inbox_count"]).to eq(2)

        feed << consumption(relayed.digest)
        expect(published["inbox_count"]).to eq(1)

        feed << turn_usage(digest: commit_citing(own.digest))
        expect(published["inbox_count"]).to eq(0)
      end

      it "keeps a relayed question counted when a child turn consumed something else" do
        feed = described_class.new(path:)
        question = message_event("q1", to: "human")
        feed << question

        feed << consumption(message_event("q2", to: "human").digest)

        expect(published["inbox_count"]).to eq(1)
      end
    end
  end

  # The one state a human is actually asked to ACT on. The park record and
  # the decision record are written by Approval::Queue around the same gated
  # call and both ride the tee this sink sits in -- but the decision carries
  # NO tool_use_id, so the pair is counted, never keyed.
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

  # The run's own measures, published as PLAIN DURATIONS beside the one
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

  # `Compaction::Source::Derived` counts consecutive derivation refusals and
  # journals the streak, and until recently nothing in `lib/` read it. Both
  # ends of the streak ride ONE channel -- the journal the
  # Backend hands the Source is the tee this feed sits in -- so a refusal
  # raises the streak here and the `context_derived` of a successful
  # derivation clears it.
  describe "the derivation refusal streak" do
    it "starts at zero, because nothing has refused yet" do
      feed = described_class.new(path:)

      feed << spawn_event("a")

      expect(published["derivation_refusal_streak"]).to eq(0)
    end

    # The streak the RECORD carries, never a count kept here: the Source owns
    # the reset and the increment, and a second tally in this sink could only
    # ever come to disagree with it.
    it "reports the streak the refusal record carries" do
      feed = described_class.new(path:)

      feed << derivation_refused(consecutive: 3)

      expect(published["derivation_refusal_streak"]).to eq(3)
    end

    # The compactions/since_compaction argument, one field over: the streak is
    # derived from an EVENT, so it belongs in the change token. Without it a
    # refusal would move nothing compared, earn no write, and the file would go
    # on saying compaction was healthy.
    it "publishes on the refusal itself, not on the next unrelated event" do
      feed = described_class.new(path:)
      feed << spawn_event("a")

      feed << derivation_refused(consecutive: 1)

      expect(published["derivation_refusal_streak"]).to eq(1)
    end

    # The other end of the same channel. A successful derivation journals a
    # `context_derived` to the journal that carried the refusals, which is what
    # lets the reading clear without this sink guessing at a timeout.
    it "clears the streak when a derivation succeeds" do
      feed = described_class.new(path:)
      feed << derivation_refused(consecutive: 2)

      feed << context_derived

      expect(published["derivation_refusal_streak"]).to eq(0)
    end
  end

  # How full the live model's window the last turn left it, derived
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

    # What a truncated stream journals: a well-formed record naming a real
    # model, every billed field zero.
    def zero_turn_usage
      Lain::Telemetry::TurnUsage.new(
        digest: "blake3:zero", model: "claude-opus-4-8", stop_reason: :end_turn,
        usage: { "input_tokens" => 0, "output_tokens" => 0,
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

    # An unmeasurable turn never overwrites a measured one -- StatusFeed
    # #record_occupancy holds the argument. These pin the four ways a turn comes
    # out unmeasurable and the one thing they all do about it.
    it "leaves the last real occupancy standing when a turn bills nothing at all" do
      feed = described_class.new(path:)
      feed << sized_turn_usage(input_tokens: 500_000)

      feed << zero_turn_usage

      expect(published["occupancy"]).to eq(0.5)
    end

    # The gate is over the fields the NUMERATOR is over. A four-field total
    # would admit this record and divide a real window by zero; Ollama's decoder
    # reads `prompt_eval_count` straight off the body, so a reply carrying no
    # such key is exactly this shape.
    it "leaves it standing for a turn that billed output against no input at all" do
      feed = described_class.new(path:)
      feed << sized_turn_usage(input_tokens: 500_000)

      feed << Lain::Telemetry::TurnUsage.new(digest: "blake3:out-only", model: "claude-opus-4-8",
                                             stop_reason: :end_turn, usage: { "output_tokens" => 250 })

      expect(published["occupancy"]).to eq(0.5)
    end

    # The rescue below used to ASSIGN its nil, so a turn with real tokens and an
    # unresolvable model erased a good reading -- the same defect one field over.
    it "leaves it standing when the book cannot resolve the turn's model" do
      feed = described_class.new(path:, context_window: Lain::ContextWindow.new(windows: { "tiny" => 1000 }))
      feed << sized_turn_usage(input_tokens: 250, model: "tiny-local")

      feed << sized_turn_usage(input_tokens: 250, model: nil)

      expect(published["occupancy"]).to eq(0.25)
    end

    # The half a `return if unmeasurable` would break: only the RATIO is
    # suppressed. run_tokens is contracted to equal Agent::Accounting's total,
    # which counts the record either way.
    it "still accrues the unmeasurable turn's tokens rather than dropping the record" do
      feed = described_class.new(path:)
      feed << sized_turn_usage(input_tokens: 500_000)

      feed << zero_turn_usage

      expect(published["run_tokens"]).to eq(500_005)
    end

    # With no reading behind it there is nothing to keep, and absence is what
    # publishes -- never a floor of 0.0.
    it "publishes absence, never a zero, when the first turn observed bills nothing" do
      feed = described_class.new(path:)

      feed << zero_turn_usage

      expect(published["occupancy"]).to be_nil
    end

    # JournaledUsage reads with `to_i`, which makes "malformed" asymmetric on
    # purpose: unparseable garbage reads 0 and so SUPPRESSES (the examples
    # above), while a plausible count in the wrong JSON type still MEASURES. A
    # provider spelling a number as a string or a float is a wire quirk, not a
    # claim about how full the window is, so it is taken as authoritative.
    # Neither direction was pinned before; this is which one it is.
    it "measures a token count that arrived as a numeric string" do
      feed = described_class.new(path:)

      feed << Lain::Telemetry::TurnUsage.new(digest: "blake3:str", model: "claude-opus-4-8",
                                             stop_reason: :end_turn, usage: { "input_tokens" => "250000" })

      expect(published["occupancy"]).to eq(0.25)
    end

    it "measures a token count that arrived as a JSON float, truncating it" do
      feed = described_class.new(path:)

      feed << Lain::Telemetry::TurnUsage.new(digest: "blake3:float", model: "claude-opus-4-8",
                                             stop_reason: :end_turn, usage: { "input_tokens" => 250_000.0 })

      expect(published["occupancy"]).to eq(0.25)
    end

    # The half-fix guard. Two surfaces read this number -- `.lain/state.json`
    # (this sink) and the `ctx` segment of the REPL prompt line
    # ({Frontend::PromptComposer::RunState}, which asks the live {Agent}) -- and
    # they divide by whatever book each was handed. Wiring one and not the other
    # is WORSE than leaving both wrong, because a human then has two numbers
    # that disagree and no way to tell which is the lie. One book, both readers.
    it "publishes the same occupancy the REPL prompt line renders, off one shared book" do
      book = Lain::ContextWindow.new(windows: { "qwen3-coder:30b" => 32_768 },
                                     fallback: Lain::ContextWindow::CONSERVATIVE_FALLBACK)
      agent = Lain::Agent.new(
        provider: Lain::Provider::Mock.new(
          responses: [Lain::Response.new(content: [{ "type" => "text", "text" => "hi" }], stop_reason: :end_turn,
                                         usage: Lain::Usage.new(input_tokens: 7_079, output_tokens: 1))]
        ),
        toolset: Lain::Toolset.new([]),
        context: Lain::Context.new(model: "qwen3-coder:30b", max_tokens: 64),
        context_window: book
      )
      agent.ask("hi")
      feed = described_class.new(path:, context_window: book)

      feed << sized_turn_usage(input_tokens: 7_079, model: "qwen3-coder:30b")
      prompt = Lain::Frontend::PromptComposer::RunState.new(agent:, clock: Lain::RunClock.new, status_feed: feed)

      expect(published["occupancy"]).to eq(7_079.fdiv(32_768))
      expect(prompt.to_h["occupancy"]).to eq("#{(published["occupancy"] * 100).round}%")
    end

    # The same guard where the two readers do NOT hold the same model string,
    # which is the case the example above structurally cannot see. Agent
    # #occupancy divides using `context.model` -- the operator's `--model qwen3`
    # -- while this sink divides using `event.model`, whatever the provider
    # ECHOED on the turn. Ollama prints an untagged request back tagged, so one
    # book is asked about `qwen3` by the prompt and `qwen3:latest` by the feed.
    #
    # A window GRANTED through `Ollama#serves?`'s `:latest` branch and then
    # refused to the `:latest` name splits the two surfaces by exactly one tag,
    # in the untagged-model case the served book was written for.
    it "agrees when the turn echoes the tagged name the run was started untagged with" do
      book = Lain::CLI::Backend::WindowBook::Served.new(model: "qwen3", window_tokens: 32_768)
      agent = Lain::Agent.new(
        provider: Lain::Provider::Mock.new(
          responses: [Lain::Response.new(content: [{ "type" => "text", "text" => "hi" }], stop_reason: :end_turn,
                                         usage: Lain::Usage.new(input_tokens: 7_079, output_tokens: 1))]
        ),
        toolset: Lain::Toolset.new([]),
        context: Lain::Context.new(model: "qwen3", max_tokens: 64),
        context_window: book
      )
      agent.ask("hi")
      feed = described_class.new(path:, context_window: book)

      feed << sized_turn_usage(input_tokens: 7_079, model: "qwen3:latest")
      prompt = Lain::Frontend::PromptComposer::RunState.new(agent:, clock: Lain::RunClock.new, status_feed: feed)

      expect(published["occupancy"]).to eq(7_079.fdiv(32_768))
      expect(prompt.to_h["occupancy"]).to eq("#{(published["occupancy"] * 100).round}%")
    end

    # A defect that PRE-DATES the run_tokens field and was live on main: an
    # oracle answer answers `#usage` and names a model, so `occupancy_of` ran
    # on it and republished the ORACLE's prompt measured against the CHAT's
    # window -- a status bar reporting a context that no turn ever filled.
    # Reproduced at 0.005 -> 0.045 on one oracle answer before the fix. The
    # `#stop_reason` half of the duck is what shuts it out.
    it "is not moved by an oracle answer, whose prompt is not this context" do
      feed = described_class.new(path:)
      feed << turn_usage(input: 1_000, output: 20)
      after_turn = published["occupancy"]

      feed << oracle_answer(input: 9_000, output: 300)

      expect(published["occupancy"]).to eq(after_turn)
    end

    # The pin that INPUT_TOKEN_FIELDS restates Usage#total_input_tokens exactly
    # moved with the constant, to
    # spec/lain/status_feed/journaled_usage_spec.rb.
  end

  # What this session has spent, summed off the same per-payment records
  # the Journal keeps. Every example here is about the number being a RUNNING
  # TOTAL over events -- which is what puts it in #observed rather than the
  # measures, and what the seam spec pins against Agent::Accounting.
  # Suppressing an unmeasurable reading is silent by construction: `occupancy`
  # simply stops moving while `run_tokens` keeps climbing, which reads on a
  # status bar as a STUCK context rather than a stale reading. This field is
  # what tells the two apart, on derivation_refusal_streak's argument -- a
  # streak, so it answers "how stale" and a measured turn clears it.
  describe "unmeasured_turns" do
    def measurable = turn_usage(input: 10)

    def unmeasurable
      Lain::Telemetry::TurnUsage.new(digest: "blake3:unmeasurable", model: "claude-x",
                                     stop_reason: :end_turn, usage: { "output_tokens" => 7 })
    end

    # The record the sink refuses to derive anything at all from -- see the
    # occupancy group's own pin for why that guard exists.
    def nil_usage
      Lain::Telemetry::TurnUsage.new(digest: "blake3:nilusage", model: "claude-x",
                                     stop_reason: :end_turn, usage: nil)
    end

    it "is zero while every turn can be measured" do
      feed = described_class.new(path:)

      feed << measurable

      expect(published["unmeasured_turns"]).to eq(0)
    end

    it "counts the turns in a row whose window could not be measured" do
      feed = described_class.new(path:)

      2.times { feed << unmeasurable }

      expect(published["unmeasured_turns"]).to eq(2)
    end

    it "clears on the next turn that can be measured" do
      feed = described_class.new(path:)
      feed << unmeasurable

      feed << measurable

      expect(published["unmeasured_turns"]).to eq(0)
    end

    # The fourth unmeasurable cause, and the one that used to bypass the single
    # writer: a record whose `usage` is nil returns before any derivation runs,
    # because `nil["input_tokens"]` inside a JournalTee sink once cost a turn. A
    # truncated stream that fabricates NO usage block and one that fabricates
    # all-zero counts are the same failure in two hats, so the streak has to see
    # both -- a run of them reading 0 would say "fresh" during exactly the
    # stretch this field exists to make visible.
    it "counts a record whose usage block is missing entirely, and keeps the reading" do
      feed = described_class.new(path:)
      feed << measurable
      standing = published["occupancy"]

      3.times { feed << nil_usage }

      expect(published["unmeasured_turns"]).to eq(3)
      expect(published["occupancy"]).to eq(standing)
    end

    it "goes on counting when a nil-usage record follows another unmeasurable one" do
      feed = described_class.new(path:)
      feed << measurable
      feed << unmeasurable

      feed << nil_usage

      expect(published["unmeasured_turns"]).to eq(2)
    end

    # Derived from an EVENT, so it belongs in the change token -- otherwise the
    # first suppressed turn after a quiet stretch moves no compared field and
    # the write carrying it is skipped.
    it "is part of the observed state a publish is compared on" do
      feed = described_class.new(path:)

      expect(feed.observed).to have_key("unmeasured_turns")
    end
  end

  describe "run_tokens" do
    # `#usage` alone is not the duck, and this is the whole reason the feed
    # asks for `#stop_reason` too -- Compaction::Source#turn_usage? has drawn
    # the same distinction since 2026-07-25, for a sibling failure on the same
    # record. Oracle spend is real and is deliberately somebody else's field:
    # this one's contract is equality with Accounting#usage, which does not
    # carry it. spec/lain/seams/usage_parity_spec.rb measures the divergence.
    it "does not count an oracle answer, which answers #usage but is not a turn" do
      feed = described_class.new(path:)

      feed << turn_usage(input: 100, output: 20)
      feed << oracle_answer(input: 9_000, output: 300)

      expect(published["run_tokens"]).to eq(120)
    end

    # The record set this field sums is a CLOSED vocabulary of one, so it is
    # matched by class -- this file's own convention (Telemetry::Compaction,
    # ContextDerived, ModeSwitch and DerivationRefused are all matched that
    # way, each with a comment saying a duck would be a guess). The oracle
    # example above is what a guess costs. `#usage` + `#stop_reason` would
    # re-arm exactly that defect for the next Telemetry record that happens to
    # carry both fields, silently and with this file's specs still green, so
    # the stand-in below stands in for that future record.
    it "counts only a real TurnUsage, not merely something shaped like one" do
      feed = described_class.new(path:)
      lookalike = Struct.new(:usage, :stop_reason, :model)
                        .new({ "input_tokens" => 9_000, "output_tokens" => 300 }, :end_turn, "claude-x")

      feed << turn_usage(input: 100, output: 20)
      feed << lookalike

      expect(published["run_tokens"]).to eq(120)
    end

    it "is nil before any usage is observed, rather than a zero that reads as a real spend" do
      feed = described_class.new(path:)

      feed << spawn_event("a")

      expect(published["run_tokens"]).to be_nil
    end

    it "publishes the sum of two observed TurnUsage records" do
      feed = described_class.new(path:)

      feed << turn_usage(input: 100, output: 20, cache_read: 3, cache_creation: 1)
      feed << turn_usage(input: 200, output: 40, cache_read: 5, cache_creation: 2)

      expect(published["run_tokens"]).to eq(371)
    end

    # The record is a PAYMENT, not content: Telemetry::TurnUsage's own doc says
    # a regenerated turn lands twice under one digest and both were paid for.
    # Deduplicating here would undercount exactly what Accounting counts.
    it "counts a regenerated turn's second payment, since digests are not unique across records" do
      feed = described_class.new(path:)

      2.times { feed << turn_usage(digest: "blake3:same", input: 100, output: 20) }

      expect(published["run_tokens"]).to eq(240)
    end

    it "ignores a record whose usage is absent rather than raising" do
      feed = described_class.new(path:)
      feed << turn_usage(input: 100, output: 20)

      feed << Lain::Telemetry::TurnUsage.new(digest: "blake3:b", model: "claude-x",
                                             stop_reason: :end_turn, usage: nil)

      expect(published["run_tokens"]).to eq(120)
    end

    # The card's third scenario, and the reason the field is in #observed: a
    # value that lives in #measures republishes once a second forever, which
    # costs a write+rename per second and destroys the struct as a change token.
    it "does not move #observed, or earn a republish, when only the clock has ticked" do
      now = 1000.0
      feed = described_class.new(path:, run_clock: Lain::RunClock.new(clock: -> { now }))
      feed << turn_usage(input: 100, output: 20)
      feed << spawn_event("a")
      before = feed.observed
      written_at = File.mtime(path)

      now = 1060.0
      feed << spawn_event("a")

      expect(feed.observed).to eq(before)
      expect(feed.observed["run_tokens"]).to eq(120)
      expect(File.mtime(path)).to eq(written_at)
    end

    # The pin that TOKEN_FIELDS restates Usage#total_tokens exactly lives with
    # the constant, in spec/lain/status_feed/journaled_usage_spec.rb; what this
    # block covers is the ACCRUAL -- that the feed sums those readings over
    # records, publishes the running total, and does so in #observed.
  end

  # The mode, published for the tmux HUD. Two keys, because they answer
  # different questions: `posture` is the exclusive slot as DATA (a bench, an
  # nvim view, a journal reader), `mode_lighter` is the already-composed
  # rendering, so none of the three renderers reading `.lain/state.json` needs
  # its own copy of the posture/layer ladder.
  describe "the mode" do
    # `toolset:` defaults to an empty Toolset named HERE, at this helper's own
    # call site: nothing in this describe block is about what a flip resolved
    # to, only about the sink's own publish/republish rules.
    def mode_switch(to:, from: :manual, from_layers: [], to_layers: [], surface: "tty", toolset: Lain::Toolset.new)
      Lain::Telemetry::ModeSwitch.new(from:, to:, from_layers:, to_layers:, surface:, toolset_digest: toolset.digest,
                                      tool_names: toolset.names)
    end

    # This sink is built in ChatLaunch#open_chronicle, BEFORE Wiring exists,
    # and Mode::Switch journals nothing at construction -- so until the first
    # /mode, the honest answer is "not told", never a guessed default.
    it "is absent until a mode_switch record names a posture" do
      feed = described_class.new(path:)

      feed << turn_usage

      expect(published.values_at("posture", "layers", "mode_lighter")).to eq([nil, nil, nil])
    end

    # The layer half ships as DATA beside the rendered lighter, so a bench arm
    # asking "was auto_approve on?" answers with a set membership rather than a
    # substring match against "AA".
    it "publishes the active layers as names, not only as a substring of the lighter" do
      feed = described_class.new(path:)

      feed << mode_switch(from: :manual, to: :manual, to_layers: %i[auto_approve goal])

      expect(published["layers"]).to eq(%w[auto_approve goal])
    end

    it "publishes the posture the record switched TO, not the one it left" do
      feed = described_class.new(path:)

      feed << mode_switch(from: :manual, to: :plan)

      expect(published["posture"]).to eq("plan")
    end

    # The layer list is built through a real LayerSet, exactly as Mode::Switch
    # builds it: the record's own doc promises precedence order, so composing
    # the lighter must READ that order rather than re-canonicalize it -- a
    # second copy of a rule LayerSet already owns.
    it "composes the lighter from the posture and every active layer, in the record's precedence order" do
      feed = described_class.new(path:)
      mode = Lain::Mode.new(posture: :manual, layers: %i[goal auto_approve])

      feed << mode_switch(from: :manual, to: mode.posture.name, to_layers: mode.layers.names)

      expect(published["mode_lighter"]).to eq("MAN AA GOAL")
    end

    # accept_edits declares an EMPTY lighter -- the default is silent, and that
    # rule lives in Posture's table, not in three renderers' filters.
    it "composes an empty lighter for the default posture, which declares itself silent" do
      feed = described_class.new(path:)

      feed << mode_switch(from: :manual, to: :accept_edits)

      expect(published.values_at("posture", "mode_lighter")).to eq(["accept_edits", ""])
    end

    it "republishes when the posture moves" do
      feed = described_class.new(path:)
      feed << mode_switch(from: :manual, to: :manual)
      allow(File).to receive(:write).and_call_original

      feed << mode_switch(from: :manual, to: :auto)

      expect(File).to have_received(:write).once
    end

    # The carry-forward from the approval work: `/mode +auto_approve` journals
    # `manual -> manual`, and auto_approve is the one layer that alters an
    # outcome. A guard comparing the posture ALONE would suppress the publish
    # and leave the HUD saying "MAN" while the approval gate had been turned
    # off -- the silently-active policy this plan's Design forbids.
    it "republishes a layer flip that never moved the posture" do
      feed = described_class.new(path:)
      feed << mode_switch(from: :manual, to: :manual)
      allow(File).to receive(:write).and_call_original

      feed << mode_switch(from: :manual, to: :manual, to_layers: %i[auto_approve])

      expect(File).to have_received(:write).once
      expect(published["mode_lighter"]).to eq("MAN AA")
    end

    it "skips the write when an unrelated record arrives and the mode did not move" do
      feed = described_class.new(path:)
      feed << mode_switch(from: :manual, to: :plan)
      feed << spawn_event("a")
      allow(File).to receive(:write).and_call_original

      feed << spawn_event("a") # redelivery: nothing this feed derives moved

      expect(File).not_to have_received(:write)
    end

    it "skips the write on a redelivered mode_switch, which moves no derived field" do
      feed = described_class.new(path:)
      feed << mode_switch(from: :manual, to: :auto)
      allow(File).to receive(:write).and_call_original

      feed << mode_switch(from: :manual, to: :auto)

      expect(File).not_to have_received(:write)
    end

    # Posture.for/Layer.for raise ArgumentError on an undeclared name, and this
    # sink rides the JournalTee, which re-raises -- so a record written by a
    # newer lain (or replayed from an older one) would cost the agent its turn
    # over a status line. It degrades to naming the thing instead, which is
    # loud where silence would be the bug.
    it "never raises on a posture name this build does not declare, and still names it" do
      feed = described_class.new(path:)

      expect { feed << mode_switch(from: :manual, to: :turbo) }.not_to raise_error
      expect(published.values_at("posture", "mode_lighter")).to eq(%w[turbo turbo])
    end

    it "never raises on a layer name this build does not declare, and still names it" do
      feed = described_class.new(path:)

      expect { feed << mode_switch(from: :manual, to: :manual, to_layers: %i[telepathy]) }.not_to raise_error
      expect(published["mode_lighter"]).to eq("MAN telepathy")
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
      telemetry = chronicle_teed_to(feed).instrumentation.journal

      telemetry << Lain::Telemetry::TurnUsage.new(
        digest: "blake3:t", model: "claude-opus-4-8", stop_reason: :end_turn,
        usage: { "input_tokens" => 500_000, "output_tokens" => 1,
                 "cache_read_input_tokens" => 0, "cache_creation_input_tokens" => 0 }
      )
      telemetry << Lain::Telemetry::Compaction.new(trigger: "token_threshold", cache_state: :cold,
                                                   bytes_before: 10, bytes_after: 1,
                                                   cost_saved: nil, cost_spent: nil)

      expect(published["occupancy"]).to eq(0.5)
      expect(published["since_compaction"]).to eq(0)
    end

    # ARRIVAL, not derivation. `Backend#compaction_source` hands the
    # Source the very journal `CompactionMount#destination` reads off this
    # chronicle's instrumentation, and that is the tee this feed rides -- so a
    # refusal written by `Compaction::Source::Derived` lands here. Driven down
    # that leg rather than into `feed <<` for the same reason the mode example
    # below drives a real Mode::Switch: the derivation is proven in
    # spec/lain/compaction/source_spec.rb, and what is unproven is the channel.
    it "publishes a refusal streak sent down the leg the compaction Source is given" do
      feed = described_class.new(path:)
      telemetry = chronicle_teed_to(feed).instrumentation.journal

      telemetry << derivation_refused(consecutive: 2)

      expect(published["derivation_refusal_streak"]).to eq(2)
    end

    # The same wiring question for the mode. Every other mode example hands
    # a Telemetry::ModeSwitch straight to `feed <<`, which proves the
    # derivation and proves nothing about ARRIVAL -- and arrival is exactly
    # what a known gap one field over got wrong. So this drives a real
    # Mode::Switch over the chronicle's own record journal, the leg
    # Approval::PolicySwitch and Context::ModelSwitch already use.
    it "publishes a flip made by a real Mode::Switch over the chronicle's record journal" do
      feed = described_class.new(path:)
      switch = Lain::Mode::Switch.new(Lain::Mode.new(posture: :manual),
                                      journal: chronicle_teed_to(feed).record_journal)

      switch.switch(Lain::Mode.new(posture: :plan, layers: %i[auto_approve]), surface: "tty", toolset: Lain::Toolset.new)

      expect(published.values_at("posture", "layers", "mode_lighter"))
        .to eq(["plan", %w[auto_approve], "PLAN AA"])
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
      # An empty base set says what this example is not about: it wants the
      # board's queue, and a posture never attenuates on this path.
      Lain::CLI::Switchboard.for(chronicle: chronicle_teed_to(feed), options: {},
                                 model: "claude-opus-4-8", toolset: Lain::Toolset.new,
                                 test_layout: Lain::Middleware::GuardTestLayout::Run.undeclared).approvals
    end
  end

  # One NON-GOAL and one pinned fold, both held here so a later change cannot
  # move either without a spec saying so.
  #
  # The NON-GOAL is the live inbox over-count: the :turn that would retire a
  # question never reaches this sink -- see the class doc.
  #
  # The fleet reading beside it was once listed as an undercount too, and is
  # not one. Two BYTE-IDENTICAL :spawn events are one member, because the fleet
  # keys on content address and identical bytes name one spawn; the fixtures
  # below construct that pair directly and never route through
  # Tools::Subagent::Lineage, so what this pins is the FOLD, not what the actor
  # path feeds it. The actor path stopped feeding it identical bytes when a
  # per-adoption ordinal entered an actor spawn's body -- two live twins are
  # two members now, pinned at unit grain in spec/lain/status_feed/fleet_spec.rb
  # and end to end in spec/lain/supervisor_reactor_spec.rb.
  #
  # Not an absolute, and the caveat belongs beside the claim rather than only in
  # Tools::Subagent::Lineage's doc, which is where it is argued: that ordinal is
  # scoped to the WRITER, so a SECOND writer over one head starts its count
  # again and re-collides. No production actor path reaches that today -- a
  # cockpit memoizes one Subagent -- but a resumed run or any second writer
  # would put identical bytes back on this sink, and the fold below is what it
  # would meet.
  describe "the known defect and the fold beside it, unchanged by the wider state" do
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

  describe "state (public reader)" do
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
                                                "occupancy", "unmeasured_turns", "compactions",
                                                "derivation_refusal_streak",
                                                "run_tokens", "posture", "layers", "mode_lighter",
                                                "elapsed", "idle", "since_compaction")
    end

    it "creates the destination directory (the project's .lain/) on demand" do
      nested = File.join(@dir, ".lain", "state.json")
      feed = described_class.new(path: nested)

      feed << turn_usage

      expect(File.read(nested)).not_to be_empty
    end

    # This feed, `lain up`'s HUD and the TTY prompt all default to the same
    # file and now ASK one locator for it. The locator is stubbed to answer a
    # path it would never derive on its own, so the example fails if the default
    # is composed here instead of delegated -- a literal cannot honour an answer
    # it never asked for. The chdir only keeps a regressed default inside the
    # tmpdir instead of writing into the real repo.
    it "asks the ONE project locator for its default path rather than composing one" do
      elsewhere = File.join(@dir, "the-locator-said-here", "state.json")
      allow(Lain::ProjectDir).to receive(:new).and_return(instance_double(Lain::ProjectDir, state_path: elsewhere))

      Dir.chdir(@dir) { described_class.new << turn_usage }

      expect(File.read(elsewhere)).not_to be_empty
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
      # The refusal is NAMED because the destination moved from the
      # project's own `.lain/`, which the user is by definition working in, to
      # a state home that can be read-only or occupied, so a bare errno now
      # reaches a human as a crash about a path they never typed. The kernel's
      # answer survives as `#cause`.
      expect { feed << turn_usage(cache_read: 2) }
        .to raise_error(Lain::StatusFeed::Publication::Unpublishable) { |e| expect(e.cause).to be_a(Errno::ENOSPC) }

      expect(File.read(path)).to eq(good_bytes)
    end

    it "leaves no leftover tmp file behind after a successful publish" do
      feed = described_class.new(path:)

      feed << turn_usage

      expect(Dir.children(@dir)).to eq(["state.json"])
    end

    # Publishing unconditionally was part of the O(n^2)
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

  # The O(n) Event::Projection fold that used to run on
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

  # A review side effect, not itself a fix: the reviewer's torn-read probe
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
