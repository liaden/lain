# frozen_string_literal: true

require "bigdecimal"

RSpec.describe Lain::Plan::SeamDecision do
  # The runtime-measured chunk the seam decision prices: its size annotation,
  # the current (long) prefix, and the shorter prefix a rewrite would leave. A
  # plain duck -- P3/P6 own the object that carries these at live seams -- so an
  # anonymous Data stands in rather than a coupled Plan type.
  def build_chunk(size:, before:, after:)
    Data.define(:size, :tokens_before, :tokens_after).new(size:, tokens_before: before, tokens_after: after)
  end

  # A Calibration stand-in: the decision depends on the #median_turns message,
  # not on the concrete Plan::Calibration (Sandi Metz -- depend on messages).
  def calibration_with(medians)
    Data.define(:medians) { def median_turns(size) = medians[size] }.new(medians:)
  end

  let(:profile) { Lain::CacheProfile::ANTHROPIC } # write 1.25x, read 0.1x
  let(:prices)  { Lain::PriceBook.default }       # opus input = $15/Mtok
  let(:journal) { [] }

  subject(:decision) { described_class.new(model: "opus", journal:) }

  # Hand-computed against opus's $15/Mtok input rate (0.000015/token):
  #   rewrite_cost = tokens_after * input * write_multiplier(1.25)
  #   payback      = tokens_removed * input * read_multiplier(0.1) * turns
  describe "#call" do
    context "an L chunk whose payback dominates the rewrite" do
      let(:chunk) { build_chunk(size: "L", before: 10_000, after: 2_000) }

      it "answers rewrite-now and journals both sides' inputs" do
        record = decision.call(chunk:, profile:, prices:)

        expect(record).to be_rewrite
        expect(record.verdict).to eq(:rewrite_now)
        expect(record.size).to eq("L")
        expect(record.tokens_removed).to eq(8_000)
        expect(record.tokens_after).to eq(2_000)
        expect(record.estimated_turns).to eq(described_class::ANNOTATION_TURNS.fetch("L"))
        # rewrite_cost = 2000 * 0.000015 * 1.25 = 0.0375
        expect(BigDecimal(record.rewrite_cost)).to eq(BigDecimal("0.0375"))
        # payback = 8000 * 0.000015 * 0.1 * 13 = 0.156
        expect(BigDecimal(record.payback)).to eq(BigDecimal("0.156"))
      end

      it "journals exactly one seam_decision carrying the verdict and both costs" do
        record = decision.call(chunk:, profile:, prices:)

        expect(journal).to eq([record])
        entry = record.to_journal
        expect(entry["type"]).to eq("seam_decision")
        expect(entry).to include("size" => "L", "verdict" => :rewrite_now,
                                 "rewrite_cost" => "0.0375", "payback" => "0.156",
                                 "tokens_removed" => 8_000, "tokens_after" => 2_000)
      end
    end

    context "a priced model under a NO_CACHING provider" do
      let(:profile) { Lain::CacheProfile::NO_CACHING } # write 1.0x, read 1.0x
      let(:chunk) { build_chunk(size: "L", before: 10_000, after: 2_000) }

      # HONEST EV, not a degenerate case: with no cache there is nothing to
      # PROTECT, but everything to SAVE -- compaction shortens every future
      # turn's full-price input resend. payback = 8000 * 0.000015 * 1.0 * 13 =
      # 1.56, dwarfing rewrite_cost = 2000 * 0.000015 * 1.0 = 0.03.
      it "still answers rewrite-now because it shortens every full-price resend" do
        record = decision.call(chunk:, profile:, prices:)

        expect(record).to be_rewrite
        expect(BigDecimal(record.rewrite_cost)).to eq(BigDecimal("0.03"))
        expect(BigDecimal(record.payback)).to eq(BigDecimal("1.56"))
      end
    end

    context "a tiny chunk whose rewrite outweighs the payback" do
      let(:chunk) { build_chunk(size: "S", before: 3_000, after: 2_900) }

      it "defers" do
        record = decision.call(chunk:, profile:, prices:)

        expect(record).not_to be_rewrite
        expect(record.verdict).to eq(:defer)
        expect(record.net).to be < 0
      end
    end

    context "when calibration supplies a measured median" do
      let(:chunk) { build_chunk(size: "L", before: 10_000, after: 2_000) }
      let(:calibration) { calibration_with("L" => 4) }

      it "prefers the calibrated median over the annotation default" do
        record = decision.call(chunk:, profile:, prices:, calibration:)

        expect(record.estimated_turns).to eq(4)
        expect(record.calibrated).to be(true)
        # payback = 8000 * 0.000015 * 0.1 * 4 = 0.048 > cost 0.0375 -> still rewrite
        expect(BigDecimal(record.payback)).to eq(BigDecimal("0.048"))
        expect(record).to be_rewrite
      end

      it "falls back to the annotation default when the class is uncalibrated" do
        record = decision.call(chunk:, profile:, prices:, calibration: calibration_with({}))

        expect(record.estimated_turns).to eq(described_class::ANNOTATION_TURNS.fetch("L"))
        expect(record.calibrated).to be(false)
      end
    end

    context "an unpriced arm (no model)" do
      let(:chunk) { build_chunk(size: "L", before: 10_000, after: 2_000) }

      it "prices both sides at zero and defers, still recording the estimate" do
        record = described_class.new(model: nil, journal:).call(chunk:, profile:, prices:)

        expect(BigDecimal(record.rewrite_cost)).to eq(0)
        expect(BigDecimal(record.payback)).to eq(0)
        expect(record.verdict).to eq(:defer)
        expect(record.estimated_turns).to eq(described_class::ANNOTATION_TURNS.fetch("L"))
      end
    end
  end

  # PC-4 AC2: a deliberately mis-sized annotation produces a visible
  # estimate-vs-actual delta. The record faithfully carries the estimate it
  # used (the annotation default, un-calibrated), so once the chunk's ACTUAL
  # turn count is measured after the run, the drift is computable and non-zero
  # rather than silently absorbed.
  describe "estimate-vs-actual drift for a mis-sized annotation" do
    let(:chunk) { build_chunk(size: "S", before: 8_000, after: 2_000) }

    it "shows the delta for a chunk annotated S that ran 4x the S estimate" do
      record = decision.call(chunk:, profile:, prices:)

      s_estimate = described_class::ANNOTATION_TURNS.fetch("S")
      actual_turns = s_estimate * 4
      drift = actual_turns - record.estimated_turns

      expect(record.calibrated).to be(false)
      expect(record.size).to eq("S")
      expect(record.estimated_turns).to eq(s_estimate)
      expect(drift).to eq(s_estimate * 3)
      expect(drift).to be > 0
    end
  end

  # This card prices both sides via profile multipliers x plain input rate
  # rather than the PriceBook's own cache_creation/cache_read rows. That is only
  # sound while the two encodings AGREE -- cheap insurance that they never
  # silently diverge for the shipped models under the Anthropic profile.
  describe "the profile-multiplier and PriceBook-row encodings agree" do
    let(:profile) { Lain::CacheProfile::ANTHROPIC }

    %w[opus sonnet haiku].each do |model|
      it "reconciles for #{model}" do
        price = Lain::PriceBook.default.price(model)

        expect(BigDecimal(profile.write_multiplier.to_s) * price.input).to eq(price.cache_creation)
        expect(BigDecimal(profile.read_multiplier.to_s) * price.input).to eq(price.cache_read)
      end
    end
  end

  # A size that is not S/M/L must fail loudly at the record, not journal
  # silently -- the calibrated estimate path never calls ANNOTATION_TURNS.fetch,
  # so the record's Guard is the only membership check on that path.
  it "refuses a size outside S/M/L at the record" do
    expect do
      Lain::Telemetry::SeamDecision.new(
        size: "XL", estimated_turns: 3, calibrated: false, tokens_removed: 100, tokens_after: 50,
        rewrite_cost: 0, payback: 0, verdict: :defer
      )
    end.to raise_error(ArgumentError, %r{size.*S/M/L.*XL})
  end

  it "is Ractor.shareable" do
    record = decision.call(chunk: build_chunk(size: "M", before: 5_000, after: 1_000),
                           profile:, prices:)

    expect(Ractor.shareable?(record)).to be(true)
  end
end
