# frozen_string_literal: true

# Which topologies each live comparison puts side by side.
#
# There are TWO rosters here and they answer different questions, which is why
# they are separate builders rather than one list that grew. `.build` is the
# ORCHESTRATION comparison `lain bench arms` runs -- single-thread against two
# richer topologies over one flat task suite. `.altitude` is the DECOMPOSITION
# comparison `lain bench altitude` runs -- the same work entered at four
# different heights on {Lain::Arm::Ladder}.
RSpec.describe Lain::Bench::LiveArms do
  # The seams the altitude arms need and the orchestration arms do not: a
  # planner, an issue actor and its fleet, and one already-built driver per epic
  # entry. Scripted here -- nothing in this file resolves a provider.
  let(:seams) do
    described_class::Seams.new(
      planner: ->(*, **) { "Subject: lib/order.rb\n" },
      actors: ->(*, **) { raise "no actor is launched in this spec" },
      supervisor: Object.new, progressive: Object.new, hands_off: Object.new,
      slug: "demo", records: -> { [] }
    )
  end

  def altitude = described_class.altitude(seams:)

  describe ".altitude — the four rungs, in ladder order" do
    # Scenario: the report compares four arms. Their ORDER is the ladder's, so
    # a reader scanning the report walks from the cheapest entry to the richest
    # rather than in whatever order a Hash happened to yield.
    it "builds one-shot, plan-only and both epic entries, lowest rung first" do
      expect(altitude.map(&:name)).to eq(%w[one-shot plan-only epic-progressive epic-hands-off])
    end

    it "enters the ladder one rung higher each time, the two epic entries alike" do
      expect(altitude.map { |arm| arm.rungs.first }).to eq(%w[implementation issue_plan research research])
    end

    # The two epic entries differ in WHO answers the gates and in nothing else,
    # so they must walk the same rungs -- the confound a bench comparing them
    # cannot introduce.
    it "has the two epic entries walk identical rungs" do
      progressive, hands_off = altitude.last(2)

      expect(progressive.rungs).to eq(hands_off.rungs)
    end

    # One instrument for every arm: a comparison is only a comparison if the
    # clock and the price book are shared, which is {Arm::Instrument}'s whole
    # reason for existing.
    it "measures every arm with one shared instrument" do
      instruments = altitude.map { |arm| arm.instance_variable_get(:@instrument) }

      expect(instruments.uniq.size).to eq(1)
    end

    it "prices every arm through the book it was given" do
      book = Lain::PriceBook.new(prices: {}, fallback: Lain::Price.per_mtok(input: 0, output: 0,
                                                                            cache_creation: 0, cache_read: 0))

      instrument = described_class.altitude(seams:, price_book: book)
                                  .first.instance_variable_get(:@instrument)

      expect(instrument.price_book).to be(book)
    end
  end

  # The orchestration roster is a DIFFERENT question, and `lain bench arms` and
  # its report spec pin it. Adding the altitude arms to it would silently change
  # what that command compares and what it costs to run.
  describe ".build — the orchestration roster, unchanged" do
    it "still answers exactly the three orchestration arms, the control first" do
      expect(described_class.build.map(&:name)).to eq(%w[single-thread orchestrator-worker dual-ledger])
    end

    it "carries none of the altitude arms" do
      expect(described_class.build.map(&:name)).not_to include("one-shot", "plan-only")
    end
  end
end
