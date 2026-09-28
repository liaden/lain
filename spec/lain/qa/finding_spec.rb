# frozen_string_literal: true

RSpec.describe Lain::QA::Finding do
  def finding(**overrides)
    described_class.new(severity: "major", criterion: "the first card/Scenario: totals",
                        summary: "the total is off by one",
                        evidence: "spec/order_spec.rb:12 expected 3, got 2",
                        reproduction: "bundle exec rspec spec/order_spec.rb:12", tier: "t1", **overrides)
  end

  describe "a finding without evidence cannot exist" do
    it "refuses blank evidence, because a finding nobody can check is an opinion" do
      expect { finding(evidence: "  ") }.to raise_error(Lain::QA::MalformedFinding, /evidence cannot be blank/)
    end

    it "refuses a blank reproduction for the same reason" do
      expect { finding(reproduction: "") }.to raise_error(Lain::QA::MalformedFinding, /reproduction cannot be blank/)
    end

    it "refuses a finding with neither, naming both rather than only the first" do
      expect { finding(evidence: nil, reproduction: nil) }
        .to raise_error(Lain::QA::MalformedFinding, /evidence.*reproduction/m)
    end

    # The hole ASCII `strip` and ActiveSupport's `blank?` both leave open. Such
    # a finding renders as `- evidence: ` and holds the work: visually empty,
    # and blocking.
    it "refuses evidence that is only zero-width or non-ASCII space" do
      ["\u200B", "\u200D", "\u2060", "\uFEFF", "\u00A0", "\u3000", "\u2007"].each do |nothing|
        expect { finding(evidence: nothing) }.to raise_error(Lain::QA::MalformedFinding, /evidence cannot be blank/)
      end
    end

    it "refuses undecodable bytes that scrub away to nothing, rather than raising on them" do
      expect { finding(evidence: (+"\xC3").force_encoding("UTF-8")) }
        .to raise_error(Lain::QA::MalformedFinding, /evidence cannot be blank/)
      expect(finding(evidence: "exit 1\xC3\x28").evidence).to eq("exit 1(")
    end

    # Stringifying whatever arrives is how an opinion gets filed: an
    # array-valued summary reaches the markdown a human reads as `["a"]`.
    it "refuses a member that is not a string at all, naming what arrived" do
      [0, [], {}, Object.new, true].each do |wrong|
        expect { finding(evidence: wrong) }
          .to raise_error(Lain::QA::MalformedFinding, /evidence must be a string, got #{wrong.class}/)
      end
    end

    it "refuses a severity or a tier outside the closed sets" do
      expect { finding(severity: "critical") }.to raise_error(Lain::QA::MalformedFinding, %r{blocker/major/minor})
      expect { finding(tier: "t9") }.to raise_error(Lain::QA::MalformedFinding, /t0/)
    end
  end

  describe "which findings hold the work" do
    it "holds on blocker and major, and carries minor without holding" do
      expect(%w[blocker major minor].map { |severity| finding(severity:).holds? }).to eq([true, true, false])
    end
  end

  describe "the wire form" do
    it "round-trips through the Hash the QA child emits" do
      expect(described_class.from_h(JSON.parse(JSON.generate(finding.to_h)))).to eq(finding)
    end

    it "names the member a wire finding is missing" do
      expect { described_class.from_h("severity" => "major") }
        .to raise_error(Lain::QA::MalformedFinding, /names no criterion/)
    end

    it "refuses a wire finding that is not an object at all" do
      expect { described_class.from_h(["major"]) }
        .to raise_error(Lain::QA::MalformedFinding, /must be an object/)
    end
  end

  it "is deeply frozen" do
    expect(Ractor.shareable?(finding)).to be(true)
  end
end
