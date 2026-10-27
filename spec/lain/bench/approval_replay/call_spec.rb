# frozen_string_literal: true

require "json"

RSpec.describe Lain::Bench::ApprovalReplay::Call do
  let(:fixtures) { ApprovalReplayFixtures::DIR }

  def records(name) = Lain::Journal.records(File.foreach(File.join(fixtures, "#{name}.ndjson"))).to_a

  def joined(name) = described_class.joined(records(name), session: name)

  def by_id(calls) = calls.to_h { [_1.tool_use_id, _1] }

  it "takes every call a rung ruled, once each, in the order the session ruled them" do
    expect(joined("ask").map(&:tool_use_id)).to eq(%w[tu_1 tu_2 tu_3 tu_4 tu_5 tu_6])
  end

  it "joins a call to its input in a main turn and in a child turn's payload" do
    calls = by_id(joined("ask"))

    expect(calls.fetch("tu_1")).to have_attributes(tool: "bash", input: { "command" => "pwd" },
                                                   requester: "agent", child: false)
    expect(calls.fetch("tu_5")).to have_attributes(tool: "bash", input: { "command" => "ls src" },
                                                   requester: "researcher", child: true)
  end

  it "keeps a ruled call with no tool_use block, reported as unjoined rather than dropped" do
    unjoined = by_id(joined("ask")).fetch("tu_6")

    expect(unjoined).not_to be_joined
    expect(unjoined).to have_attributes(tool: "bash", input: nil)
  end

  it "carries what the session recorded about the call" do
    calls = by_id(joined("ask"))

    expect(calls.fetch("tu_2").decisions).to eq(%w[approve deny])
    expect(calls.fetch("tu_3").decisions).to eq(["deny"])
    expect(calls.fetch("tu_1").landings).to eq("/usr/bin/pwd" => "/usr/lib/coreutils/pwd")
    expect(calls.fetch("tu_4").recorded).to include("rung" => "triage", "verdict" => "deny")
  end

  it "places a call where the session header says it ran" do
    expect(joined("ask").map(&:place).uniq)
      .to eq([Lain::Bench::ApprovalReplay::Place.new(cwd: "/home/user/project", root: "/home/user/project",
                                                     home: "/home/user")])
  end

  it "leaves a call unplaced when the header recorded no place" do
    expect(joined("auto").map(&:place).uniq).to eq([nil])
  end

  it "names the judge's recorded ruling and the digest of what it read" do
    judged = by_id(joined("auto")).fetch("tu_1").judged

    expect(judged).to include("rung" => "auto", "verdict" => "allow")
    expect(judged.fetch("prompt_digest")).to start_with("blake3:")
  end

  it "takes the last ruling that did not abstain as the one that decided, wherever the first one sat" do
    read = Lain::Effect::ToolCall.new(tool_use_id: "tu_1", name: "read_file", input: { "path" => ".env" })
    journal = []
    [Lain::Approval::Escalation::Ruling.allow(rung: "surfaces", because: "a person allowed the path"),
     Lain::Approval::Escalation::Ruling.abstain(rung: "rules", because: "no rule had an opinion"),
     Lain::Approval::Escalation::Ruling.deny(rung: "remembered", because: "a person refused the release")]
      .each { Lain::Telemetry::Escalation.write(journal, _1, read, nil) }
    turn = { "type" => "turn", "role" => "assistant",
             "content" => [{ "type" => "tool_use", "id" => "tu_1", "name" => "read_file", "input" => read.input }] }

    expect(described_class.joined([turn, *journal], session: "s").first.recorded)
      .to include("rung" => "remembered", "verdict" => "deny")
  end

  describe "a tool_use id two calls share" do
    # The shape a provider that mints its own ids leaves, as Ollama's `ollama-tool-<index>` does each turn.
    def collided = records("ask").map { Lain::Journal.parse(JSON.generate(_1).gsub(/"tu_[15]"/, '"ollama-tool-0"')) }

    it "keeps each call apart, joined to the block that made it" do
      calls = described_class.joined(collided, session: "ask")

      expect(calls.size).to eq(6)
      expect(calls.select { _1.tool_use_id == "ollama-tool-0" }.map { [_1.input, _1.child, _1.recorded["rung"]] })
        .to contain_exactly([{ "command" => "pwd" }, false, "rules"], [{ "command" => "ls src" }, true, "surfaces"])
    end

    it "carries each call's own resolution and answers" do
      shared = described_class.joined(collided, session: "ask").select { _1.tool_use_id == "ollama-tool-0" }

      expect(shared.map { [_1.landings.keys, _1.decisions] })
        .to contain_exactly([["/usr/bin/pwd"], []], [[], ["approve"]])
    end

    it "reports an id it cannot place a record under as ambiguous, keeping it" do
      ls = { "type" => "tool_use", "id" => "x", "name" => "bash", "input" => { "command" => "ls" } }
      both = [{ "type" => "turn", "role" => "assistant", "content" => [ls] },
              { "type" => "turn", "role" => "assistant", "content" => [ls] },
              { "type" => "escalation", "tool_use_id" => "x", "tool" => "bash", "rung" => "surfaces",
                "verdict" => "allow", "input_digest" => Lain::Effect.input_digest({ "command" => "ls" }) }]

      calls = described_class.joined(both, session: "s")

      expect(calls.map { [_1.tool_use_id, _1.ambiguous, _1.joined?] }).to eq([["x", true, false]])
    end
  end

  it "lands every program a stage ran, the wrappers it ran under included" do
    stages = [{ "name" => "ls", "resolved" => "/usr/bin/ls", "realpath" => "/usr/lib/ls",
                "wrappers" => [{ "name" => "env", "resolved" => "/usr/bin/env", "realpath" => "/usr/lib/env",
                                 "wrappers" => [] }] }]
    records = [{ "type" => "exec_resolution", "tool_use_id" => "tu_1", "stages" => stages },
               { "type" => "escalation", "tool_use_id" => "tu_1", "tool" => "bash", "rung" => "rules",
                 "verdict" => "allow" }]

    expect(described_class.joined(records, session: "s").first.landings)
      .to eq("/usr/bin/env" => "/usr/lib/env", "/usr/bin/ls" => "/usr/lib/ls")
  end

  it "digests the tool, the input and the directory it ran in" do
    call = by_id(joined("ask")).fetch("tu_1")

    expect(call.digest).to eq(Lain::Canonical.digest(["bash", { "command" => "pwd" }, "/home/user/project"]))
  end
end
