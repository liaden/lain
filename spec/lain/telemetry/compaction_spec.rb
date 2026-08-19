# frozen_string_literal: true

require "bigdecimal"
require "json"

# UX5. Two different units were both spelled "tokens" in one NDJSON stream: this
# record's before/after figures are a canonical-BYTE-length proxy
# (`Canonical.dump(messages).bytesize`), while the sibling turn record's
# `used_tokens`/`window_tokens` are provider-MEASURED. Dividing one by the other
# read 80% occupancy where every other reader said 32%.
#
# So the proxy fields say bytes, and the ONE crossing between the two units is
# {Lain::ProxyBytes#to_tokens} -- spec'd at its own mirrored path, and
# exercised at both pricing sites (`compaction/scheduler_spec.rb`,
# `plan/seam_decision_spec.rb`).
RSpec.describe Lain::Telemetry::Compaction do
  # `**unknown` rather than a fixed signature: one example hands this the
  # PRE-CHUNK spelling on purpose, and it has to reach the record's own
  # constructor to be refused there rather than by this helper.
  def record(trigger: %i[token_threshold], cache_state: :forced, bytes_before: 26_174, bytes_after: 21_867,
             cost_saved: BigDecimal("0.002"), cost_spent: BigDecimal("0.0005"),
             model: "claude-sonnet-4-6", **unknown)
    described_class.new(trigger:, cache_state:, bytes_before:, bytes_after:, cost_saved:, cost_spent:,
                        model:, **unknown)
  end

  describe "the unit it names" do
    it "names the figures it carries in bytes" do
      expect(record.bytes_before).to eq(26_174)
      expect(record.bytes_after).to eq(21_867)
    end

    it "journals them under byte names" do
      expect(record.to_journal).to include("bytes_before" => 26_174, "bytes_after" => 21_867)
    end

    # The whole of UX5, mechanically: a reader grepping this stream for a token
    # count must not find the byte proxy wearing that name.
    it "carries no field called tokens at all" do
      expect(described_class.members.grep(/token/)).to be_empty
      expect(record.to_journal.keys.grep(/token/)).to be_empty
    end

    it "still coerces both figures to Integers" do
      coerced = record(bytes_before: "100", bytes_after: 40.9)

      expect(coerced.bytes_before).to eq(100)
      expect(coerced.bytes_after).to eq(40)
    end
  end

  # Old journals are NOT migrated (chunk decision) and no back-compat shim
  # ships, so this is the mechanical statement of that: the old spelling is
  # simply gone, and a caller still using it fails loudly rather than
  # defaulting a byte count into existence.
  it "ships no shim for the pre-chunk token spelling" do
    expect { record(tokens_before: 100) }.to raise_error(ArgumentError, /tokens_before/)
  end

  it "is a deeply frozen value" do
    expect(record).to be_deeply_frozen
  end

  # Unchanged by the rename, and pinned here because this file is now the
  # record's mirrored spec: the two dollar figures are absent TOGETHER or not
  # at all, and absence is nil rather than zero.
  describe "the refusal the record already carried" do
    it "answers #priced? false when it quotes nothing" do
      refused = record(cost_saved: nil, cost_spent: nil)

      expect(refused).not_to be_priced
      expect(refused.cost_delta).to be_nil
      expect(refused.to_journal).to include("bytes_before" => 26_174, "cost_saved" => nil)
    end

    it "refuses one figure quoted beside a missing one" do
      expect { record(cost_spent: nil) }.to raise_error(ArgumentError, /cost_saved/)
    end
  end
end
