# frozen_string_literal: true

# The three questions StatusFeed asks of a Telemetry::TurnUsage's `usage`, and
# the two restatements of Lain::Usage's own arithmetic that nothing structural
# holds together. Those pins moved here with the code they pin (they were
# spec/lain/status_feed_spec.rb's "sums exactly the fields Usage#..." examples).
RSpec.describe Lain::StatusFeed::JournaledUsage do
  # The canonical wire form a record actually carries: String keys, exactly
  # Usage's four members.
  def journaled(**fields) = described_class.new(fields.transform_keys(&:to_s))

  describe "#cache_active?" do
    it "is true when the turn READ the cache" do
      expect(journaled(cache_read_input_tokens: 1, cache_creation_input_tokens: 0)).to be_cache_active
    end

    it "is true when the turn WROTE the cache, since either means the TTL was touched" do
      expect(journaled(cache_read_input_tokens: 0, cache_creation_input_tokens: 4096)).to be_cache_active
    end

    it "is false when neither field moved" do
      expect(journaled(cache_read_input_tokens: 0, cache_creation_input_tokens: 0, input_tokens: 900))
        .not_to be_cache_active
    end
  end

  describe "#total_input_tokens" do
    it "counts cached tokens too -- the window holds them whether or not they were billed in full" do
      expect(journaled(input_tokens: 10, output_tokens: 5,
                       cache_read_input_tokens: 3, cache_creation_input_tokens: 2).total_input_tokens)
        .to eq(15)
    end
  end

  describe "#total_tokens" do
    it "counts everything billed, both directions" do
      expect(journaled(input_tokens: 10, output_tokens: 5,
                       cache_read_input_tokens: 3, cache_creation_input_tokens: 2).total_tokens)
        .to eq(20)
    end
  end

  # The reason this object reads with `to_i` rather than rebuilding a real
  # Usage: StatusFeed rides CLI::JournalTee, which RE-RAISES a sink's failure
  # into the agent loop, so a malformed record must make the feed derive
  # nothing rather than cost the turn. Usage.from_anthropic_wire reads these
  # same four keys but goes through Integer(), which raises.
  describe "a malformed record" do
    it "derives zero from an absent field rather than raising" do
      expect(journaled(input_tokens: 10).total_tokens).to eq(10)
    end

    it "derives zero from a field that is not a number rather than raising" do
      expect(journaled(input_tokens: "nonsense", output_tokens: 5).total_tokens).to eq(5)
    end
  end

  # Both constants restate Lain::Usage against the JOURNALED hash: this object
  # is handed the record, never the Usage value it was built from. They agree
  # today and nothing structural holds them together, so these are the pins --
  # both the field NAMES (fetch, not [], so a rename fails loudly) and the sum.
  describe "the restatement of Lain::Usage's arithmetic" do
    let(:usage) do
      Lain::Usage.new(input_tokens: 3, output_tokens: 7,
                      cache_creation_input_tokens: 11, cache_read_input_tokens: 13)
    end
    let(:wire) { usage.to_h.transform_keys(&:to_s) }

    it "sums exactly the fields Usage#total_input_tokens does" do
      summed = described_class::INPUT_TOKEN_FIELDS.sum { |field| wire.fetch(field) }

      expect(summed).to eq(usage.total_input_tokens)
      expect(described_class.new(wire).total_input_tokens).to eq(usage.total_input_tokens)
    end

    it "sums exactly the fields Usage#total_tokens does" do
      summed = described_class::TOKEN_FIELDS.sum { |field| wire.fetch(field) }

      expect(summed).to eq(usage.total_tokens)
      expect(described_class.new(wire).total_tokens).to eq(usage.total_tokens)
    end
  end
end
