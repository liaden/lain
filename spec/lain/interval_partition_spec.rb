# frozen_string_literal: true

# The refusals below are the ones {Lain::Compaction::Strategy::Base} carried
# privately until this extraction. They are pinned twice on purpose: from the
# seat where the damage was felt (strategy_spec, derivation_spec) and here, on
# the value itself, where a second and third caller now reach them.
RSpec.describe Lain::IntervalPartition do
  def partition(ranges, span: 0..3, owner: "Elide", **rest)
    described_class.of(span, ranges, owner:, **rest)
  end

  describe "the refusals, each on its own terms" do
    it "refuses a proposal that is not a list at all, naming the owner and where it came from" do
      expect { partition(nil, provenance: "#propose_ranges") }
        .to raise_error(described_class::NotAPartition, /Elide answers nil from #propose_ranges/)
    end

    it "refuses a member that is not a Range" do
      expect { partition([[0, 1]]) }
        .to raise_error(described_class::NotAPartition, /Elide answers \[0, 1\], which is not a Range/)
    end

    it "refuses endpoints that are not message indices" do
      expect { partition([0.0..1.5]) }
        .to raise_error(described_class::NotAPartition, /0\.0\.\.1\.5.*not Integer message indices/)
    end

    it "refuses an empty range as empty rather than as out of bounds, in both spellings" do
      [2..1, 2...2].each do |hollow|
        expect { partition([hollow]) }
          .to raise_error(described_class::NotAPartition, /an empty range/)
      end
    end

    it "refuses one outside the span, naming the range and the span" do
      expect { partition([0..1, 7..9]) }
        .to raise_error(described_class::NotAPartition, /7\.\.9.*0\.\.3/)
    end

    it "refuses them out of ascending order, naming the ordering" do
      expect { partition([2..3, 0..1]) }
        .to raise_error(described_class::NotAPartition, /ascending order/)
    end

    it "refuses two that overlap, naming the overlap" do
      expect { partition([0..2, 1..3]) }
        .to raise_error(described_class::NotAPartition, /overlap/)
    end

    it "answers a well-formed partition unchanged, adjacency included" do
      expect(partition([0..1, 2..3]).validated).to eq([0..1, 2..3])
    end
  end

  # Three of the seven speak about ranges that are perfectly WELL FORMED --
  # which is exactly the shape the canonical form rewrites. Quoting the
  # rewritten spelling sends an author looking for ranges their code never
  # built, and the derivation always asks with an exclusive span
  # (`0...boundary.index`), so the span half of this is not hypothetical.
  describe "the spelling a refusal quotes" do
    it "names overlapping ranges as they were proposed" do
      expect { partition([0...3, 1...4], span: 0..4) }
        .to raise_error(described_class::NotAPartition, /answers 0\.\.\.3 and 1\.\.\.4, which overlap at 1/)
    end

    it "names out-of-order ranges as they were proposed" do
      expect { partition([2...4, 0...2], span: 0..4) }
        .to raise_error(described_class::NotAPartition, /answers 0\.\.\.2 after 2\.\.\.4/)
    end

    it "names the span in the spelling the caller asked with" do
      expect { partition([7..9], span: 0...4) }
        .to raise_error(described_class::NotAPartition, /outside the span it was asked about, 0\.\.\.4/)
    end

    it "cannot be held in an invalid state at all, so no caller has to remember to check" do
      expect { described_class.of(0..3, [7..9], owner: "Elide") }
        .to raise_error(described_class::NotAPartition)
    end
  end

  # A refusal that cited `#propose_ranges` from a value nobody proposed to
  # would send a reader to a hook that was never called.
  describe "the provenance a refusal cites" do
    it "cites the hook only when the strategy path supplied it" do
      expect { partition(nil) }
        .to raise_error(described_class::NotAPartition, /answers nil from IntervalPartition\.of/)
    end

    it "cites its own constructor when the runs were built here" do
      expect do
        described_class.new(owner: "PinCuts", span: 0..3, ranges: nil,
                            provenance: "IntervalPartition.covering")
      end.to raise_error(described_class::NotAPartition, /answers nil from IntervalPartition\.covering/)
    end
  end

  describe "the canonical form of a range" do
    it "reads an exclusive end as the inclusive interval it spells" do
      expect(partition([0...2, 2...4], span: 0...4).validated).to eq([0..1, 2..3])
    end

    # T10 tags ranges with their owning strategy by subclassing Range, and the
    # fold reads that tag back off the object #validated answers.
    it "answers an already-inclusive range by identity, class intact" do
      tagged = Class.new(Range).new(0, 1)

      expect(partition([tagged]).validated.first).to be(tagged)
    end
  end

  # `owner` is a diagnostic for the message, not part of what a partition IS.
  describe "when two partitions are the same partition" do
    it "is its span and its intervals, whoever asked and however they spelled them" do
      expect(described_class.of(0...4, [0...2], owner: "Elide"))
        .to eq(described_class.of(0..3, [0..1], owner: "Summarizing", provenance: "elsewhere"))
    end

    it "pairs eql? and hash with ==, so it dedupes and keys a Hash" do
      one = described_class.of(0..3, [0..1], owner: "Elide")
      same = described_class.of(0...4, [0...2], owner: "PinCuts")

      expect(one).to eql(same)
      expect(one.hash).to eq(same.hash)
      expect([one, same].uniq.size).to eq(1)
      expect({ one => :held }.fetch(same)).to be(:held)
    end

    it "is neither a partition of another span nor one into other intervals" do
      one = described_class.of(0..3, [0..1], owner: "Elide")

      expect(one).not_to eq(described_class.of(0..4, [0..1], owner: "Elide"))
      expect(one).not_to eq(described_class.of(0..3, [0..2], owner: "Elide"))
    end

    it "is not equal to something that is not a partition at all" do
      expect(described_class.of(0..3, [0..1], owner: "Elide")).not_to eq([0..1])
    end
  end

  describe "the runs left by a set of cut points" do
    it "answers one contiguous run per stretch of unexcluded indices" do
      expect(described_class.covering(0..6, excluding: [2, 5], owner: "PinCuts").validated)
        .to eq([0..1, 3..4, 6..6])
    end

    it "answers the whole span when nothing is cut out" do
      expect(described_class.covering(0..6, excluding: [], owner: "PinCuts").validated).to eq([0..6])
    end

    it "answers nothing when every index is a cut point" do
      expect(described_class.covering(0..2, excluding: [0, 1, 2], owner: "PinCuts").validated).to be_empty
    end
  end

  # Published, so its two arguments are refused BY NAME rather than left to
  # fail inside the walk: `nil.include?` names nobody, and an endless span does
  # not fail at all -- it walks forever.
  describe "the arguments .covering will not walk" do
    it "refuses a span with no end, rather than enumerating it forever" do
      expect { described_class.covering(0.., excluding: [], owner: "PinCuts") }
        .to raise_error(described_class::NotAPartition, /PinCuts.*runs of 0\.\., which is not a bounded span/)
    end

    it "refuses a span that is not a range of indices at all" do
      expect { described_class.covering(nil, excluding: [], owner: "PinCuts") }
        .to raise_error(described_class::NotAPartition, /not a bounded span of Integer indices/)
    end

    it "refuses cut points it cannot ask, rather than dying unnamed inside the walk" do
      expect { described_class.covering(0..3, excluding: nil, owner: "PinCuts") }
        .to raise_error(described_class::NotAPartition, /PinCuts.*exclude nil.*cannot be asked/)
    end

    # {Compaction::Source::Derived}'s PinCuts is the second caller, and it splits
    # the two names deliberately: `#name` answers the INNER strategy, because
    # that is what the journalled edge records, while computing the runs is the
    # wrapper's own work and a fault in it must not be reported against the
    # strategy an operator chose. Both halves are pinned here.
    #
    # The span has to be built deliberately because the derivation cannot produce
    # one: it always asks with `0...boundary.index`, which is bounded. `#ranges`
    # forwards `span:` straight through to `.covering`, so an unbounded span
    # asked of PinCuts directly is the one observation that distinguishes the two
    # owners.
    it "names the wrapper that computed the runs, never the strategy an operator chose" do
      pin_cuts = Lain::Compaction::Source::Derived.const_get(:PinCuts)
                                                  .new(inner: Lain::Compaction::Strategy::Elide.new,
                                                       pins: Lain::Context::PinnedMessages::NONE)

      expect { pin_cuts.ranges([], span: 0..) }
        .to raise_error(described_class::NotAPartition, /PinCuts asks IntervalPartition\.covering/)
      expect(pin_cuts.name).to eq("Lain::Compaction::Strategy::Elide")
    end
  end

  # The combination `chunk-derived-context-timeline.md` follow-up 3 deferred as
  # speculative, un-deferred by Joel on 2026-07-29 because building it is what
  # proves this extraction: `Compaction::Strategy::Composed` refuses an overlap
  # by asking two proposals what they meet in.
  describe "the common refinement two partitions meet in" do
    def over(ranges, owner:, span: 0..7) = described_class.of(span, ranges, owner:)

    it "cuts wherever either operand cuts" do
      halves = over([0..3, 4..7], owner: "Elide")
      thirds = over([0..1, 2..5, 6..7], owner: "Summarizing")

      expect(halves.meet(thirds).validated).to eq([0..1, 2..3, 4..5, 6..7])
    end

    it "reads two spellings of one interval as one interval" do
      expect(over([0...4], owner: "a").meet(over([0..3], owner: "b")).validated).to eq([0..3])
    end

    it "is finer than both operands, and coarser than neither" do
      halves = over([0..3, 4..7], owner: "Elide")
      thirds = over([0..1, 2..5, 6..7], owner: "Summarizing")
      met = halves.meet(thirds)

      expect([met.refines?(halves), met.refines?(thirds)]).to eq([true, true])
      expect([halves.refines?(met), thirds.refines?(met)]).to eq([false, false])
    end

    it "keeps only what both partitions cover, so a gap in either is a gap in it" do
      expect(over([0..3], owner: "a").meet(over([2..7], owner: "b")).validated).to eq([2..3])
      expect(over([0..1], owner: "a").meet(over([4..5], owner: "b")).validated).to be_empty
    end

    it "answers the other operand itself when one of them is the trivial partition" do
      trivial = over([0..7], owner: "trivial")
      other = over([0..1, 4..5], owner: "other")

      expect(trivial.meet(other)).to eq(other)
      expect(other.meet(trivial)).to eq(other)
    end

    # A meet over the partitions of ONE span, said as the laws rather than as
    # prose. The registry proves the same four laws over an exhaustive
    # population; this example is the readable statement of them.
    it "is idempotent, commutative and associative over one span" do
      a = over([0..3, 4..7], owner: "a")
      b = over([0..1, 2..5, 6..7], owner: "b")
      c = over([0..0, 1..7], owner: "c")

      expect(a.meet(a)).to eq(a)
      expect(a.meet(b)).to eq(b.meet(a))
      expect(a.meet(b).meet(c)).to eq(a.meet(b.meet(c)))
    end

    it "refuses two partitions of different spans, naming both" do
      expect { over([0..1], owner: "a", span: 0..3).meet(over([0..1], owner: "b", span: 0..7)) }
        .to raise_error(described_class::NotAPartition, /a and b.*0\.\.3 and 0\.\.7/)
    end

    it "names both askers, so a refusal about the refinement cites whose ranges met" do
      met = over([0..3], owner: "Elide").meet(over([2..7], owner: "Summarizing"))

      expect(met.owner).to eq("Elide meet Summarizing")
    end

    it "is a deeply frozen, shareable value like any other partition" do
      met = over([0..3], owner: "a").meet(over([2..7], owner: "b"))

      expect(met).to be_frozen
      expect(Ractor.shareable?(met)).to be(true)
    end
  end

  describe "the shape of the object" do
    it "is a deeply frozen, shareable value" do
      value = partition([0..1, 2..3])

      expect(value).to be_frozen
      expect(Ractor.shareable?(value)).to be(true)
    end

    # The error is the value's, and the compaction namespace keeps a name for
    # it so no rescue site or pinned spec had to move.
    it "is the error the strategy namespace still names" do
      expect(Lain::Compaction::Strategy::NotAPartition).to be(described_class::NotAPartition)
    end

    it "is an error of this codebase" do
      expect(described_class::NotAPartition.new).to be_a(Lain::Error)
    end
  end
end
