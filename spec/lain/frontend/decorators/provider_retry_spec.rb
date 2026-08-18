# frozen_string_literal: true

RSpec.describe Lain::Frontend::Decorators::ProviderRetry do
  let(:theme) { Lain::Frontend::Theme.new(pastel: Pastel.new(enabled: false)) }

  def event(attempt: 1, will_retry_in: 1.0, status: 503, reason: "Faraday::TimeoutError")
    Lain::Telemetry::ProviderRetry.new(attempt:, will_retry_in:, status:, reason:)
  end

  it "announces the attempt as it happens, so a hung endpoint is not a blank screen" do
    rendered = described_class.new(event(attempt: 1)).render(theme)

    expect(rendered).to include("attempt 1")
  end

  it "names the second attempt distinctly from the first" do
    first = described_class.new(event(attempt: 1)).render(theme)
    second = described_class.new(event(attempt: 2)).render(theme)

    expect(first).to include("attempt 1")
    expect(second).to include("attempt 2")
    expect(second).not_to eq(first)
  end

  it "names the third attempt distinctly from the second, so repeated waiting stays legible" do
    second = described_class.new(event(attempt: 2)).render(theme)
    third = described_class.new(event(attempt: 3)).render(theme)

    expect(third).to include("attempt 3")
    expect(third).not_to eq(second)
  end

  it "marks an exhausted retry (will_retry_in nil) distinctly from one still backing off" do
    backing_off = described_class.new(event(attempt: 2, will_retry_in: 4.0)).render(theme)
    exhausted = described_class.new(event(attempt: 3, will_retry_in: nil)).render(theme)

    expect(backing_off).not_to eq(exhausted)
  end

  it "writes nothing to stdout or stderr -- it only returns a string for the caller to route" do
    expect { described_class.new(event).render(theme) }.to output("").to_stdout.and output("").to_stderr
  end

  describe ".for" do
    it "returns a ProviderRetry decorator for a ProviderRetry event" do
      expect(Lain::Frontend::Decorators.for(event)).to be_a(described_class)
    end
  end
end
