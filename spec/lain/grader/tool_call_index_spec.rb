# frozen_string_literal: true

# The shared substrate selection-frequency grading and outcome-lineage walks
# both read from -- an offline projection over a Journal's turn records
# pairing each tool_use with its outcome. No production writer emits a
# standalone `tool_result` RECORD (only `tool_use`/`tool_result` content
# BLOCKS inside `turn` records), so this generalizes
# {Lain::Bench::Session::MemoryReplay#outcomes}'s pairing recipe from
# "memory_write, is_error only" to "any tool, full outcome".
RSpec.describe Lain::Grader::ToolCallIndex do
  let(:store) { Lain::Store.new }

  def text(body) = [{ "type" => "text", "text" => body }]
  def tool_use(id, name, input) = { "type" => "tool_use", "id" => id, "name" => name, "input" => input }

  def tool_result(id, content, is_error: false)
    { "type" => "tool_result", "tool_use_id" => id, "content" => content, "is_error" => is_error }
  end

  def journal_turns(timeline)
    timeline.to_a.map { |turn| Lain::SessionRecord.turn(turn) }
  end

  describe "pairing a tool_use with its outcome" do
    it "pairs a tool_use with its outcome (name, args, is_error, result), keyed by the issuing turn's digest" do
      call_turn = Lain::Timeline.empty(store:)
                                .commit(role: :user, content: text("please echo"))
                                .commit(role: :assistant, content: [tool_use("tu_1", "echo", { "text" => "hi" })])
      result_turn = call_turn.commit(role: :user, content: [tool_result("tu_1", "hi")])

      index = described_class.new(journal_turns(result_turn))
      call = index.calls.fetch(call_turn.head_digest).first

      expect(call.name).to eq("echo")
      expect(call.args).to eq({ "text" => "hi" })
      expect(call.is_error).to be(false)
      expect(call.result).to eq("hi")
    end

    it "keys on tool_use_id, not name, so two parallel calls to the same tool don't merge" do
      call_turn = Lain::Timeline.empty(store:)
                                .commit(role: :user, content: text("please echo twice"))
                                .commit(role: :assistant, content: [
                                          tool_use("tu_1", "echo", { "text" => "one" }),
                                          tool_use("tu_2", "echo", { "text" => "two" })
                                        ])
      # Results committed out of tool_use order, as a real gathered dispatch
      # (Agent::ToolRunner#gather) can return them.
      result_turn = call_turn.commit(role: :user, content: [
                                       tool_result("tu_2", "two"),
                                       tool_result("tu_1", "one")
                                     ])

      pairs = described_class.new(journal_turns(result_turn)).calls.fetch(call_turn.head_digest)

      expect(pairs.map(&:tool_use_id)).to eq(%w[tu_1 tu_2])
      expect(pairs.find { |call| call.tool_use_id == "tu_1" }.args).to eq({ "text" => "one" })
      expect(pairs.find { |call| call.tool_use_id == "tu_2" }.args).to eq({ "text" => "two" })
    end

    it "carries an error outcome's content, not only the is_error flag" do
      call_turn = Lain::Timeline.empty(store:)
                                .commit(role: :user, content: text("try boom"))
                                .commit(role: :assistant, content: [tool_use("tu_1", "boom", {})])
      result_turn = call_turn.commit(role: :user, content: [tool_result("tu_1", "kaboom", is_error: true)])

      call = described_class.new(journal_turns(result_turn)).calls.fetch(call_turn.head_digest).first

      expect(call.is_error).to be(true)
      expect(call.result).to eq("kaboom")
    end

    it "leaves a tool_use with no recorded outcome unpaired (never executed, not fabricated)" do
      call_turn = Lain::Timeline.empty(store:)
                                .commit(role: :user, content: text("ask"))
                                .commit(role: :assistant, content: [tool_use("tu_1", "echo", { "text" => "hi" })])

      call = described_class.new(journal_turns(call_turn)).calls.fetch(call_turn.head_digest).first

      expect(call.is_error).to be_nil
      expect(call.result).to be_nil
    end

    # Only a tool_result answers a tool_use. Anthropic's block vocabulary is
    # non-exhaustive and other shapes carry a `tool_use_id` too --
    # `web_search_tool_result` is the shipped example -- so the outcome map's
    # type filter is what keeps one of those from being read as the call's
    # answer. Given all four keys here, so the filter's absence would show up as
    # a WRONG outcome rather than as a raise on a missing one.
    it "pairs only from tool_result blocks -- another shape naming the same tool_use_id is not the outcome" do
      call_turn = Lain::Timeline.empty(store:)
                                .commit(role: :user, content: text("search"))
                                .commit(role: :assistant, content: [tool_use("tu_1", "search", { "q" => "cats" })])
      foreign = { "type" => "web_search_tool_result", "tool_use_id" => "tu_1",
                  "content" => "not an outcome", "is_error" => true }
      result_turn = call_turn.commit(role: :user, content: [foreign])

      call = described_class.new(journal_turns(result_turn)).calls.fetch(call_turn.head_digest).first

      expect(call.is_error).to be_nil
      expect(call.result).to be_nil
    end

    it "omits a turn with no tool_use from #calls entirely" do
      turn = Lain::Timeline.empty(store:).commit(role: :user, content: text("just chatting"))

      expect(described_class.new(journal_turns(turn)).calls).to eq({})
    end

    it "enumerates every paired call flat via #each, the fold selection frequency wants" do
      first = Lain::Timeline.empty(store:)
                            .commit(role: :user, content: text("go"))
                            .commit(role: :assistant, content: [tool_use("tu_1", "echo", { "text" => "a" })])
      after_first = first.commit(role: :user, content: [tool_result("tu_1", "a")])
      second = after_first.commit(role: :assistant, content: [tool_use("tu_2", "echo", { "text" => "b" })])
      result_turn = second.commit(role: :user, content: [tool_result("tu_2", "b")])

      index = described_class.new(journal_turns(result_turn))

      expect(index.map(&:name)).to eq(%w[echo echo])
      expect(index.map(&:name).tally).to eq({ "echo" => 2 })
    end
  end

  # Lineage is read where a chat records it -- a `:spawn`, a completion
  # `message` and the child's `child_turn` records -- so every session here is
  # written by a real Scribe observing a real spawn.
  describe "lineage across a recorded spawn" do
    def spawn_session(prefix: :fresh, prompt: "child task")
      RecordedSpawnSession.new(
        prefix:,
        parent_responses: [tool_response(["tu_spawn", "subagent", { "prompt" => prompt }]), text_response("done")],
        child_responses: [tool_response(["tu_1", "echo", { "text" => "hi" }]), text_response("child done")]
      ).run
    end

    def turn_digest(session, type, &) = session.of_type(type).find(&).fetch("digest")

    def calls?(record, name)
      Array(record.dig("payload", "content") || record["content"]).any? do |block|
        block["name"] == name
      end
    end

    def calling(session, name)
      turn_digest(session, Lain::SessionRecord::CHILD_TURN_TYPE) { |record| calls?(record, name) }
    end

    def texts_root(records, text)
      records.find { |record| record.dig("payload", "content", 0, "text") == text }.fetch("digest")
    end

    def spawning(session)
      turn_digest(session, "turn") { |record| record["content"].any? { |block| block["name"] == "subagent" } }
    end

    it "indexes the child's calls beside the parent's, each paired with its own outcome" do
      session = spawn_session
      call = described_class.new(session.records).calls.fetch(calling(session, "echo")).first

      expect([call.name, call.is_error, call.result]).to eq(["echo", false, "hi"])
    end

    it "walks a fresh child's turn back through its root to the parent turn that spawned it" do
      session = spawn_session
      parent_root = session.agent.timeline.to_a.first.digest
      child_root = session.of_type(Lain::SessionRecord::CHILD_TURN_TYPE).first.fetch("digest")

      lineage = described_class.new(session.records).lineage(calling(session, "echo")).to_a

      expect(lineage).to eq([calling(session, "echo"), child_root, spawning(session), parent_root])
    end

    it "walks an inheriting child's turn straight onto the parent chain at its spawn point" do
      session = spawn_session(prefix: :inherit)

      lineage = described_class.new(session.records).lineage(calling(session, "echo")).to_a

      expect(lineage).to include(spawning(session))
      expect(lineage.last).to eq(session.agent.timeline.to_a.first.digest)
    end

    it "agrees whether the child's records were written before or after the parent's turns" do
      session = spawn_session
      flat, turns = session.records.partition { |record| record["type"] != "turn" }
      header, flat = flat.partition { |record| record["type"] == "session" }

      written = described_class.new(session.records).lineage(calling(session, "echo")).to_a
      reordered = described_class.new(header + turns + flat).lineage(calling(session, "echo")).to_a

      expect(reordered).to eq(written)
    end

    # A fresh child seeded with the human's opening text commits the parent's
    # own root turn: one event, recorded once. It is a root of the parent's
    # chain, so it gains no spawn edge -- which would otherwise loop the walk
    # back down that chain forever.
    it "ends a child walk at a root it shares with the parent chain, rather than cycling" do
      session = spawn_session(prompt: RecordedSpawnSession::OPENING)

      # Bounded, so a cycle fails here rather than hanging the run.
      lineage = described_class.new(session.records).lineage(calling(session, "echo")).take(16)

      expect(lineage.uniq).to eq(lineage)
      expect(lineage.last).to eq(session.agent.timeline.to_a.first.digest)
    end

    # A child and its grandchild given the same fresh prompt commit one root,
    # claimed from two heads. Either edge is wrong for one of them, and keeping
    # the child's loops the grandchild's walk through the child forever.
    it "ends a walk at a root two nested spawns share, rather than cycling" do
      session = RecordedSpawnSession.new(
        parent_responses: [tool_response(["tu_s", "subagent", { "prompt" => "same task" }]), text_response("done")],
        child_responses: [tool_response(["tu_g", "subagent", { "prompt" => "same task" }]), text_response("child")],
        grandchild_responses: [tool_response(["tu_1", "echo", { "text" => "hi" }]), text_response("grandchild")]
      ).run
      shared = session.of_type(Lain::SessionRecord::CHILD_TURN_TYPE).first.fetch("digest")

      # Bounded, so a cycle fails here rather than hanging the run.
      lineage = described_class.new(session.records).lineage(calling(session, "echo")).take(16)

      expect(lineage.uniq).to eq(lineage)
      expect(lineage.last).to eq(shared)
    end

    # A live file: the grandchild finished, the child that spawned it has not,
    # so the child's turns are no completed lineage this index holds.
    it "ends a walk at the root of a child spawned from a turn still in progress" do
      session = RecordedSpawnSession.new(
        parent_responses: [tool_response(["tu_s", "subagent", { "prompt" => "child task" }]), text_response("done")],
        child_responses: [tool_response(["tu_g", "subagent", { "prompt" => "grandchild task" }]),
                          tool_response(["tu_snap", "snapshot", {}]), text_response("child")],
        grandchild_responses: [tool_response(["tu_1", "echo", { "text" => "hi" }]), text_response("grandchild")]
      ).run
      live = Lain::Journal.records(session.snapshots.first.each_line).to_a
      echo = live.find { |record| record["type"] == Lain::SessionRecord::CHILD_TURN_TYPE && calls?(record, "echo") }

      lineage = described_class.new(live).lineage(echo.fetch("digest")).to_a

      expect(lineage.last).to eq(texts_root(live, "grandchild task"))
    end

    # A resumed file's first turn continues a head its prior file holds: the
    # slice ends there, which is not the dangling predecessor a torn slice is.
    it "ends a resumed file's walk at the head it continues, rather than refusing it as dangling" do
      prior = RecordedSpawnSession.new(parent_responses: [text_response("hello")], child_responses: []).run
      resumed = RecordedSpawnSession.new(
        resuming: [prior, "prior.ndjson"],
        parent_responses: [tool_response(["tu_e", "echo", { "text" => "again" }]), text_response("done")],
        child_responses: []
      ).run("again")
      echo = turn_digest(resumed, "turn") { |record| calls?(record, "echo") }

      lineage = described_class.new(resumed.records).lineage(echo).to_a

      expect(lineage.last).to eq(resumed.of_type("turn").first.fetch("digest"))
    end

    it "stops at a chain root no spawn names -- an ordinary (non-subagent) chain" do
      turn = Lain::Timeline.empty(store:).commit(role: :user, content: text("hi"))
                           .commit(role: :assistant, content: text("hello"))

      lineage = described_class.new(journal_turns(turn)).lineage(turn.head_digest).to_a

      expect(lineage.last).to eq(turn.to_a.first.digest)
    end
  end

  # Mutation hazard: the real production path (Journal.records(File.foreach(path)))
  # parses records with JSON.parse, which freezes NOTHING -- unlike the in-memory
  # Turn#content path, which is already deeply frozen via Canonical.normalize.
  # #calls is memoized, so every reader shares the same Call objects; a caller
  # mutating one Call's args or result in place would leak into every later read.
  describe "Call fields are deeply frozen regardless of source (mutation hazard)" do
    it "freezes args and result even when built from unfrozen, JSON-sourced records" do
      call_turn = Lain::Timeline.empty(store:)
                                .commit(role: :user, content: text("please echo"))
                                .commit(role: :assistant, content: [tool_use("tu_1", "echo", { "text" => "hi" })])
      result_turn = call_turn.commit(role: :user, content: [tool_result("tu_1", "hi")])

      # A JSON round-trip, the same transformation a real journal file's bytes
      # go through: JSON.parse hands back plain, mutable Hashes and Strings.
      json_entries = journal_turns(result_turn).map { |record| JSON.parse(JSON.generate(record)) }
      call = described_class.new(json_entries).calls.fetch(call_turn.head_digest).first

      expect(call.args).to be_frozen
      expect(call.result).to be_frozen
      expect { call.args["text"] << "!" }.to raise_error(FrozenError)
      expect { call.result << "!" }.to raise_error(FrozenError)
    end
  end

  # Orchestrator decision: a dangling predecessor RAISES loudly rather than
  # silently reading as a shorter-but-real root -- {Bench::Session::Corrupt}'s
  # precedent, applied to lineage instead of the digest chain. An outcome-lineage
  # walk needs to trust that a nil predecessor means "genuine root," never "the
  # journal slice this index was built from is missing a record."
  describe "a dangling predecessor (partial or corrupted journal slice)" do
    it "resolves a clean, complete chain to its root without raising" do
      chain = Lain::Timeline.empty(store:)
                            .commit(role: :user, content: text("hi"))
                            .commit(role: :assistant, content: text("hello"))
                            .commit(role: :user, content: text("thanks"))

      index = described_class.new(journal_turns(chain))
      lineage = nil

      expect { lineage = index.lineage(chain.head_digest).to_a }.not_to raise_error
      expect(lineage.last).to eq(chain.to_a.first.digest)
    end

    # A file that resumes nothing continues no other file's chain: its
    # `rewound` records name turns it wrote, so a missing one is a hole.
    it "raises for a missing turn a rewound record names, when the slice resumes from no file" do
      chain = Lain::Timeline.empty(store:)
                            .commit(role: :user, content: text("hi"))
                            .commit(role: :assistant, content: text("hello"))
                            .commit(role: :user, content: text("thanks"))
      missing_digest = chain.rewind.head_digest
      entries = journal_turns(chain).reject { |record| record.fetch("digest") == missing_digest } +
                [Lain::SessionRecord.rewound(from: chain.head_digest, to: missing_digest)]

      expect { described_class.new(entries).lineage(chain.head_digest).to_a }
        .to raise_error(Lain::Error, /#{Regexp.escape(missing_digest)}/)
    end

    it "raises naming the missing digest when a predecessor is absent from the entry set" do
      chain = Lain::Timeline.empty(store:)
                            .commit(role: :user, content: text("hi"))
                            .commit(role: :assistant, content: text("hello"))
                            .commit(role: :user, content: text("thanks"))
      # Drop the middle turn: the tail turn's `parent` still names it, but no
      # record for it is in this entry set -- a partial slice, not a shorter
      # real chain.
      missing_digest = chain.rewind.head_digest
      entries = journal_turns(chain).reject { |record| record.fetch("digest") == missing_digest }

      expect { described_class.new(entries).lineage(chain.head_digest).to_a }
        .to raise_error(Lain::Error, /#{Regexp.escape(missing_digest)}/)
    end
  end
end
