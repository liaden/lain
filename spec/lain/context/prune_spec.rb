# frozen_string_literal: true

RSpec.describe Lain::Context::Prune do
  def text(body) = [{ "type" => "text", "text" => body }]

  let(:store) { Lain::Store.new }
  let(:timeline) do
    Lain::Timeline.empty(store:)
                  .commit(role: :user, content: text("one"))
                  .commit(role: :assistant, content: text("two"))
                  .commit(role: :user, content: text("three"))
                  .commit(role: :assistant, content: text("four"))
  end
  let(:messages) { timeline.to_a.map { |turn| { "role" => turn.role, "content" => turn.content } } }

  describe "keep_last:" do
    it "keeps only the last N messages" do
      pruned = described_class.new(keep_last: 2).call(messages)
      expect(pruned.map { |m| m["content"].first["text"] }).to eq(%w[three four])
    end

    it "is a no-op when N exceeds the message count" do
      pruned = described_class.new(keep_last: 100).call(messages)
      expect(pruned).to eq(messages)
    end

    it "produces byte-diffable output -- pruning is visible as a digest change" do
      require "lain/canonical"
      full_digest = Lain::Canonical.digest(messages)
      pruned_digest = Lain::Canonical.digest(described_class.new(keep_last: 2).call(messages))
      expect(pruned_digest).not_to eq(full_digest)
    end
  end

  describe "predicate (block form)" do
    it "keeps messages matching the block" do
      pruned = described_class.new { |m| m["role"] == "user" }.call(messages)
      expect(pruned.map { |m| m["content"].first["text"] }).to eq(%w[one three])
    end
  end

  it "rejects being given both keep_last: and a predicate" do
    expect { described_class.new(keep_last: 1) { true } }.to raise_error(ArgumentError, /not both/)
  end

  it "rejects being given neither keep_last: nor a predicate" do
    expect { described_class.new }.to raise_error(ArgumentError, /keep_last: or a predicate/)
  end

  it "declares no required capabilities -- pruning is purely client-side" do
    expect(described_class.new(keep_last: 1).requires).to eq([])
  end

  it "is pure: identical input yields identical output" do
    combinator = described_class.new(keep_last: 2)
    expect(combinator.call(messages)).to eq(combinator.call(messages))
  end

  it "composes with other combinators via >>" do
    require "lain/context/base"
    composed = described_class.new(keep_last: 2) >> Lain::Context::Identity
    expect(composed.call(messages).size).to eq(2)
  end

  describe "protected_patterns: (identity, not value equality, must gate survivorship)" do
    # Regression: an EARLIER message that happens to be Hash-VALUE-equal to
    # the true keep_last: survivor (a repeated "ok" tool result, a duplicated
    # turn -- common in real transcripts) must NOT be spuriously resurrected
    # just because `protected_patterns:` is configured. The pattern here
    # matches nothing, so this is purely a survivorship-identity check.
    it "keeps exactly the true survivor when an earlier message is value-equal to it" do
      duplicate_content = text("same content")
      messages = [
        { "role" => "user", "content" => duplicate_content },
        { "role" => "user", "content" => text("middle") },
        { "role" => "user", "content" => duplicate_content }
      ]
      pattern_matching_nothing = Lain::Context::ProtectedPatterns.new(["this-matches-nothing"])

      pruned = described_class.new(keep_last: 1, protected_patterns: pattern_matching_nothing).call(messages)

      expect(pruned).to eq([messages.last])
      expect(pruned.size).to eq(1)
    end
  end
end
