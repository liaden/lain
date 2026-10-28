# frozen_string_literal: true

RSpec.describe Lain::Compare::Stats do
  describe ".mean_interval" do
    it "is the two-sided 95% t interval for the mean" do
      interval = described_class.mean_interval([0.6, 0.7, 0.8, 0.9])
      expect([interval.low, interval.high].map { |bound| bound.round(3) }).to eq([0.545, 0.955])
    end

    it "answers no interval for fewer than 2 values" do
      expect(described_class.mean_interval([0.6])).to be_nil
    end

    it "widens as the confidence rises" do
      narrow = described_class.mean_interval([1.0, 2.0, 3.0], confidence: 0.90)
      wide = described_class.mean_interval([1.0, 2.0, 3.0], confidence: 0.99)
      expect(wide.high - wide.low).to be > (narrow.high - narrow.low)
    end

    it "uses the normal quantile past 30 values" do
      values = (1..40).map(&:to_f)
      interval = described_class.mean_interval(values)
      sd = Math.sqrt(values.sum { |v| (v - 20.5)**2 } / 39)
      expect(interval.high - 20.5).to be_within(1e-3).of(1.96 * sd / Math.sqrt(40))
    end

    it "builds a deeply frozen interval" do
      expect(described_class.mean_interval([1.0, 2.0])).to be_deeply_frozen
    end
  end

  describe ".mean" do
    it "is the arithmetic mean as a Float" do
      expect(described_class.mean([1, 2, 4])).to eq(7 / 3.0)
    end
  end

  describe ".percentile" do
    it "interpolates linearly between ranks" do
      expect([0.25, 0.5, 0.75].map { |fraction| described_class.percentile([4.0, 1.0, 3.0, 2.0], fraction) })
        .to eq([1.75, 2.5, 3.25])
    end
  end

  describe "the t quantile" do
    it "is bisected once per confidence and degrees" do
      allow(described_class).to receive(:t_cdf).and_call_original

      100.times { described_class.mean_interval((1..10).map(&:to_f), confidence: 0.9137) }

      expect(described_class).to have_received(:t_cdf).exactly(200).times
    end
  end

  describe ".wilson" do
    it "is Wilson's 95% interval for 9 of 28" do
      interval = described_class.wilson(9, 28)
      expect([interval.low, interval.high]).to contain_exactly(be_within(0.001).of(0.179), be_within(0.001).of(0.506))
    end
  end

  describe "Interval#percents" do
    it "is the low and high bounds as whole percents" do
      expect(described_class.wilson(9, 28).percents).to eq([18, 51])
    end
  end

  describe ".rate_percent" do
    it "is k of n as a whole percent" do
      expect(described_class.rate_percent(9, 28)).to eq(32)
    end
  end

  describe ".wilson edge cases" do
    it "refuses zero trials" do
      expect { described_class.wilson(0, 0) }.to raise_error(ArgumentError)
    end

    it "keeps the bounds inside 0..1" do
      expect(described_class.wilson(0, 10).low).to eq(0.0)
      expect(described_class.wilson(10, 10).high).to eq(1.0)
    end
  end

  describe ".clopper_pearson_upper" do
    it "bounds 0 failures in 150 trials at 0.0198" do
      expect(described_class.clopper_pearson_upper(0, 150).round(4)).to eq(0.0198)
    end

    it "rises with the failures seen" do
      expect(described_class.clopper_pearson_upper(3, 150)).to be > described_class.clopper_pearson_upper(0, 150)
    end
  end

  describe ".brier refusals" do
    it "refuses empty input" do
      expect { described_class.brier([], []) }.to raise_error(ArgumentError)
    end

    it "refuses forecasts and outcomes of different sizes" do
      expect { described_class.brier([0.5, 0.5], [1]) }.to raise_error(ArgumentError)
    end
  end

  describe ".brier" do
    it "is the mean squared error of forecasts against outcomes" do
      expect(described_class.brier([0.9, 0.2], [1, 0])).to be_within(1e-12).of(0.025)
    end
  end
end
