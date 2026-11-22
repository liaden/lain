# frozen_string_literal: true

RSpec.describe Lain::Sensitivity::Secrets::Identity do
  let(:env) { { "HOME" => "/home/alice", "USER" => "alice" } }
  let(:git_values) { { "user.name" => "Alice Liddell", "user.email" => "a@example.org" } }
  let(:git) { ->(key) { git_values[key] } }
  let(:identity) { described_class.current(env:, git:, hostname: "wonder") }

  it "maps each identity value to its placeholder, longest first" do
    expect(identity.pairs).to eq(
      [["Alice Liddell", "<lain:git-author>"], ["a@example.org", "<lain:git-email>"],
       ["/home/alice", "/home/<lain:user>"], ["wonder", "<lain:host>"], ["alice", "<lain:user>"]]
    )
  end

  it "round-trips text holding every value" do
    text = "Alice Liddell <a@example.org> alice at /home/alice/src on wonder"
    aliased = identity.alias(text)

    expect([aliased, identity.restore(aliased)]).to eq(
      ["<lain:git-author> <<lain:git-email>> <lain:user> at /home/<lain:user>/src on <lain:host>", text]
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

    expect([aliased, clash.restore(aliased)])
      .to eq(["/home/<lain:user> <lain:user> <lain:host>", "/home/user user host"])
  end

  it "survives a git that is not installed" do
    missing = described_class.current(env:, git: ->(_) { raise Errno::ENOENT }, hostname: "wonder")

    expect(missing.pairs.map(&:last)).to eq(["/home/<lain:user>", "<lain:host>", "<lain:user>"])
  end

  it "keeps one entry per real value" do
    same = described_class.current(env:, git: ->(key) { key == "user.name" ? "alice" : nil }, hostname: "wonder")

    expect(same.pairs.count { _1.first == "alice" }).to eq(1)
  end

  # Ordinary text holds bare `<host>` and `<user>`: in XML, docs and templates.
  it "restores only its own namespaced placeholders, never a bare one ordinary text holds" do
    text = "<host>docs</host> for <user> at /home/<user>"

    expect(identity.restore(text)).to eq(text)
  end

  # A string leaf can hold JSON or source text whose escapes are literal, so
  # `\n` before a value reads as a line break, not as a word.
  it "aliases a value right after a literal escape sequence" do
    escaped = described_class.current(env: { "HOME" => "/srv/me", "USER" => "alice" }, git: ->(_) {},
                                      hostname: "wonder")

    expect(escaped.alias('cd \\n/srv/me/dev \\talice \\"alice\\" \\/srv/me'))
      .to eq('cd \\n/home/<lain:user>/dev \\t<lain:user> \\"<lain:user>\\" \\/home/<lain:user>')
  end

  it "still leaves a value alone after an ordinary letter that is no escape" do
    expect(identity.alias("qalice nalice")).to eq("qalice nalice")
  end

  describe ".session" do
    it "is one instance for the process, read once" do
      expect(described_class.session).to equal(described_class.session)
    end
  end

  it "is deeply frozen" do
    bare = described_class.current(env: {}, git: ->(_) {}, hostname: "")

    expect([identity, bare].map { Ractor.shareable?(_1) }).to eq([true, true])
  end
end
