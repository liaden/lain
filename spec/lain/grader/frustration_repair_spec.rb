# frozen_string_literal: true

require "json"

# Built on the shared {Grader::ToolCallIndex} substrate. The
# `spec/fixtures/grader/frustration/*.ndjson` fixtures are REAL `turn`
# records -- genuine content-addressed digests, generated once through a
# live Timeline (the same recipe spec/fixtures/sessions/*_v1 used) rather
# than hand-authored, since a turn's digest cannot be guessed. Each
# `*.digests.json` sidecar names the fixture's turn-of-interest digests so
# the spec never has to recompute or hardcode a blake3 hash by hand.
RSpec.describe Lain::Grader::FrustrationRepair do
  let(:fixture_dir) { File.expand_path("../../fixtures/grader/frustration", __dir__) }

  def fixture_entries(name)
    Lain::Journal.records(File.foreach(File.join(fixture_dir, "#{name}.ndjson"))).to_a
  end

  def fixture_digests(name)
    JSON.parse(File.read(File.join(fixture_dir, "#{name}.digests.json")))
  end

  def text(body) = [{ "type" => "text", "text" => body }]
  def tool_use(id, name, input) = { "type" => "tool_use", "id" => id, "name" => name, "input" => input }

  def tool_result(id, content, is_error: false)
    { "type" => "tool_result", "tool_use_id" => id, "content" => content, "is_error" => is_error }
  end

  def journal_turns(timeline)
    timeline.to_a.map { |turn| Lain::SessionRecord.turn(turn) }
  end

  describe "a downstream signal attributed to its upstream cause (Gherkin AC)" do
    # Given a fixture where a tool failure at turn i produces a rephrase-loop
    # at turn i+k, with a DECOY tool call (a different, succeeding tool)
    # sitting in between -- so a naive "nearest prior turn" attribution would
    # land on the decoy, not the real cause.
    let(:entries) { fixture_entries("rephrase_loop") }
    let(:digests) { fixture_digests("rephrase_loop") }

    it "reports the signal at i+k and attributes it to turn i via causal lineage" do
      found = described_class.new.signals(entries)

      expect(found.size).to eq(1)
      expect(found.first.turn_digest).to eq(digests.fetch("turn_ik"))
      expect(found.first.caused_by).to eq([digests.fetch("turn_i")])
    end

    it "is not merely the nearest prior turn -- the decoy tool call in between is skipped" do
      decoy_digest = entries.find { |record| record["content"]&.any? { |b| b["name"] == "web_search" } }
                            &.fetch("digest")

      found = described_class.new.signals(entries)

      expect(decoy_digest).not_to be_nil
      expect(found.first.caused_by).not_to include(decoy_digest)
      expect(found.first.caused_by).to eq([digests.fetch("turn_i")])
    end

    it "is deterministic -- the same entries grade to the same signals every time" do
      grader = described_class.new

      expect(grader.signals(entries)).to eq(grader.signals(entries))
    end

    it "grades an unrepaired loop below a pass (the retry errored again too)" do
      grade = described_class.new.grade(entries)

      expect(grade.pass?).to be(false)
      expect(grade.score).to eq(0.0)
      expect(grade.why).to include("1 frustration signal", "0 repaired")
    end
  end

  describe "a rephrase-loop whose retry succeeds" do
    let(:entries) { fixture_entries("rephrase_loop_repaired") }
    let(:digests) { fixture_digests("rephrase_loop_repaired") }

    it "still reports the loop (the frustration happened) but marks it repaired" do
      found = described_class.new.signals(entries)

      expect(found.size).to eq(1)
      expect(found.first.turn_digest).to eq(digests.fetch("turn_ik"))
      expect(found.first.caused_by).to eq([digests.fetch("turn_i")])
      expect(found.first.repaired).to be(true)
    end

    it "grades a fully repaired run as a clean pass" do
      grade = described_class.new.grade(entries)

      expect(grade.pass?).to be(true)
      expect(grade.score).to eq(1.0)
    end
  end

  describe "a run with no frustration signals" do
    it "grades a clean pass rather than a zero -- nothing went wrong is not a failure" do
      store = Lain::Store.new
      clean = Lain::Timeline.empty(store:)
                            .commit(role: :user, content: text("hi"))
                            .commit(role: :assistant, content: text("hello"))

      grade = described_class.new.grade(journal_turns(clean))

      expect(described_class.new.signals(journal_turns(clean))).to eq([])
      expect(grade.score).to eq(1.0)
      expect(grade.pass?).to be(true)
      expect(grade.why).to eq("no frustration signals")
    end
  end

  describe "a repeat whose prior use SUCCEEDED (legitimate reuse, not a loop)" do
    it "does not flag ordinary reuse of a tool that already worked" do
      store = Lain::Store.new
      timeline = Lain::Timeline.empty(store:)
                               .commit(role: :user, content: text("look up two drugs"))
                               .commit(role: :assistant, content: [tool_use("tu_1", "dosing_lookup",
                                                                            { "drug" => "aspirin" })])
                               .commit(role: :user, content: [tool_result("tu_1", "325-650mg")])
                               .commit(role: :assistant, content: [tool_use("tu_2", "dosing_lookup",
                                                                            { "drug" => "ibuprofen" })])
                               .commit(role: :user, content: [tool_result("tu_2", "200-400mg")])

      expect(described_class.new.signals(journal_turns(timeline))).to eq([])
    end

    it "gates a fuzzy signal behind the injected oracle -- Null by default finds nothing" do
      store = Lain::Store.new
      timeline = Lain::Timeline.empty(store:)
                               .commit(role: :user, content: text("look up a drug twice"))
                               .commit(role: :assistant, content: [tool_use("tu_1", "dosing_lookup",
                                                                            { "drug" => "aspirin" })])
                               .commit(role: :user, content: [tool_result("tu_1", "not the dose I meant")])
                               .commit(role: :assistant, content: [tool_use("tu_2", "dosing_lookup",
                                                                            { "drug" => "aspirin" })])
                               .commit(role: :user, content: [tool_result("tu_2", "not the dose I meant either")])
      entries = journal_turns(timeline)

      expect(described_class.new.signals(entries)).to eq([])

      fuzzy_oracle = Class.new { def frustrated?(_prior, _next) = true }.new
      with_oracle = described_class.new(oracle: fuzzy_oracle).signals(entries)

      expect(with_oracle.size).to eq(1)
      expect(with_oracle.first.source).to eq(:oracle)
    end
  end

  # Across a spawn, over the records a chat actually writes: a real Scribe
  # observing a real spawn, so the child's turns are `child_turn` records under
  # a `:spawn` and never `turn` records carrying lineage in their meta.
  describe "attribution across a recorded spawn" do
    def digest_of(records, &) = records.find(&).fetch("digest")

    def calls?(record, name)
      Array(record["content"] || record.dig("payload", "content")).any? do |block|
        block["type"] == "tool_use" && block["name"] == name
      end
    end

    it "attributes a child's repeat of a failing call to the parent turn that spawned it" do
      session = RecordedSpawnSession.new(
        tools: [BoomTool.new], child_tools: [BoomTool.new],
        parent_responses: [tool_response(["tu_b1", "boom", {}], ["tu_s", "subagent", { "prompt" => "try boom" }]),
                           text_response("parent done")],
        child_responses: [tool_response(["tu_c1", "boom", {}]), text_response("child gave up")]
      ).run
      spawning = digest_of(session.of_type("turn")) { |record| calls?(record, "subagent") }
      repeat = digest_of(session.of_type(Lain::SessionRecord::CHILD_TURN_TYPE)) { |record| calls?(record, "boom") }

      found = described_class.new.signals(session.records)

      expect(found.map(&:turn_digest)).to eq([repeat])
      expect(found.first.caused_by).to eq([spawning])
    end

    it "attributes a parent's retry to its own earlier failure, not to the child turns in between" do
      session = RecordedSpawnSession.new(
        tools: [BoomTool.new], child_tools: [BoomTool.new],
        parent_responses: [tool_response(["tu_b1", "boom", {}]),
                           tool_response(["tu_s", "subagent", { "prompt" => "child task" }]),
                           tool_response(["tu_b2", "boom", {}]), text_response("parent done")],
        child_responses: [tool_response(["tu_c1", "boom", {}]), text_response("child done")]
      ).run
      parent_booms = session.of_type("turn").select { |record| calls?(record, "boom") }.map { |r| r.fetch("digest") }

      signal = described_class.new.signals(session.records).find { |found| found.turn_digest == parent_booms.last }

      expect(signal.caused_by).to eq([parent_booms.first])
    end
  end

  # A caller folding several graders over ONE record array
  # (Friction::Report) already holds the projection they share, so it can hand
  # it in rather than pay for a second parse of the same in-memory records.
  describe "an injected ToolCallIndex" do
    it "detects from the injected index instead of building its own" do
      entries = fixture_entries("rephrase_loop")
      injected = Lain::Grader::ToolCallIndex.new(entries)
      allow(Lain::Grader::ToolCallIndex).to receive(:new).and_call_original

      found = described_class.new.signals(entries, tool_call_index: injected)

      expect(found.map(&:turn_digest)).to eq([fixture_digests("rephrase_loop").fetch("turn_ik")])
      expect(Lain::Grader::ToolCallIndex).not_to have_received(:new)
    end

    it "builds its own when none is injected" do
      expect(described_class.new.signals(fixture_entries("rephrase_loop")).size).to eq(1)
    end
  end

  describe "Signal#caused_by is always an Array (multi-element attribution contract)" do
    it "never answers a bare digest, even when exactly one cause was found" do
      entries = fixture_entries("rephrase_loop")

      described_class.new.signals(entries).each do |signal|
        expect(signal.caused_by).to be_an(Array)
      end
    end
  end

  # Mutation hazard, the same one the ToolCallIndex spec guards: entries
  # loaded from a real journal file arrive via plain JSON.parse, which freezes
  # NOTHING -- only a String used as a Hash KEY is auto-frozen by Ruby, and a
  # lineage digest is a VALUE. A Signal built from unfrozen input must still
  # come out deeply frozen, or `Ractor.shareable?` (this project's mechanical
  # statement of "no reachable mutable state") silently breaks.
  describe "Signal is deeply frozen regardless of source (mutation hazard)" do
    it "is Ractor.shareable? even when built from unfrozen, JSON-sourced entries" do
      signal = described_class.new.signals(fixture_entries("rephrase_loop")).first

      expect(signal).to be_deeply_frozen
    end
  end
end
