# frozen_string_literal: true

require "bigdecimal"

# Cache waste for requests nobody sent: a re-rendered prefix that diverges from the one before
# it is priced as a cache write of everything after the first differing byte, at 4 bytes a token.
# No usage is involved, recorded or invented.
RSpec.describe Lain::Friction::CacheWaste::Simulated do
  def message(text, role: "user") = { "role" => role, "content" => [{ "type" => "text", "text" => text }] }

  def request(messages, system: "be terse", tools: [])
    Lain::Request.new(model: "m", system:, tools:, messages:, max_tokens: 64)
  end

  # Independent of the subject: the prefix in cache order, as one byte string.
  def prefix_bytes(request)
    stripped = Lain::Request.strip_cache_markers(request.messages)
    [Lain::Canonical.dump(request.tools), Lain::Canonical.dump(request.system),
     *stripped.map { |each| Lain::Canonical.dump(each) }].join
  end

  def first_difference(before, after)
    before.bytes.zip(after.bytes).index { |a, b| a != b } || before.bytesize
  end

  let(:history) { [message("alpha " * 40), message("ok", role: "assistant"), message("beta " * 40)] }
  let(:haiku) { "claude-haiku-5-5" }

  def simulated(requests, price_as: haiku) = described_class.new(requests, price_as:)

  it "rebills nothing while each prefix only grows" do
    grown = history + [message("more", role: "assistant"), message("again")]

    waste = simulated([request(history), request(grown)])

    expect(waste.rebilled_tokens).to eq(0)
    expect(waste.count).to eq(0)
  end

  describe "an earlier message edited" do
    let(:edited) { [message("alpha " * 40), message("ok", role: "assistant"), message("BETA " * 40), message("x")] }
    let(:waste) { simulated([request(history), request(edited)]) }
    let(:expected_tokens) do
      after = prefix_bytes(request(edited))
      (after.bytesize - first_difference(prefix_bytes(request(history)), after)) / 4
    end

    it "rebills the bytes after the first difference as tokens at 4 bytes each" do
      expect(waste.rebilled_tokens).to eq(expected_tokens)
      expect(expected_tokens).to be_positive
    end

    it "prices them as cache writes of the named model" do
      expect(waste.rebilled_cost.amount).to eq(BigDecimal("0.125") / 1_000_000 * expected_tokens)
      expect(waste.rebilled_cost).to be_complete
    end

    it "places the rebill at the first differing byte, counted in bytes" do
      offset = first_difference(prefix_bytes(request(history)), prefix_bytes(request(edited)))

      expect(waste.map(&:offset_bytes)).to eq([offset])
    end

    it "names the cause with the cache-waste classifier" do
      expect(waste.causes).to eq(history_edited: 1)
      expect(Lain::Friction::BreakCause::LABELS.fetch(waste.first.cause)).to eq("earlier messages edited")
    end

    it "builds no usage" do
      expect(Lain::Usage).not_to receive(:new)

      simulated([request(history), request(edited)]).rebilled_tokens
    end
  end

  it "rebills nothing when the later request is a strict prefix of the earlier" do
    waste = simulated([request(history), request(history.first(1))])

    expect(waste.count).to eq(0)
  end

  # Over 100,000 prompt tokens Haiku 5.5 bills the whole request at its dearer row.
  it "prices a prompt past the size tier at the tier's cache-write rate" do
    tail = message("w" * 500_000)
    before = request([message("x" * 1_000), message("y", role: "assistant"), tail])
    after = request([message("X" * 1_000), message("y", role: "assistant"), tail])
    waste = simulated([before, after])

    expect(prefix_bytes(after).bytesize).to be > 400_000
    expect(waste.rebilled_cost.amount).to eq(BigDecimal("0.625") / 1_000_000 * waste.rebilled_tokens)
  end

  it "names a changed system prompt as the cause" do
    waste = simulated([request(history), request(history, system: "be verbose")])

    expect(waste.causes).to eq(system_changed: 1)
  end

  it "reads a moved cache marker as no rewrite" do
    marked = history.dup
    marked[0] = { "role" => "user", "content" => [{ "type" => "text", "text" => "alpha " * 40, "cache" => true }] }

    expect(simulated([request(history), request(marked)]).rebilled_tokens).to eq(0)
  end

  it "counts the tokens and withholds the dollars for a model with no price" do
    waste = simulated([request(history), request(history.reverse)], price_as: "no-such-model")

    expect(waste.rebilled_tokens).to be_positive
    expect(waste.rebilled_cost).not_to be_complete
  end
end
