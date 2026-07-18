# frozen_string_literal: true

# T8: the shared substrate GR-2 (T10, selection frequency) and GR-3 (T11,
# outcome-lineage walks) both read from -- an offline projection over a
# Journal's turn records pairing each tool_use with its outcome. No
# production writer emits a standalone `tool_result` RECORD (only
# `tool_use`/`tool_result` content BLOCKS inside `turn` records), so this
# generalizes {Lain::Bench::Session::MemoryReplay#outcomes}'s pairing recipe
# from "memory_write, is_error only" to "any tool, full outcome".
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
      expect(call.is_error).to eq(false)
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

      expect(call.is_error).to eq(true)
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

    it "omits a turn with no tool_use from #calls entirely" do
      turn = Lain::Timeline.empty(store:).commit(role: :user, content: text("just chatting"))

      expect(described_class.new(journal_turns(turn)).calls).to eq({})
    end

    it "enumerates every paired call flat via #each, the fold GR-2's selection frequency wants" do
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

  describe "lineage across a spawned_from fan-out" do
    it "resolves a child chain's outcome back to its causing turn via causal lineage" do
      parent_chain = Lain::Timeline.empty(store:).commit(role: :user, content: text("do the big task"))
      spawn_turn = parent_chain.commit(role: :assistant,
                                       content: [tool_use("tu_spawn", "subagent", { "prompt" => "child task" })])

      child_root = Lain::Timeline.empty(store:)
                                 .commit(role: :user, content: text("child task"),
                                         meta: { "spawned_from" => spawn_turn.head_digest })
      child_call_turn = child_root.commit(role: :assistant, content: [tool_use("tu_1", "echo", { "text" => "hi" })])
      child_result_turn = child_call_turn.commit(role: :user, content: [tool_result("tu_1", "hi")])

      spawn_result_turn = spawn_turn.commit(role: :user, content: [tool_result("tu_spawn", "spawned")])

      entries = journal_turns(spawn_result_turn) + journal_turns(child_result_turn)
      index = described_class.new(entries)

      lineage = index.lineage(child_call_turn.head_digest).to_a

      expect(lineage).to eq([child_call_turn.head_digest, child_root.head_digest,
                             spawn_turn.head_digest, parent_chain.head_digest])
    end

    it "agrees no matter how the parent and child chains were interleaved on disk" do
      parent_chain = Lain::Timeline.empty(store:).commit(role: :user, content: text("do the big task"))
      spawn_turn = parent_chain.commit(role: :assistant,
                                       content: [tool_use("tu_spawn", "subagent", { "prompt" => "child task" })])
      child_root = Lain::Timeline.empty(store:)
                                 .commit(role: :user, content: text("child task"),
                                         meta: { "spawned_from" => spawn_turn.head_digest })

      entries = journal_turns(spawn_turn) + journal_turns(child_root)
      ordered = described_class.new(entries)
      shuffled = described_class.new(entries.reverse)

      expect(ordered.lineage(child_root.head_digest).to_a).to eq(shuffled.lineage(child_root.head_digest).to_a)
    end

    it "stops at a chain root with no spawned_from meta -- an ordinary (non-subagent) chain" do
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
  # precedent, applied to lineage instead of the digest chain. GR-3 (T11) needs
  # to trust that a nil predecessor means "genuine root," never "the journal
  # slice this index was built from is missing a record."
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

    it "raises DanglingLineage naming the missing digest when a predecessor is absent from the entry set" do
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
        .to raise_error(described_class::DanglingLineage, /#{Regexp.escape(missing_digest)}/)
    end
  end
end
