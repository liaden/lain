# frozen_string_literal: true

RSpec.describe Lain::Sensitivity::Secrets::Identity do
  let(:env) { { "HOME" => "/home/alice", "USER" => "alice" } }
  let(:git_values) { { "user.name" => "Alice Liddell", "user.email" => "a@example.org" } }
  let(:git) { ->(key) { git_values[key] } }
  let(:identity) { described_class.current(env:, git:, hostname: "wonder") }

  it "maps each identity value to its placeholder, longest first" do
    expect(identity.pairs).to eq(
      [["Alice Liddell", "<git-author>"], ["a@example.org", "<git-email>"], ["/home/alice", "/home/<user>"],
       ["wonder", "<host>"], ["alice", "<user>"]]
    )
  end

  it "round-trips text holding every value" do
    text = "Alice Liddell <a@example.org> alice at /home/alice/src on wonder"
    aliased = identity.alias(text)

    expect([aliased, identity.restore(aliased)]).to eq(
      ["<git-author> <<git-email>> <user> at /home/<user>/src on <host>", text]
    )
  end

  it "leaves a word that merely contains a value alone" do
    expect(identity.alias("Palace and alicex")).to eq("Palace and alicex")
  end

  it "skips a value the box does not have" do
    bare = described_class.current(env: { "HOME" => " ", "USER" => "" }, git: ->(_) { "" }, hostname: "")

    expect(bare.pairs).to eq([])
  end

  it "leaves a value alone when a word character precedes it" do
    expect(identity.alias("xalice _alice alice_")).to eq("xalice _alice alice_")
  end

  it "does not rescan a placeholder when a value spells part of one" do
    clash = described_class.current(env: { "HOME" => "/home/user", "USER" => "user" }, git: ->(_) {},
                                    hostname: "host")
    aliased = clash.alias("/home/user user host")

    expect([aliased, clash.restore(aliased)]).to eq(["/home/<user> <user> <host>", "/home/user user host"])
  end

  it "survives a git that is not installed" do
    missing = described_class.current(env:, git: ->(_) { raise Errno::ENOENT }, hostname: "wonder")

    expect(missing.pairs.map(&:last)).to eq(["/home/<user>", "<host>", "<user>"])
  end

  it "keeps one entry per real value" do
    same = described_class.current(env:, git: ->(key) { key == "user.name" ? "alice" : nil }, hostname: "wonder")

    expect(same.pairs.count { _1.first == "alice" }).to eq(1)
  end

  it "is deeply frozen" do
    expect(Ractor.shareable?(identity)).to be(true)
  end
end
