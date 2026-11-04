# frozen_string_literal: true

require "stringio"

RSpec.describe Lain::Bench::ApprovalReplay::Approver do
  let(:queue) { Lain::Approval::Parked::Queue.new(journal: Lain::Journal.new(io: StringIO.new)) }
  let(:call) { Lain::Effect::ToolCall.new(tool_use_id: "tu_1", name: "list_files", input: { "path" => "/home" }) }

  def replayed(*given)
    approver = described_class.new(:recorded, decisions: { "tu_1" => given })
    Sync do |task|
      run = task.async { queue.adjudicate(call, nil) }
      pending = task.with_timeout(1) { queue.dequeue }
      approver.answer(pending)
      run.wait
    end
  end

  it "replays a recorded postpone as the human's hold, so the replay decides what the session did" do
    expect(replayed("postpone")).to have_attributes(decision: :postpone, authority: :human)
  end

  it "remembers no denial for a replayed postpone, as the live queue did not" do
    replayed("postpone")

    expect(queue.denied(requester: "agent", path: "/home")).to be_nil
  end

  it "replays a recorded approve and deny as the human's" do
    expect([replayed("approve"), replayed("deny")].map { [_1.decision, _1.authority] })
      .to eq([%i[approve human], %i[deny human]])
  end
end
