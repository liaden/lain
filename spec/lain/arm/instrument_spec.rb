# frozen_string_literal: true

# The arms' measuring instrument: the ONE place the bench's two headline metrics
# -- wall-time and dollars -- are taken. Every arm is injected with one, so
# `elapsed` and `ledger` cannot disagree between topologies by copy-paste drift
# (which is exactly how they used to agree: four byte-identical `#timed` copies
# and three `Ledger.from_journal` lines).
RSpec.describe Lain::Arm::Instrument do
  # A clock that ticks a fixed amount per call, so elapsed is exact.
  def ticking(*seconds) = seconds.each.method(:next)

  describe "#timed -- the elapsed/result pair" do
    it "answers the block's own value alongside the elapsed seconds" do
      instrument = described_class.new(clock: ticking(100.0, 100.5))

      elapsed, result = instrument.timed { :the_block_value }

      expect(elapsed).to eq(0.5)
      expect(result).to eq(:the_block_value)
    end

    it "defaults to a monotonic clock, so elapsed is never negative" do
      elapsed, = described_class.new.timed { 1 + 1 }

      expect(elapsed).to be_a(Float).and be >= 0
    end

    # The tick clock above cannot tell a SPAN from a PAIR OF READS: two
    # consecutive reads differ by the same amount whatever sits between them, so
    # it stays green even if the first read moves to AFTER the block. A clock the
    # BLOCK advances is the only shape that pins what this object measures.
    it "measures the span the block occupies, not merely two clock reads" do
      now = 0.0
      instrument = described_class.new(clock: -> { now })

      elapsed, result = instrument.timed { (now += 5.0) && :done }

      expect(elapsed).to eq(5.0)
      expect(result).to eq(:done)
    end

    it "measures zero for a block that consumes no time on that clock" do
      expect(described_class.new(clock: -> { 42.0 }).timed { :instant }.first).to eq(0.0)
    end
  end

  describe "#price -- the run's journal folded into a Ledger" do
    let(:timeline) do
      Lain::Timeline.empty(store: Lain::Store.new)
                    .commit(role: :assistant, content: [{ "type" => "text", "text" => "done" }])
    end

    def usage_record(digest)
      Lain::Telemetry::TurnUsage.new(digest:, model: "claude-sonnet-4", stop_reason: :end_turn,
                                     usage: { "input_tokens" => 1000, "output_tokens" => 100 })
    end

    it "drains the journal and prices its usage records" do
      journal = Lain::Channel.new
      journal << usage_record(timeline.head_digest)

      ledger = described_class.new.price(journal)

      expect(ledger.usage(timeline).total_tokens).to eq(1100)
      expect(ledger.cost(timeline)).to be > 0
    end

    it "prices through the INJECTED price book, not the default" do
      journal = Lain::Channel.new
      journal << usage_record(timeline.head_digest)
      # Nothing in the map, so every model falls to a free fallback: what is
      # pinned is WHOSE book priced the run, not the rate.
      zero = Lain::Price.per_mtok(input: 0, output: 0, cache_creation: 0, cache_read: 0)
      free = Lain::PriceBook.new(prices: {}, fallback: zero)

      ledger = described_class.new(price_book: free).price(journal)

      expect(ledger.cost(timeline)).to eq(0)
    end

    it "prices already-drained records too, for an arm that folds its workers' journals itself" do
      records = [usage_record(timeline.head_digest).to_journal]

      expect(described_class.new.price_records(records).usage(timeline).total_tokens).to eq(1100)
    end
  end
end
