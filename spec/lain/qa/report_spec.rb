# frozen_string_literal: true

RSpec.describe Lain::QA::Report do
  def wire(severity)
    { "severity" => severity, "criterion" => "the second card/Scenario: refunds", "summary" => "refund skips tax",
      "evidence" => "bin/refund 12 printed 10.00", "reproduction" => "bin/refund 12", "tier" => "t2" }
  end

  def answer(body) = "I ran the refund path.\n\n```qa-report\n#{JSON.generate(body)}\n```\n"

  def fenced(body) = "```qa-report\n#{body}\n```\n"

  describe ".parse" do
    it "reads the one fenced block and ignores the prose around it" do
      report = described_class.parse(answer("findings" => [wire("major")], "tiers_run" => %w[t1 t2],
                                            "escalations" => ["the second card: t1 escalate (disagreement)"],
                                            "unsettled" => ["the second card/Scenario: partial refunds"]),
                                     subject: "plan.md @ a..b")

      expect(report.findings.map(&:severity)).to eq(["major"])
      expect(report.tiers_run).to eq(%w[t1 t2])
      expect(report.escalations).to eq(["the second card: t1 escalate (disagreement)"])
      expect(report.unsettled).to eq(["the second card/Scenario: partial refunds"])
    end

    # A child that answered without the block reported nothing, and reading that
    # as a clean pass is the silent failure this refuses.
    it "refuses an answer with no report block rather than reading it as a pass" do
      expect { described_class.parse("Looks good to me!", subject: "x") }
        .to raise_error(Lain::QA::MalformedReport, /reported nothing/)
    end

    # The silent pass in its worst dress: a child typing its own
    # inconclusiveness into the fence used to yield `Verdict: PASS. Findings: 0.`
    it "refuses a fence holding anything but an object, rather than reading a pass out of it" do
      ['"the run was inconclusive"', "null", "[1,2]", "7", "true"].each do |body|
        expect { described_class.parse(fenced(body), subject: "x") }
          .to raise_error(Lain::QA::MalformedReport, /must be an object/)
      end
    end

    # These are refused deliberately: a child that opened a fence and wrote
    # nothing in it has not reported, and the words say so rather than handing
    # the human a JSON parser's column number.
    it "refuses an empty or whitespace-only fence in its own words" do
      ["", "   ", "\n", "\u200B"].each do |body|
        expect { described_class.parse(fenced(body), subject: "x") }
          .to raise_error(Lain::QA::MalformedReport, /block is empty/)
      end
    end

    it "reads a fence carrying nothing found as an empty report, not a refusal" do
      report = described_class.parse(answer("tiers_run" => %w[t0 t1]), subject: "x")

      expect(report.findings).to be_empty
      expect(report.tiers_run).to eq(%w[t0 t1])
    end

    it "refuses a block that is not JSON" do
      expect { described_class.parse(fenced("{nope"), subject: "x") }
        .to raise_error(Lain::QA::MalformedReport, /not JSON/)
    end

    # A caller writing `rescue MalformedReport` around a report parse is the
    # obvious reading, so a finding that is not one arrives as that.
    it "refuses a wire finding as a malformed REPORT, which is what parsing one promises" do
      expect { described_class.parse(fenced(JSON.generate("findings" => [{ "severity" => "major" }])), subject: "x") }
        .to raise_error(Lain::QA::MalformedReport, /names no criterion/)
    end

    it "never raises an untyped error on undecodable bytes" do
      expect { described_class.parse((+"\xC3\x28").force_encoding("UTF-8"), subject: "x") }
        .to raise_error(Lain::QA::MalformedReport, /reported nothing/)
    end

    # The child is asked to END with one block, and a model that shows the
    # requested shape before filling it in is ordinary.
    it "reads the LAST fence, so a template block shown first is not the report" do
      report = described_class.parse("Shape:\n#{answer("findings" => [])}Now really:\n" \
                                     "#{answer("tiers_run" => %w[t1 t2], "unsettled" => %w[c])}", subject: "x")

      expect(report.tiers_run).to eq(%w[t1 t2])
      expect(report.unsettled).to eq(%w[c])
    end
  end

  describe "what a report will not be built out of" do
    it "refuses a finding that is not one, rather than becoming unshareable" do
      expect { described_class.new(subject: "x", findings: [Object.new]) }
        .to raise_error(Lain::QA::MalformedReport, /findings/)
    end

    it "refuses a rung outside the closed set, and a blank line in any list" do
      expect { described_class.new(subject: "x", tiers_run: %w[t1 t9]) }
        .to raise_error(Lain::QA::MalformedReport, /t9/)
      expect { described_class.new(subject: "x", unsettled: ["\u200B"]) }
        .to raise_error(Lain::QA::MalformedReport, /unsettled/)
    end

    # "# QA report: " -- a report about nothing, in a namespace whose thesis is
    # that a blank answer is a finding.
    it "refuses a blank subject, because a report has to say what it is about" do
      expect { described_class.new(subject: nil) }.to raise_error(Lain::QA::MalformedReport, /subject/)
    end
  end

  describe "the verdict" do
    it "is one of three states rather than two booleans a hurried caller reads one of" do
      minor = Lain::QA::Finding.from_h(wire("minor"))
      major = Lain::QA::Finding.from_h(wire("major"))

      expect(described_class.new(subject: "x", findings: [minor]).verdict).to eq(:pass)
      expect(described_class.new(subject: "x", unsettled: %w[c]).verdict).to eq(:unsettled)
      expect(described_class.new(subject: "x", findings: [minor, major]).verdict).to eq(:hold)
    end

    it "passes with only minor findings and holds on any major one" do
      minor = Lain::QA::Finding.from_h(wire("minor"))
      major = Lain::QA::Finding.from_h(wire("major"))

      expect(described_class.new(subject: "x", findings: [minor])).to be_passed
      expect(described_class.new(subject: "x", findings: [minor, major]).holding).to eq([major])
    end

    it "counts an unsettled criterion as unsettled rather than as a pass" do
      report = described_class.new(subject: "x", tiers_run: %w[t1 t2],
                                   unsettled: ["the second card/Scenario: refunds"])

      expect(report.verdict).to eq(:unsettled)
      expect(report).not_to be_clean
      expect(report.to_markdown).to include("PASS (1 unsettled)", "the second card/Scenario: refunds")
    end
  end

  describe "#prepend" do
    it "puts the structural rung's findings first and records that it ran" do
      t0 = Lain::QA::Finding.from_h(wire("major").merge("tier" => "t0"))
      report = described_class.new(subject: "x", findings: [Lain::QA::Finding.from_h(wire("minor"))],
                                   tiers_run: ["t1"]).prepend([t0])

      expect(report.findings.first).to eq(t0)
      expect(report.tiers_run).to eq(%w[t0 t1])
    end
  end

  describe "#to_h" do
    it "emits the wire form it parses, so nothing downstream has to invent the inverse" do
      report = described_class.new(subject: "plan.md", findings: [Lain::QA::Finding.from_h(wire("major"))],
                                   tiers_run: %w[t1], escalations: %w[e], unsettled: %w[c])

      expect(described_class.parse(fenced(JSON.generate(report.to_h)), subject: "plan.md")).to eq(report)
    end
  end

  describe "a report with no findings still states what it ran" do
    it "names the rungs and the escalations, so a pass is auditable" do
      markdown = described_class.new(subject: "plan.md", tiers_run: %w[t0 t1 t2],
                                     escalations: ["card one: t1 escalate (risk-high)",
                                                   "card two: t1 escalate (disagreement)"]).to_markdown

      expect(markdown).to include("Verdict: PASS", "Tiers run: t0, t1, t2", "Findings: 0")
      expect(markdown).to include("- card one: t1 escalate (risk-high)", "- card two: t1 escalate (disagreement)")
    end

    it "gives every finding its evidence and reproduction when there are some" do
      markdown = described_class.new(subject: "plan.md", findings: [Lain::QA::Finding.from_h(wire("major"))],
                                     tiers_run: ["t2"]).to_markdown

      expect(markdown).to include("Verdict: HOLD (1 holding)")
      expect(markdown).to include("- evidence: bin/refund 12 printed 10.00", "- reproduce: bin/refund 12")
    end
  end

  it "is deeply frozen" do
    expect(Ractor.shareable?(described_class.new(subject: +"x", findings: [Lain::QA::Finding.from_h(wire("minor"))],
                                                 tiers_run: [+"t1"], escalations: [+"e"], unsettled: [+"c"])))
      .to be(true)
  end
end
