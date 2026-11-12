# frozen_string_literal: true

require "tmpdir"

RSpec.describe Lain::CLI::Resume::StoppedChildren do
  around do |example|
    Dir.mktmpdir("lain-stopped-children") do |dir|
      @kept_dir = dir
      example.run
    end
  end

  attr_reader :kept_dir

  def stop(label, role: "dev", parent: "blake3:chat", **lease)
    Lain::Telemetry::ChildStopped.new(spawn: "blake3:#{label}", label:, role:, head: "blake3:head", parent:,
                                      reason: :iterations, task: "build it", **lease)
  end

  let(:stopped) do
    described_class.new([stop("skeleton"), stop("notes", role: "researcher", kept: true, lease_path: kept_dir),
                         stop("deep", parent: "blake3:a-child")], chat: "blake3:chat")
  end

  it "hands on the stops the chat's own spawners can resume, a researcher's kept directory included" do
    expect(stopped.resumable.map(&:label)).to eq(%w[skeleton notes])
  end

  it "lists the resumable ones in a notice, so the human knows to ask for them" do
    expect(stopped.notices.first).to eq("2 stopped children can be resumed: skeleton (dev), notes (researcher)")
  end

  it "hands on a checkout's stop that kept a snapshot" do
    snapshotted = described_class.new([stop("skeleton", lease_path: "/w/children/4bfe", snapshot: "c0ffee")],
                                      chat: "blake3:chat")

    expect(snapshotted.resumable.map(&:label)).to eq(["skeleton"])
  end

  it "names the stops the resumed run cannot resume, and says why" do
    gone = File.join(kept_dir, "gone")
    unresumable = described_class.new(
      [stop("deep", parent: "blake3:a-child"), stop("notes", role: "researcher", kept: true, lease_path: gone),
       stop("skeleton", lease_path: "/w/children/4bfe")], chat: "blake3:chat"
    )

    expect(unresumable.resumable).to be_empty
    expect(unresumable.notices).to eq([
                                        "3 stopped children cannot be resumed: deep (dev), as the child it stopped " \
                                        "under has ended; notes (researcher), as its directory, #{gone}, is gone; " \
                                        "skeleton (dev), as it kept no snapshot"
                                      ])
  end

  it "says nothing when no child was left stopped" do
    expect(described_class.new([], chat: "blake3:chat").notices).to be_empty
  end
end
