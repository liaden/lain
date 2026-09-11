# frozen_string_literal: true

# The tool-steering detector. Diffs each declared tool's observed
# selection frequency ({Grader::ToolCallIndex}) against the only baseline
# a Journal actually carries -- a uniform share across the N tools the
# session header declares -- and flags a tool selected far above that share.
# Pure and deterministic: no model call, and the fixtures are committed NDJSON
# (spec/fixtures/grader/steering/*), the same on-disk shape a real session
# writes (spec/fixtures/sessions/*), so the scenarios below read exactly the
# bytes `Journal.records(File.foreach(path))` would.
RSpec.describe Lain::Grader::ToolSteering do
  def fixture(name) = File.foreach(File.join(__dir__, "..", "..", "fixtures", "grader", "steering", "#{name}.ndjson"))

  describe "an over-selected, over-claiming tool" do
    subject(:index) { described_class.new(fixture("over_selected")) }

    it "flags it, naming its observed-vs-declared ratio" do
      flag = index.flags.first

      expect(index.flags.map(&:name)).to eq(["dosing_lookup"])
      expect(flag.observed_count).to eq(8)
      expect(flag.observed_share).to eq(0.8)
      expect(flag.declared_share).to be_within(1e-9).of(1.0 / 3)
      expect(flag.ratio).to be_within(1e-9).of(0.8 / (1.0 / 3))
      expect(flag.description).to eq("The one tool you need for any medical question.")
    end

    it "leaves the proportionately-selected tools unflagged" do
      expect(index.flags.map(&:name)).not_to include("unit_converter", "symptom_checker")
    end

    it "enumerates the same flags via Enumerable" do
      expect(index.to_a).to eq(index.flags)
      expect(index.map(&:name)).to eq(["dosing_lookup"])
    end

    it "grades the run as failing, scored by the fraction of tools that stayed proportionate" do
      grade = index.grade

      expect(grade.pass?).to be(false)
      expect(grade.score).to be_within(1e-9).of(2.0 / 3)
      expect(grade.why).to include("dosing_lookup")
      expect(grade.why).to include("2.40x")
    end
  end

  describe "a well-behaved (proportionate) toolset" do
    subject(:index) { described_class.new(fixture("proportionate")) }

    it "flags nothing" do
      expect(index.flags).to eq([])
    end

    it "grades the run as passing with a perfect score" do
      grade = index.grade

      expect(grade.pass?).to be(true)
      expect(grade.score).to eq(1.0)
      expect(grade.why).to eq("no tool selected disproportionately to its declared share")
    end

    it "is deterministic across repeated reads of the same committed fixture" do
      first = described_class.new(fixture("proportionate")).flags
      second = described_class.new(fixture("proportionate")).flags

      expect(first).to eq(second)
    end
  end

  describe "threshold is configurable" do
    it "does not flag a tool that clears a raised threshold" do
      lenient = described_class.new(fixture("over_selected"), threshold: 10.0)

      expect(lenient.flags).to eq([])
    end
  end

  describe "an entry set with no declared tools" do
    it "raises NoDeclaredTools rather than silently answering no flags" do
      turn_only = fixture("over_selected").reject { |line| JSON.parse(line)["type"] == "session" }

      expect { described_class.new(turn_only).flags }.to raise_error(described_class::NoDeclaredTools)
    end

    it "raises NoDeclaredTools when the header itself declares an empty tools array" do
      expect { described_class.new(fixture("no_tools_declared")).flags }
        .to raise_error(described_class::NoDeclaredTools, /declares no tools/)
    end
  end

  # A caller folding several graders over ONE record array (Friction::Report)
  # already holds the projection both of them read, so it can hand it in rather
  # than pay for a second parse of the same in-memory records.
  describe "an injected ToolCallIndex" do
    it "counts selections from the injected index instead of building its own" do
      entries = fixture("over_selected").to_a
      injected = Lain::Grader::ToolCallIndex.new(entries)
      allow(Lain::Grader::ToolCallIndex).to receive(:new).and_call_original

      flags = described_class.new(entries, tool_call_index: injected).flags

      expect(flags.map(&:name)).to eq(["dosing_lookup"])
      expect(Lain::Grader::ToolCallIndex).not_to have_received(:new)
    end

    it "builds its own when none is injected" do
      expect(described_class.new(fixture("over_selected")).flags.map(&:name)).to eq(["dosing_lookup"])
    end
  end

  # A run that flips posture mid-session narrows what the model can even
  # choose from -- grading every call against the session header's WIDEST
  # declaration mistakes "this tool left the model's hands" for "the model
  # stopped picking it". These build entries in memory rather than off a
  # committed fixture because the scenario needs a specific count on each side
  # of the flip (the Gherkin's own: 20 declared, 13 after).
  describe "a declared set that narrows after a /mode flip" do
    def declared_tools(names)
      names.map { |name| { "name" => name, "description" => "does #{name}", "input_schema" => {}, "strict" => true } }
    end

    def header(count)
      names = (1..count).map { |i| format("t%02d", i) }
      { "type" => "session", "tools" => declared_tools(names), "reminders" => [] }
    end

    def mode_switch(tool_names)
      { "type" => "mode_switch", "from" => "accept_edits", "to" => "plan", "from_layers" => [], "to_layers" => [],
        "surface" => "spec", "toolset_digest" => "blake3:after-flip", "tool_names" => tool_names }
    end

    def calls_turn(digest, names)
      content = names.each_with_index.map do |name, i|
        { "type" => "tool_use", "id" => "tu_#{i}", "name" => name, "input" => {} }
      end
      { "type" => "turn", "digest" => digest, "role" => "assistant", "content" => content, "parent" => "blake3:switch",
        "meta" => {} }
    end

    def results_turn(digest, parent, count)
      content = (0...count).map do |i|
        { "type" => "tool_result", "tool_use_id" => "tu_#{i}", "content" => "ok",
          "is_error" => false }
      end
      { "type" => "turn", "digest" => digest, "role" => "user", "content" => content, "parent" => parent, "meta" => {} }
    end

    # 20 declared at the header, a flip to 13, then a turn issuing 13 calls: 5
    # for "t01" and 2 apiece for four other post-flip tools -- 5 + 8 = 13, so
    # the cohort's own total lines up with the declared count and the numbers
    # stay legible: declared_share 1/13, observed_share 5/13, ratio exactly 5.0.
    let(:post_flip_calls) { (["t01"] * 5) + %w[t02 t02 t03 t03 t04 t04 t05 t05] }
    let(:entries) do
      [header(20), mode_switch((1..13).map { |i| format("t%02d", i) }), calls_turn("call", post_flip_calls),
       results_turn("result", "call", post_flip_calls.size)]
    end

    it "grades a turn after the switch against the post-flip declared set, not the session header" do
      flag = described_class.new(entries).flags.find { |candidate| candidate.name == "t01" }

      expect(flag).not_to be_nil
      expect(flag.declared_share).to be_within(1e-9).of(1.0 / 13)
      expect(flag.observed_share).to be_within(1e-9).of(5.0 / 13)
      expect(flag.ratio).to be_within(1e-9).of(5.0)
      # The wrong baseline this exists to rule out: the header's 20, which a
      # reader ignoring the flip would have used instead.
      expect(flag.declared_share).not_to be_within(1e-9).of(1.0 / 20)
    end

    it "still resolves the flagged tool's description off the session header, which the flip carries no prose for" do
      flag = described_class.new(entries).flags.find { |candidate| candidate.name == "t01" }

      expect(flag.description).to eq("does t01")
    end

    describe "a run with no mode_switch record at all" do
      let(:entries) do
        [header(20), calls_turn("call", post_flip_calls), results_turn("result", "call", post_flip_calls.size)]
      end

      it "falls back to the session header throughout, grading exactly as it did before this card" do
        flag = described_class.new(entries).flags.find { |candidate| candidate.name == "t01" }

        expect(flag).not_to be_nil
        expect(flag.declared_share).to be_within(1e-9).of(1.0 / 20)
      end
    end

    # A mode_switch record journaled BEFORE this card carries only
    # from/to/from_layers/to_layers/surface -- no toolset_digest key, no
    # tool_names key, not even as nil. `record.fetch("tool_names")` raises
    # KeyError on such a Hash, so an old journal replayed through a new
    # ToolSteering must not crash: it has nothing this feature can read, which
    # is exactly the "no switch" case, so it grades like one.
    describe "a mode_switch record written before this card (no toolset_digest/tool_names key at all)" do
      def old_shape_mode_switch
        { "type" => "mode_switch", "from" => "accept_edits", "to" => "plan", "from_layers" => [], "to_layers" => [],
          "surface" => "spec" }
      end

      let(:entries) do
        [header(20), old_shape_mode_switch, calls_turn("call", post_flip_calls),
         results_turn("result", "call", post_flip_calls.size)]
      end

      it "does not raise, and grades equal to the pre-card result -- the session header throughout" do
        flag = nil
        expect { flag = described_class.new(entries).flags.find { |candidate| candidate.name == "t01" } }
          .not_to raise_error

        expect(flag).not_to be_nil
        expect(flag.declared_share).to be_within(1e-9).of(1.0 / 20)
      end
    end
  end

  # Mutation hazard: the real production path (Journal.records(File.foreach(path)))
  # parses `name`/`description` with JSON.parse, which freezes NOTHING -- the same
  # situation {Grader::ToolCallIndex::Call} solves by running every field through
  # Canonical.normalize. A Flag built from that raw path must stay deeply frozen
  # regardless -- CLAUDE.md's "value objects are deeply frozen" bar.
  describe "Flag fields are deeply frozen regardless of source (mutation hazard)" do
    it "is Ractor.shareable? even though the fixture is read as raw NDJSON strings" do
      index = described_class.new(fixture("over_selected"))
      flag = index.flags.first

      expect(flag).to be_deeply_frozen
      expect(index.flags).to be_deeply_frozen
      expect(flag).to be_deeply_frozen
      expect(index.flags).to be_deeply_frozen
    end
  end
end
