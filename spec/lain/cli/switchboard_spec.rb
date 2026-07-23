# frozen_string_literal: true

require "stringio"

RSpec.describe Lain::CLI::Switchboard do
  let(:journal_io) { StringIO.new }
  let(:journal) { Lain::Journal.new(io: journal_io) }

  def switchboard(yolo: false)
    described_class.new(journal:, yolo:, model: "claude-opus-4-8")
  end

  describe "the approval side" do
    it "wires the queue as BOTH the parked list and the gate's starting policy" do
      board = switchboard

      expect(board.approvals).to be_a(Lain::Approval::Queue)
      expect(board.policy_switch.current).to be(board.approvals)
    end

    it "wires NO queue under --yolo, starting the switch on ApproveAll" do
      board = switchboard(yolo: true)

      expect(board.approvals).to be_nil
      expect(board.policy_switch.call("effect", nil)).to be(true)
    end
  end

  describe "the model side" do
    let(:store) { Lain::Store.new }
    let(:timeline) do
      Lain::Timeline.empty(store:).commit(role: :user, content: [{ "type" => "text", "text" => "hi" }])
    end

    it "grafts the live model slot onto a context, read at render time" do
      board = switchboard
      grafted = board.graft(Lain::Context.new(model: "claude-opus-4-8", max_tokens: 64))

      board.model_switch.switch("claude-haiku-4-5", surface: "tty")

      expect(grafted.render(timeline:, toolset: Lain::Toolset.new).model).to eq("claude-haiku-4-5")
    end
  end

  it "hands /approve a tty-signing drain prompt whose reads route through the conductor" do
    conductor = instance_double(Lain::CLI::Conductor)
    tty = instance_double(Lain::Frontend::TTY)
    prompt = switchboard.surface_kwargs(conductor:, tty:).fetch(:approval_prompt)
    pending = Lain::Approval::Queue::Pending.new(
      effect: Struct.new(:name, :input).new("bash", { "command" => "ls" }), requester: "agent", clock: -> { 0.0 }
    )
    allow(conductor).to receive(:read_reply).with(tty, /bash/).and_return("y")

    prompt.decide(pending)

    expect(pending.surface).to eq("tty")
    expect(pending).to be_approved
  end
end
