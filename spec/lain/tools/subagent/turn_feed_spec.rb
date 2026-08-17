# frozen_string_literal: true

# T2: the feed that carries a spawned chain's turns to the session record.
#
# It speaks {Lain::Middleware::JournalTurns}' `#catch_up` duck, which is what
# lets a child Agent journal its own turns through the same middleware a chat
# uses -- but it is NOT the {Lain::SessionRecord::Scribe}, and the difference is
# the whole reason this file exists: the Scribe refuses a timeline that stops
# extending the chain it has written, and a feed that copied only the walk would
# have inherited the duck without the guard.
RSpec.describe Lain::Tools::Subagent::TurnFeed do
  let(:store) { Lain::Store.new }
  let(:seen) { [] }

  def text(body) = [{ "type" => "text", "text" => body }]

  def chain(*bodies)
    bodies.each_with_index.inject(Lain::Timeline.empty(store:)) do |acc, (body, index)|
      acc.commit(role: index.even? ? :user : :assistant, content: text(body))
    end
  end

  def feed(base: nil) = described_class.new(observer: seen.method(:push), base:)

  it "feeds every turn root-first" do
    grown = chain("a", "b", "c")

    feed.catch_up(grown)

    expect(seen.map(&:digest)).to eq(grown.ancestor_digests.reverse)
  end

  it "feeds nothing twice across repeated catch_ups" do
    first = chain("a", "b")
    subject = feed
    subject.catch_up(first)

    subject.catch_up(first.commit(role: :user, content: text("c")))

    expect(seen.map(&:digest).uniq).to eq(seen.map(&:digest))
    expect(seen.size).to eq(3)
  end

  # `base` is the digest the child STARTED from -- the parent's head under an
  # `:inherit` prefix, where everything at or below it is already in the record
  # as `turn` records written by the Scribe's own walk.
  it "leaves the turns at and below its base to whoever spawned it" do
    inherited = chain("parent ask", "parent reply")
    grown = inherited.commit(role: :user, content: text("child ask"))

    feed(base: inherited.head_digest).catch_up(grown)

    expect(seen.map(&:digest)).to eq([grown.head_digest])
  end

  # PROBE 5, promoted. A stop digest is a `take_while` sentinel, and a walk that
  # never meets it runs to the root -- which is indistinguishable from "nothing
  # fed yet" unless somebody says so. Silently re-feeding is record duplication
  # in a format whose premise is that a record means something.
  describe "when the timeline no longer carries the digest last fed" do
    it "refuses a checkout below the stop rather than re-feeding from the root" do
      grown = chain("a", "b")
      subject = feed
      subject.catch_up(grown)
      rewound = grown.checkout(grown.ancestors.to_a.last.digest).commit(role: :assistant, content: text("c"))

      expect { subject.catch_up(rewound) }
        .to raise_error(described_class::Diverged, /is not on timeline/)
      expect(seen.map(&:digest).uniq).to eq(seen.map(&:digest))
    end

    it "refuses a base that was never on the chain at all" do
      elsewhere = chain("other")

      expect { feed(base: elsewhere.head_digest).catch_up(chain("a", "b")) }
        .to raise_error(described_class::Diverged)
      expect(seen).to be_empty
    end

    # The ordinary caught-up case walks out empty and must NOT be mistaken for
    # a divergence.
    it "accepts a timeline that stands exactly at the stop digest" do
      settled = chain("a", "b")

      expect { feed(base: settled.head_digest).catch_up(settled) }.not_to raise_error
      expect(seen).to be_empty
    end
  end
end
