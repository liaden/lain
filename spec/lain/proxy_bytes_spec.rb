# frozen_string_literal: true

# UX5's enforcement, and the ONE definition of "this is how a byte count becomes
# a token count" in the whole of `lib/`. The compaction subsystem's history
# proxy is `Canonical.dump(messages).bytesize` -- bytes, never tokens -- while
# every field of {Lain::Usage} and every {Lain::PriceBook} rate is per TOKEN.
# Two pricing sites consume the proxy ({Lain::Compaction::Scheduler} and
# {Lain::Plan::SeamDecision}); both cross here, so there is one divisor to
# correct and no second copy promising to agree with it.
RSpec.describe Lain::ProxyBytes do
  it "is a deeply frozen value" do
    expect(described_class.new(count: 4_096)).to be_deeply_frozen
  end

  it "coerces its count to an Integer" do
    expect(described_class.new(count: "4096").count).to eq(4_096)
  end

  # A LITERAL, not `4_096 / described_class::BYTES_PER_TOKEN`: re-deriving the
  # expectation from the constant under test makes the example agree with
  # whatever the divisor silently became.
  it "crosses into tokens only through #to_tokens, at the stated divisor" do
    expect(described_class.new(count: 4_096).to_tokens).to eq(1_024)
  end

  # Truncating, not rounding: an estimate feeding a cost claim understates
  # rather than overstates, and a byte count below one token's worth is worth no
  # tokens at all.
  it "truncates a partial token rather than rounding one up" do
    expect(described_class.new(count: 3).to_tokens).to eq(0)
  end

  # What keeps "truncating" true rather than usually-true: `Integer#/` floors,
  # so a negative would round AWAY from zero and overstate the very magnitude
  # this type promises to understate. Both producers clamp at zero, so this is
  # unreachable in production and cheap to make unrepresentable.
  it "refuses a negative byte count outright" do
    expect { described_class.new(count: -5) }.to raise_error(ArgumentError, /cannot be negative/)
  end

  # The whole point of the type. `Usage#initialize` coerces every field with
  # `Integer()`, which refuses this object outright -- so the mistake UX5 named
  # (pricing a byte count at a per-token rate) is now a raise rather than a
  # plausible-looking dollar figure.
  it "cannot be spent as a token count without that crossing" do
    expect { Lain::Usage.new(input_tokens: described_class.new(count: 4_096)) }.to raise_error(TypeError)
    expect { Lain::Usage.new(cache_creation_input_tokens: described_class.new(count: 4_096)) }
      .to raise_error(TypeError)
  end
end
