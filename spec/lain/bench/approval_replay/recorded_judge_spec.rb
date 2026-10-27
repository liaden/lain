# frozen_string_literal: true

RSpec.describe Lain::Bench::ApprovalReplay::RecordedJudge do
  subject(:judge) { described_class.new }

  let(:place) do
    Lain::Approval::Judge::Place.new(root: "/home/user/project", cwd: "/home/user/project", requester: "agent",
                                     outside: [])
  end
  let(:prompt) { judge.prompt(tool: "bash", input: { "command" => "make" }, place:) }

  def recorded(**ruling)
    record = { "type" => "escalation", "rung" => "auto", "prompt_digest" => Lain::Canonical.digest(prompt),
               **ruling.transform_keys(&:to_s) }
    Lain::Bench::ApprovalReplay::Call.new(session: "s", tool: "bash", input: { "command" => "make" },
                                          tool_use_id: "tu_1", rulings: [record])
  end

  def answer(call) = judge.answering(call) { judge.call(tool: "bash", input: { "command" => "make" }, place:, prompt:) }

  it "answers the verdict the session's judge gave" do
    expect([answer(recorded(verdict: "allow")), answer(recorded(verdict: "deny"))]).to eq(%i[approve deny])
    expect(judge.state).to eq("replayed")
  end

  it "defers a judge's approval its bar overruled, as the call was handed down live" do
    expect(answer(recorded(verdict: "abstain", bar: "a fresh program"))).to eq(:defer)
  end

  it "faults where the session's judge faulted" do
    expect(answer(recorded(verdict: "abstain", faulted: true))).to eq(:fault)
  end

  it "says a call whose recorded prompt digest is not today's prompt's drifted" do
    answer(recorded(verdict: "allow", prompt_digest: "blake3:#{"0" * 64}"))

    expect(judge.state).to eq("drifted")
  end

  it "defers a call the session's judge left no ruling on, and says so" do
    call = Lain::Bench::ApprovalReplay::Call.new(session: "s", tool: "bash", input: {}, tool_use_id: "tu_1")

    expect(answer(call)).to eq(:defer)
    expect(judge.state).to eq("unrecorded")
  end
end
