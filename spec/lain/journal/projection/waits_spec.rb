# frozen_string_literal: true

RSpec.describe Lain::Journal::Projection::Waits do
  wait = described_class::Wait
  main = described_class::MAIN
  child = "blake3:#{"c" * 64}"

  # Each closing record in this file reads back as Untyped, as a reader of a closed file steps it.
  fixture = File.join(__dir__, "../../../fixtures/waits/closing_records.ndjson")
  read = -> { File.readlines(fixture).map { |line| Lain::Telemetry.read(JSON.parse(line), strict: false) } }

  approval_park = lambda do |tool_use_id, spawn: nil|
    Lain::Telemetry::AwaitingHuman.new(kind: "approval", ref: tool_use_id, summary: "bash", requester: "agent",
                                       tool: "bash", tool_use_id:, spawn:)
  end
  decision = lambda do |tool_use_id|
    effect = Lain::Effect::ToolCall.new(tool_use_id:, name: "bash", input: {})
    pending = Lain::Approval::Parked::Queue::Pending.new(effect:, identity: Lain::Requester.main, clock: -> { 0.0 })
    pending.decide(Lain::Approval::Verdict::Approve.new, surface: "tty")
    pending
  end
  gate_wait = lambda do |ref, deferred: false|
    Lain::Telemetry::AwaitingHuman.new(kind: "gate", ref:, summary: "Approve the plan?", deferred:)
  end
  gate_decision = lambda do |ref, verdict|
    Lain::Epic::GateDecision.new(artifact_digest: ref, epic_slug: "alpha", stage: "research", verdict:,
                                 answered_by: "human", policy: "interactive", latency: 1.0)
  end
  degraded = lambda do |entry_class|
    { "type" => "journal_error", "error" => "IOError: closed stream", "entry_class" => entry_class.name }
  end

  describe "the laws" do
    include_examples "an incremental fold", projection: described_class, population: -> { [read.call] }
  end

  describe "closing records read back from a file" do
    it "reads every closing record as Untyped" do
      closers = read.call.grep_v(Lain::Telemetry::AwaitingHuman)

      expect(closers.map(&:class).uniq).to eq([Lain::Telemetry::Untyped])
    end

    it "closes every wait the file opened" do
      records = read.call
      opened = records.grep(Lain::Telemetry::AwaitingHuman)

      expect([described_class.over(opened).open.size, described_class.over(records).open])
        .to eq([3, []])
    end

    it "leaves a held gate open when its decision is read back from a file" do
      held = gate_decision.call("blake3:held", Lain::Approval::Verdict::Hold.new(note: "after lunch"))
      untyped = Lain::Telemetry.read(JSON.parse(JSON.generate(held.to_journal)), strict: false)

      expect(described_class.over([gate_wait.call("blake3:held"), untyped]).open.map(&:ref)).to eq(["blake3:held"])
    end

    it "counts a degraded park read back from a file" do
      untyped = Lain::Telemetry::Untyped.new(fields: degraded.call(Lain::Telemetry::AwaitingHuman))

      expect(described_class.over([untyped]).approvals_pending).to eq(1)
    end
  end

  describe "#open" do
    it "names each wait's ref, kind, agent and summary" do
      question = Lain::Telemetry::AwaitingHuman.new(kind: "question", ref: "blake3:q", summary: "Which?", spawn: child)

      expect(described_class.over([approval_park.call("tu_1"), question]).open)
        .to eq([wait.new(ref: "tu_1", kind: "approval", agent: main, summary: "bash"),
                wait.new(ref: "blake3:q", kind: "question", agent: child, summary: "Which?")])
    end

    it "keeps a held gate open and opens a deferred gate" do
      waits = described_class.over([gate_wait.call("blake3:held"),
                                    gate_decision.call("blake3:held", Lain::Approval::Verdict::Hold.new(note: "later")),
                                    gate_wait.call("blake3:deferred", deferred: true)])

      expect(waits.open.map(&:ref)).to eq(%w[blake3:held blake3:deferred])
    end

    it "lists a wave's waits as the one question they share" do
      wave = %w[b c].map do |id|
        Lain::Telemetry::AwaitingHuman.new(kind: "gate", ref: "blake3:#{id}", summary: "Approve the wave?",
                                           question_key: "blake3:wave")
      end

      expect(described_class.over(wave).open)
        .to eq([wait.new(ref: "blake3:wave", kind: "gate", agent: main, summary: "Approve the wave?")])
    end

    it "lists an approval by its tool_use_id, never by a question key it carries" do
      park = Lain::Telemetry::AwaitingHuman.new(kind: "approval", ref: "tu_1", summary: "bash", requester: "agent",
                                                tool: "bash", tool_use_id: "tu_1", question_key: "blake3:wave")

      expect(described_class.over([park]).open.map(&:ref)).to eq(["tu_1"])
    end

    it "replaces a deferred gate with a live ask for the same artifact, naming the new agent and summary" do
      live = Lain::Telemetry::AwaitingHuman.new(kind: "gate", ref: "blake3:plan", summary: "Approve the rework?",
                                                spawn: child)
      waits = described_class.over([gate_wait.call("blake3:plan", deferred: true), live])

      expect([waits.open, waits.waiting])
        .to eq([[wait.new(ref: "blake3:plan", kind: "gate", agent: child, summary: "Approve the rework?")], 1])
    end

    it "keeps a wave's count when a deferred park lands on it, so the last live decision still closes it" do
      wave = %w[b c].map do |id|
        Lain::Telemetry::AwaitingHuman.new(kind: "gate", ref: "blake3:#{id}", summary: "Approve the wave?",
                                           question_key: "blake3:wave", deferred: id == "c")
      end
      waits = described_class.over([*wave, gate_decision.call("blake3:b", Lain::Approval::Verdict::Approve.new)])

      expect([waits.open, waits.waiting]).to eq([[], 0])
    end

    it "closes a live wave on its decisions though a deferred gate holds one of its refs" do
      in_wave = lambda do |ref|
        Lain::Telemetry::AwaitingHuman.new(kind: "gate", ref:, summary: "Approve the wave?",
                                           question_key: "blake3:wave")
      end
      approve = Lain::Approval::Verdict::Approve.new
      waits = described_class.over([gate_wait.call("blake3:x", deferred: true), in_wave.call("blake3:x"),
                                    in_wave.call("blake3:y"), gate_decision.call("blake3:x", approve),
                                    gate_decision.call("blake3:y", approve)])

      expect([waits.open, waits.waiting]).to eq([[], 0])
    end

    it "puts a live ask that replaces a deferred one after the asks opened since" do
      in_wave = lambda do |ref|
        Lain::Telemetry::AwaitingHuman.new(kind: "gate", ref:, summary: "Approve the wave?",
                                           question_key: "blake3:wave")
      end
      waits = described_class.over([gate_wait.call("blake3:x", deferred: true), in_wave.call("blake3:x"),
                                    in_wave.call("blake3:y"), gate_wait.call("blake3:x"),
                                    gate_decision.call("blake3:x", Lain::Approval::Verdict::Approve.new)])

      expect(waits.waiting).to eq(2)
    end

    it "releases the approval its decision names" do
      waits = described_class.over([approval_park.call("tu_1"), approval_park.call("tu_2"), decision.call("tu_2")])

      expect(waits.open.map(&:ref)).to eq(["tu_1"])
    end
  end

  describe "#open_for" do
    it "answers only the agent's own waits" do
      waits = described_class.over([approval_park.call("tu_1"), approval_park.call("tu_2", spawn: child)])

      expect([waits.open_for(child).map(&:ref), waits.open_for(main).map(&:ref)]).to eq([["tu_2"], ["tu_1"]])
    end
  end

  describe "the counts the status feed publishes" do
    it "leaves a deferred gate out of the waiting count" do
      waits = described_class.over([gate_wait.call("blake3:plan", deferred: true)])

      expect([waits.waiting, waits.approvals_pending]).to eq([0, 0])
    end

    it "releases a degraded park before the oldest approval for a decision naming none it holds" do
      degraded_park = Lain::Telemetry::Untyped.new(fields: degraded.call(Lain::Telemetry::AwaitingHuman))
      waits = described_class.over([approval_park.call("tu_1"), degraded_park, decision.call("tu_other")])

      expect([waits.approvals_pending, waits.open.map(&:ref)]).to eq([1, ["tu_1"]])
    end

    it "releases one approval for a decision naming none it holds, and never goes below zero" do
      waits = described_class.over([approval_park.call("tu_1"), decision.call("tu_other"), decision.call("tu_x")])

      expect([waits.approvals_pending, waits.open]).to eq([0, []])
    end
  end
end
