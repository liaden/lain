# frozen_string_literal: true

RSpec.describe Lain::CLI::Resume::StoppedChildren do
  def stop(label, role: "dev", parent: "blake3:chat", kept: false)
    Lain::Telemetry::ChildStopped.new(spawn: "blake3:#{label}", label:, role:, head: "blake3:head", parent:, kept:,
                                      reason: :iterations, task: "build it")
  end

  let(:stopped) do
    described_class.new([stop("skeleton"), stop("notes", role: "researcher", kept: true),
                         stop("deep", parent: "blake3:a-child")], chat: "blake3:chat")
  end

  it "hands on only the stops the chat's own spawners can resume" do
    expect(stopped.resumable.map(&:label)).to eq(["skeleton"])
  end

  it "lists the resumable ones in a notice, so the human knows to ask for them" do
    expect(stopped.notices.first).to eq("1 stopped child can be resumed: skeleton (dev)")
  end

  it "names the stops the resumed run cannot resume, and says why" do
    expect(stopped.notices.last).to eq(
      "2 stopped children cannot be resumed: notes (researcher), as its directory was confined by the run that " \
      "leased it; deep (dev), as the child it stopped under has ended"
    )
  end

  it "says nothing when no child was left stopped" do
    expect(described_class.new([], chat: "blake3:chat").notices).to be_empty
  end
end
