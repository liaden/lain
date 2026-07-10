# frozen_string_literal: true

require "lain/context/compact"

RSpec.describe Lain::Context::Compact do
  def text(body) = [{ "type" => "text", "text" => body }]

  def message(role, body)
    { "role" => role, "content" => text(body) }
  end

  let(:messages) do
    [
      message("user", "a" * 200),
      message("assistant", "b" * 200),
      message("user", "c" * 200),
      message("assistant", "d" * 200)
    ]
  end

  let(:summarizer) { ->(dropped) { "summary of #{dropped.size} turns" } }

  it "is a no-op under threshold" do
    compact = described_class.new(threshold: 1_000_000, keep_last: 1, summarizer: summarizer)
    expect(compact.call(messages)).to eq(messages)
  end

  it "replaces the dropped head with one summary turn, keeping the tail intact" do
    compact = described_class.new(threshold: 10, keep_last: 1, summarizer: summarizer)
    result = compact.call(messages)

    expect(result.size).to eq(2)
    expect(result.first["content"].first["text"]).to eq("summary of 3 turns")
    expect(result.last).to eq(messages.last)
  end

  it "calls the summarizer with exactly the dropped messages" do
    seen = nil
    compact = described_class.new(threshold: 10, keep_last: 1, summarizer: lambda { |dropped|
      seen = dropped
      "s"
    })
    compact.call(messages)
    expect(seen).to eq(messages[0..-2])
  end

  it "is pure: identical input yields identical output (the summarizer must be too)" do
    compact = described_class.new(threshold: 10, keep_last: 1, summarizer: summarizer)
    expect(compact.call(messages)).to eq(compact.call(messages))
  end

  # #requires is an enforcement contract, not a comparison label. Compact
  # summarizes entirely client-side via the injected summarizer, so it needs
  # nothing from the provider -- and declaring :server_compaction would make
  # Capability::Policy wrongly raise (:strict) or journal a false degradation
  # (:degrade) on exactly the providers lacking native compaction, which is
  # when you reach for client-side Compact.
  it "requires nothing from the provider -- it is a client-side summarizer" do
    compact = described_class.new(threshold: 10, keep_last: 1, summarizer: summarizer)
    expect(compact.requires).to eq([])
  end

  it "composes with other combinators via >>" do
    require "lain/context/base"
    composed = described_class.new(threshold: 10, keep_last: 1, summarizer: summarizer) >> Lain::Context::Identity
    expect(composed.call(messages).size).to eq(2)
  end
end
