# frozen_string_literal: true

RSpec.describe Lain::Approval::Reply do
  let(:verdict) { Lain::Approval::Verdict }

  def parsed(line) = described_class.parse(line)

  it "reads a bare approve as Approve with no note" do
    expect(parsed("approve")).to eq(verdict::Approve.new(note: nil))
  end

  it "reads the note after an approve" do
    expect(parsed("approve, re-signed unchanged")).to eq(verdict::Approve.new(note: "re-signed unchanged"))
  end

  it "reads a y as Approve with no note" do
    expect(parsed("y")).to eq(verdict::Approve.new(note: nil))
  end

  it "reads an n with a reason as Deny" do
    expect(parsed("n wrong crate name")).to eq(verdict::Deny.new(note: "wrong crate name"))
  end

  it "reads a deny with a colon" do
    expect(parsed("deny: use lain epic status")).to eq(verdict::Deny.new(note: "use lain epic status"))
  end

  it "reads a hold with a note" do
    expect(parsed("hold back after lunch")).to eq(verdict::Hold.new(note: "back after lunch"))
  end

  it "reads a blank note as no note" do
    expect(parsed("approve,   ")).to eq(verdict::Approve.new(note: nil))
  end

  it "drops a separator after the verdict word" do
    expect([parsed("deny: wrong crate"),
            parsed("deny, wrong crate")]).to all(eq(verdict::Deny.new(note: "wrong crate")))
  end

  it "keeps a path that follows the word" do
    expect(parsed("n ./build").note).to eq("./build")
  end

  it "ignores case, surrounding space and a closing full stop" do
    expect(parsed("  YES!  ")).to eq(verdict::Approve.new(note: nil))
  end

  it "does not read an empty line as a verdict" do
    expect(parsed("")).to eq(described_class::Unrecognised.new(text: ""))
  end

  it "does not read an unknown first word as a deny" do
    expect(parsed("approvx")).to eq(described_class::Unrecognised.new(text: "approvx"))
  end

  it "does not read a word that merely starts with a verdict word" do
    expect(parsed("nothing")).to be_a(described_class::Unrecognised)
  end

  it_behaves_like "a round trip", {
    render: ->(v) { described_class.render(v) },
    parse: ->(s) { described_class.parse(s) },
    population: lambda {
      [Lain::Approval::Verdict::Approve, Lain::Approval::Verdict::Hold, Lain::Approval::Verdict::Deny]
        .product([nil, "wrong crate", "a; b", "./build", "a, b", "x: y", "approve me", "é, 日本語", "! x", "- item",
                  "; x", ": x", "- "]).map { |k, note| k.new(note:) }
    }
  }

  describe "the words the old parsers accepted" do
    {
      Lain::Approval::Verdict::Approve => %w[approved approve yes y],
      Lain::Approval::Verdict::Deny => %w[denied deny nope nah no n],
      Lain::Approval::Verdict::Hold => %w[hold wait stop]
    }.each do |kind, words|
      words.each do |word|
        it "reads #{word.inspect} as #{kind.name.demodulize}" do
          expect(parsed(word)).to eq(kind.new(note: nil))
        end
      end
    end
  end

  describe "an approval, which only a clear reply may give" do
    it "is not given by a question or a trailing ellipsis" do
      replies = ["approve?", "y?", "approve...", "approve ?", "approve..", "approve!."].map { |line| parsed(line) }
      expect(replies).to all(be_a(described_class::Unrecognised))
    end

    it "is not given by a note with no separator" do
      expect(["approve it", "yes please"].map { parsed(_1) }).to all(be_a(described_class::Unrecognised))
    end

    it "takes a note after a comma, colon or dash" do
      expect(["approve, ok", "approve: ok", "approve - ok"].map { parsed(_1) })
        .to all(eq(verdict::Approve.new(note: "ok")))
    end

    it "takes a closing full stop or exclamation mark" do
      expect(["approve.", "yes!!"].map { parsed(_1) }).to all(eq(verdict::Approve.new(note: nil)))
    end
  end

  describe "a deny or hold" do
    it "takes any punctuation tail" do
      expect([parsed("no?"), parsed("stop..."), parsed("n?")].map(&:class))
        .to eq([verdict::Deny, verdict::Hold, verdict::Deny])
    end

    it "takes a bare-space note" do
      expect(parsed("hold on").note).to eq("on")
    end
  end

  it "keeps a note led by punctuation whole" do
    expect(parsed("approve, ! x")).to eq(verdict::Approve.new(note: "! x"))
  end

  describe "the network answer" do
    def offered(line) = described_class.parse(line, network: true)

    it "reads network and approve network as an approval with network" do
      expect(%w[network NETWORK].push("approve network").map { offered(_1) })
        .to all(eq(verdict::Approve.new(network: true)))
    end

    it "takes a note after a separator, as an approval does" do
      expect(offered("network, push to origin")).to eq(verdict::Approve.new(note: "push to origin", network: true))
    end

    it "takes a note only after a comma, colon or dash, and nothing after a bare space or a question" do
      expect(["network: push", "network - push", "approve network, push"].map { offered(_1) })
        .to all(eq(verdict::Approve.new(note: "push", network: true)))
      expect(["network please", "network?", "approve network please"].map { offered(_1) })
        .to all(be_a(described_class::Unrecognised))
    end

    it "never reads a note as consent to network" do
      expect(offered("approve: network please")).to eq(verdict::Approve.new(note: "network please"))
    end

    it "is unrecognised where it is not offered, as at an epic gate" do
      expect(["network", "approve network"].map { parsed(_1) }).to all(be_a(described_class::Unrecognised))
    end

    it "renders a form that reads back where it is offered" do
      [verdict::Approve.new(network: true), verdict::Approve.new(note: "a, b", network: true)].each do |chosen|
        expect(offered(described_class.render(chosen))).to eq(chosen)
      end
    end
  end
end
