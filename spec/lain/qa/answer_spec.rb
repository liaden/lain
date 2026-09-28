# frozen_string_literal: true

RSpec.describe Lain::QA::Answer do
  def reply(body) = "Checked it.\n\n```qa-answer\n#{body}\n```\n"

  it "reads the verdict, confidence and evidence out of the fenced block" do
    answer = described_class.parse(reply(JSON.generate(
                                           "verdict" => "fail", "confidence" => 0.8, "executed" => true,
                                           "summary" => "total off by one", "evidence" => "exit 1",
                                           "reproduction" => "bin/total"
                                         )))

    expect(answer).to have_attributes(verdict: "fail", confidence: 0.8, executed: true, reproduction: "bin/total")
    expect(answer).to be_settled
  end

  describe "an unreadable answer is unverified, never a pass" do
    it "reads a reply with no block as unverified, with the reason in its evidence" do
      answer = described_class.parse("it works")

      expect(answer.verdict).to eq("unverified")
      expect(answer.evidence).to include("qa-answer")
      expect(answer).not_to be_settled
    end

    it "reads a broken block, a non-object block and a blank reply the same way" do
      expect(described_class.parse(reply("{broken")).evidence).to include("did not read")
      expect(described_class.parse(reply("[1, 2]")).verdict).to eq("unverified")
      expect(described_class.parse(reply("null")).verdict).to eq("unverified")
      expect(described_class.parse(reply("{}")).evidence).to include("names no verdict")
      expect(described_class.parse(reply("   ")).verdict).to eq("unverified")
      expect(described_class.parse("").verdict).to eq("unverified")
    end

    # The cheapest rung reads a small quantised local model, where broken bytes
    # are ordinary. The whole design rests on a model that cannot hold a format
    # being a reason to climb, so the reader may not raise on one.
    it "never raises on undecodable bytes, in the fence or around it" do
      broken = (+"\xC3\x28").force_encoding("UTF-8")

      expect(described_class.parse("#{broken}\n#{reply(JSON.generate("verdict" => "pass"))}").verdict).to eq("pass")
      expect(described_class.parse(reply(%({"verdict":"fail","evidence":"exit 1#{broken}","reproduction":"r"}))))
        .to have_attributes(verdict: "fail", evidence: "exit 1(")
      expect(described_class.parse(broken).verdict).to eq("unverified")
    end

    it "reads a verdict outside the closed set as unverified rather than as itself" do
      expect(described_class.parse(reply(JSON.generate("verdict" => "maybe"))).verdict).to eq("unverified")
      expect(described_class.parse(reply(JSON.generate("verdict" => { "a" => 1 }))).verdict).to eq("unverified")
      expect(described_class.parse(reply(JSON.generate("verdict" => "pass"))).verdict).to eq("pass")
    end

    # The seam a provider's own typed malformed outcome arrives through: an
    # empty reply never reaches `parse`, and the reason still has to survive.
    it "can be built straight from a reason, for a reply that never had a body" do
      answer = described_class.unverified(because: "the model returned an empty answer")

      expect(answer).to have_attributes(verdict: "unverified", confidence: 0.0, executed: false)
      expect(answer.evidence).to eq("the model returned an empty answer")
    end

    # An unverified answer that does not say why is the blank answer this
    # namespace's whole thesis calls a finding.
    it "refuses a reason that says nothing, loudly, because that is the caller's bug" do
      [nil, "", "   ", "\u200B", 7].each do |nothing|
        expect { described_class.unverified(because: nothing) }.to raise_error(Lain::QA::MalformedAnswer, /because/)
      end
    end

    it "keeps a confidence a weak model overstates inside its own range" do
      expect(described_class.parse(reply(JSON.generate("verdict" => "pass", "confidence" => 5))).confidence)
        .to eq(1.0)
      expect(described_class.parse(reply(JSON.generate("verdict" => "pass", "confidence" => "high"))).confidence)
        .to eq(0.0)
    end

    it "reads a member that is not a string as nothing said, never as its inspect form" do
      answer = described_class.parse(reply(JSON.generate("verdict" => "fail", "summary" => %w[a],
                                                         "evidence" => { "x" => 1 })))

      expect(answer).to have_attributes(summary: "", evidence: "")
    end
  end

  # The child is asked to END its reply with one block, and a model that
  # restates the requested shape before filling it in is ordinary.
  it "reads the LAST fence, so a template block shown first is not the answer" do
    answer = described_class.parse("Shape I will use:\n#{reply(JSON.generate("verdict" => "unverified"))}" \
                                   "Now really:\n#{reply(JSON.generate("verdict" => "fail", "confidence" => 0.9))}")

    expect(answer).to have_attributes(verdict: "fail", confidence: 0.9)
  end

  describe "#findings" do
    it "is one finding when the answer can be checked by somebody else" do
      answer = described_class.parse(reply(JSON.generate("verdict" => "fail", "evidence" => "exit 1",
                                                         "reproduction" => "bin/total")))

      expect(answer.findings(criterion: "the first card/s", tier: "t2", severity: "major").size).to eq(1)
    end

    it "is none for a fail with no reproduction -- the false positive the ladder keeps from an implementer" do
      answer = described_class.parse(reply(JSON.generate("verdict" => "fail", "evidence" => "looks wrong")))

      expect(answer.findings(criterion: "the first card/s", tier: "t1", severity: "major")).to be_empty
    end

    # A model's reply alone was enough to file a blocking finding whose evidence
    # was one zero-width space.
    it "is none for a fail whose evidence is only zero-width, which reads as no evidence at all" do
      answer = described_class.parse(reply(JSON.generate("verdict" => "fail", "evidence" => "\u200B",
                                                         "reproduction" => "\u200B")))

      expect(answer.findings(criterion: "c", tier: "t1", severity: "blocker")).to be_empty
    end

    it "is none for a pass, and none for an unverified answer -- which is an unsettled criterion, not a defect" do
      pass = described_class.parse(reply(JSON.generate("verdict" => "pass", "evidence" => "exit 0",
                                                       "reproduction" => "bin/total")))

      expect(pass.findings(criterion: "c", tier: "t1", severity: "major")).to be_empty
      expect(described_class.unverified(because: "no block").findings(criterion: "c", tier: "t1", severity: "minor"))
        .to be_empty
    end
  end

  # Three later cards read this class, and a coercion helper is not a promise
  # this card is making to them.
  it "keeps its wire coercions to itself" do
    expect(described_class).not_to respond_to(:verdict_of, :confidence_of, :from_wire)
  end

  it "is deeply frozen" do
    expect(Ractor.shareable?(described_class.unverified(because: +"no block"))).to be(true)
  end
end
