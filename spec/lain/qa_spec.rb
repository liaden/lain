# frozen_string_literal: true

# The namespace's own constants: the closed sets every guard beneath it cites,
# and the three later cards read. `spec/lain/review_spec.rb` is the precedent --
# a vocabulary nothing asserts can be misspelled with nothing going red, which
# is worst in the file whose whole job is to name things for other cards.
RSpec.describe Lain::QA do
  it "restates every HOLDING member inside SEVERITIES, so the two spellings cannot drift apart" do
    expect(described_class::HOLDING - described_class::SEVERITIES).to be_empty
  end

  it "holds on the severe half and carries the rest" do
    expect(described_class::SEVERITIES - described_class::HOLDING).to eq(["minor"])
  end

  it "spells its verdicts, tiers and risks exactly once, and the later cards read these" do
    expect(described_class::VERDICTS).to eq(%w[pass fail unverified])
    expect(described_class::TIERS).to eq(%w[t0 t1 t2 t3])
    expect(described_class::RISKS).to eq(%w[low medium high])
  end

  # A set that is merely assigned can be pushed onto from anywhere, and a
  # vocabulary that grows at runtime is not closed.
  it "freezes every set, and every member of one" do
    sets = %i[SEVERITIES HOLDING TIERS VERDICTS RISKS].map { |name| described_class.const_get(name) }

    expect(sets.map(&:frozen?)).to all(be(true))
    expect(sets.flatten.map(&:frozen?)).to all(be(true))
  end

  describe "the one definition of nothing" do
    # `Blankness`' own docstring records what a second definition cost: a bare
    # APPROVE closed a gate on an evidence section holding one U+00A0.
    it "refuses the zero-width set ASCII strip and blank? both let through" do
      ["\u200B", "\u200D", "\u2060", "\uFEFF", "\u00A0", "\u3000", "", "   ", nil]
        .each do |value|
        expect { described_class.words!({ evidence: value }, refusal: ArgumentError) }
          .to raise_error(ArgumentError, /evidence/)
      end
    end

    it "refuses anything that is not a string, naming the attribute and what arrived" do
      expect { described_class.words!({ evidence: {} }, refusal: ArgumentError) }
        .to raise_error(ArgumentError, /evidence must be a string, got Hash/)
    end

    it "names every offending member in one raise rather than the first" do
      expect { described_class.words!({ evidence: "", reproduction: 0 }, refusal: ArgumentError) }
        .to raise_error(ArgumentError, /evidence.*reproduction/m)
    end

    it "scrubs undecodable bytes rather than raising on them" do
      expect(described_class.words!({ evidence: "ok\xC3\x28" }, refusal: ArgumentError))
        .to eq({ evidence: "ok(" })
    end

    it "reads a value that is nothing but undecodable bytes as nothing at all" do
      expect { described_class.words!({ evidence: (+"\xC3").force_encoding("UTF-8") }, refusal: ArgumentError) }
        .to raise_error(ArgumentError, /cannot be blank/)
    end
  end
end
