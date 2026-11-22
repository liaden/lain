# frozen_string_literal: true

require "json"

RSpec.describe Lain::Telemetry::AwaitingHuman do
  def approval(**fields)
    described_class.new(kind: "approval", ref: "tu_1", summary: "bash", requester: "agent", tool: "bash",
                        tool_use_id: "tu_1", **fields)
  end

  def parked(command: "rm -rf build", **options)
    Lain::Approval::Parked::Queue::Pending.new(
      effect: Lain::Effect::ToolCall.new(tool_use_id: "tu_1", name: "bash", input: { "command" => command }),
      identity: Lain::Requester.new(name: "the-agent"), clock: -> { 0.0 },
      wall: -> { Time.utc(2026, 11, 2, 9, 0, 0) }, timeout: 300, **options
    )
  end

  it "journals as awaiting_human naming its kind, its ref, its deadline and its summary" do
    record = described_class.new(kind: "gate", ref: "blake3:plan", deadline: "2026-11-02T09:15:00Z",
                                 summary: "Approve the plan?")

    expect(record.journal_type).to eq("awaiting_human")
    expect(record.to_journal).to eq("type" => "awaiting_human", "kind" => "gate", "ref" => "blake3:plan",
                                    "deadline" => "2026-11-02T09:15:00Z", "summary" => "Approve the plan?")
  end

  it "names the park it opens, which no other park of the same call shares" do
    record = described_class.approval(parked.bind(park: "park-1"))

    expect(record.to_journal).to include("park" => "park-1")
  end

  it "omits the park of a wait that is not an approval" do
    expect(described_class.new(kind: "gate", ref: "r", summary: "s").to_journal).not_to have_key("park")
  end

  it "journals a null deadline for a question, which waits on no clock" do
    record = described_class.new(kind: "question", ref: "blake3:q", summary: "Which branch?")

    expect(record.to_journal).to include("deadline" => nil)
  end

  it "rounds a part second of the window up, so a deadline never reads earlier than the clock that enforces it" do
    expect(described_class.deadline(299.4, from: Time.utc(2026, 11, 2, 9))).to eq("2026-11-02T09:05:00Z")
  end

  it "bounds a lead sentence to 120 characters" do
    lead = described_class.lead("#{"A" * 200}?")

    expect(lead.length).to eq(120)
    expect(lead).to end_with("...")
  end

  it "prints the question a wave's waits share" do
    record = described_class.new(kind: "gate", ref: "blake3:b", summary: "Approve?", question_key: "blake3:wave")

    expect(record.to_journal).to include("question_key" => "blake3:wave")
    expect(described_class.new(kind: "gate", ref: "r", summary: "s").to_journal).not_to have_key("question_key")
  end

  it "is deeply frozen and Ractor-shareable even when built from mutable Strings" do
    record = described_class.new(kind: +"approval", ref: +"tu_1", summary: +"bash", requester: +"agent",
                                 tool: +"bash", tool_use_id: +"tu_1", notes: [+"a note"])

    expect(record).to be_deeply_frozen
  end

  it "interns its strings, so equal records share their bytes" do
    one = approval(notes: [+"n"], input_digest: +"d")
    two = approval(notes: [+"n"], input_digest: +"d")

    expect(one).to eq(two)
    expect(one.ref).to equal(two.ref)
    expect(one.tool).to equal(two.tool)
    expect(one.notes.first).to equal(two.notes.first)
    expect(one.input_digest).to equal(two.input_digest)
  end

  it "refuses a kind outside approval, gate and question" do
    expect { described_class.new(kind: "tool", ref: "r", summary: "s") }.to raise_error(ArgumentError, /kind/)
  end

  it "refuses a record that names nothing to wait on or nothing to show" do
    expect { described_class.new(kind: "gate", ref: nil, summary: "s") }.to raise_error(ArgumentError, /ref/)
    expect { described_class.new(kind: "gate", ref: "r", summary: nil) }.to raise_error(ArgumentError, /summary/)
  end

  it "refuses an approval that names no requester, no tool or no call, nil or false" do
    expect { approval(requester: nil) }.to raise_error(ArgumentError, /requester must name who the call was asked for/)
    expect { approval(tool: false) }.to raise_error(ArgumentError, /tool must name the gated tool/)
    expect { approval(tool_use_id: nil) }.to raise_error(ArgumentError, /tool_use_id must name the gated call/)
  end

  it "journals humans_only as true only for exactly true" do
    expect(approval(humans_only: "yes").humans_only).to be(false)
  end

  it "still refuses an unknown keyword" do
    expect { approval(extra: 1) }.to raise_error(ArgumentError)
  end

  describe "journal lines, byte for byte" do
    it "omits every field still at its default after the four it always carries" do
      expect(JSON.generate(approval.to_journal)).to eq(
        '{"type":"awaiting_human","kind":"approval","ref":"tu_1","deadline":null,"summary":"bash",' \
        '"requester":"agent","tool":"bash","tool_use_id":"tu_1"}'
      )
    end

    it "prints a deferred gate's address" do
      record = described_class.new(kind: "gate", ref: "blake3:impl", summary: "q?", deferred: true, epic_slug: "alpha",
                                   stage: "implementation", issue_id: "a", sha: "8b6b677")

      expect(JSON.generate(record.to_journal)).to eq(
        '{"type":"awaiting_human","kind":"gate","ref":"blake3:impl","deadline":null,"summary":"q?",' \
        '"deferred":true,"epic_slug":"alpha","stage":"implementation","issue_id":"a","sha":"8b6b677"}'
      )
    end
  end

  describe "the spawn a wait is a child's" do
    it "journals the spawn digest after the fields it follows, and omits it for the main chat" do
      child = described_class.approval(parked(spawn: "blake3:child"))

      expect([child.spawn, child.to_journal["spawn"]]).to eq(%w[blake3:child blake3:child])
      expect(described_class.approval(parked).to_journal).not_to have_key("spawn")
    end

    it "reads a line with no spawn key as nil, every other field unchanged" do
      old = described_class.new(kind: "question", ref: "d", summary: "q?", requester: "reviewer")

      expect(old).to have_attributes(spawn: nil, requester: "reviewer", ref: "d")
      expect(old.to_journal).to eq("type" => "awaiting_human", "kind" => "question", "ref" => "d",
                                   "deadline" => nil, "summary" => "q?", "requester" => "reviewer")
    end
  end

  describe ".approval, from a parked Pending" do
    it "names the requester, the tool, the call and the moment the queue denies it unasked" do
      record = described_class.approval(parked)

      expect(record).to have_attributes(kind: "approval", ref: "tu_1", requester: "the-agent", tool: "bash",
                                        tool_use_id: "tu_1", humans_only: false,
                                        deadline: "2026-11-02T09:05:00Z")
      expect(record).to be_deeply_frozen
    end

    it "carries the digest of the parked call's input, and never the input" do
      journaled = described_class.approval(parked).to_journal

      expect(journaled).to include("input_digest" => Lain::Canonical.digest("command" => "rm -rf build"))
      expect(journaled).not_to have_key("input")
    end

    it "names the tool and the command in the summary" do
      expect(described_class.approval(parked(command: "cargo test --release")).summary)
        .to eq("bash cargo test --release")
    end

    it "masks a known value in the summary and still journals no input field" do
      mask = ->(text) { text.gsub("hunter2", "<redacted:1>") }
      journaled = described_class.approval(parked(command: "echo hunter2 done", mask:)).to_journal

      expect(journaled).to include("summary" => "bash echo <redacted:1> done")
      expect(journaled).not_to have_key("input")
    end

    it "cuts the summary at the notifier's limit" do
      summary = described_class.approval(parked(command: "echo #{"a" * 500}")).summary

      expect(summary.length).to eq(Lain::Frontend::TTY::TmuxMessage::LIMIT)
    end

    it "masks a value that straddles the limit before it cuts, so no prefix of it survives" do
      mask = ->(text) { text.gsub("hunter2xyz", "<redacted:1>") }
      summary = described_class.approval(parked(command: "#{"a" * 190}hunter2xyz", mask:)).summary

      expect(summary).not_to include("hunt")
    end

    it "carries the Pending's notes and who may decide it" do
      record = described_class.approval(parked(notes: ["cat is /bin/cat"], humans_only: true))

      expect(record.to_journal).to include("notes" => ["cat is /bin/cat"], "humans_only" => true)
    end

    it "names a decision's kind as its tool and its digest as the call" do
      decision = Lain::Approval::Parked::Queue::Decision.new(requester: "egress", kind: "egress", summary: "s",
                                                             digest: "b3_abc")
      pending = Lain::Approval::Parked::Queue::DecisionPending.new(
        decision:, identity: Lain::Requester.new(name: "egress"), clock: -> { 0.0 }
      )

      expect(described_class.approval(pending).to_journal)
        .to include("kind" => "approval", "tool" => "egress", "tool_use_id" => "b3_abc", "ref" => "b3_abc")
    end
  end
end
