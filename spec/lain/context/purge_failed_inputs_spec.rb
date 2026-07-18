# frozen_string_literal: true

RSpec.describe Lain::Context::PurgeFailedInputs do
  def tool_use(id:, name:, input:)
    { "type" => "tool_use", "id" => id, "name" => name, "input" => input }
  end

  def tool_result(id:, content:, is_error: false)
    { "type" => "tool_result", "tool_use_id" => id, "content" => content, "is_error" => is_error }
  end

  def assistant(*blocks) = { "role" => "assistant", "content" => blocks }
  def user(*blocks) = { "role" => "user", "content" => blocks }

  # old-failed: outside the turns:2 window -> input purged, error text kept.
  # old-ok: outside the window but never failed -> untouched.
  # recent-failed: inside the window -> untouched, even though it failed.
  let(:messages) do
    [
      assistant(tool_use(id: "old-failed", name: "search", input: { "q" => "old", "payload" => "x" * 500 })),
      user(tool_result(id: "old-failed", content: "error: rate limited", is_error: true)),
      assistant(tool_use(id: "old-ok", name: "search", input: { "q" => "fine" })),
      user(tool_result(id: "old-ok", content: "ok")),
      assistant(tool_use(id: "recent-failed", name: "search", input: { "q" => "recent" })),
      user(tool_result(id: "recent-failed", content: "error: still broken", is_error: true))
    ]
  end

  describe "AC2: purge drops old failed inputs but keeps the error" do
    let(:purged) { described_class.new(turns: 2).call(messages) }

    it "drops the failed call's input once it ages out of the turn window" do
      expect(purged[0]["content"].first["input"]).to eq({})
    end

    it "keeps the error text of the purged call" do
      expect(purged[1]).to eq(messages[1])
      expect(purged[1]["content"].first["content"]).to eq("error: rate limited")
    end

    it "never touches a call that did not fail, regardless of age" do
      expect(purged[2]).to eq(messages[2])
    end

    it "never purges a failed call still inside the turn window" do
      expect(purged[4]).to eq(messages[4])
      expect(purged[4]["content"].first["input"]).to eq({ "q" => "recent" })
    end

    it "leaves the recent error's tool_result untouched" do
      expect(purged[5]).to eq(messages[5])
    end
  end

  it "is a no-op when the whole list fits inside the turn window" do
    expect(described_class.new(turns: messages.size).call(messages)).to eq(messages)
  end

  it "rejects a negative turns: -- silently clamping would purge everything, including the recent window" do
    expect { described_class.new(turns: -1) }.to raise_error(ArgumentError, /turns/)
  end

  it "does not mutate the input message list -- a pure projection" do
    before = Lain::Canonical.dump(messages)
    described_class.new(turns: 2).call(messages)
    expect(Lain::Canonical.dump(messages)).to eq(before)
  end

  it "is pure: identical input yields identical output" do
    combinator = described_class.new(turns: 2)
    expect(combinator.call(messages)).to eq(combinator.call(messages))
  end

  it "declares no required capabilities -- purging is purely client-side" do
    expect(described_class.new(turns: 2).requires).to eq([])
  end

  it "composes with other combinators via >>" do
    composed = described_class.new(turns: 2) >> Lain::Context::Identity
    expect(composed.call(messages)).to eq(described_class.new(turns: 2).call(messages))
  end

  describe "the monoid law (property-tested)" do
    let(:pool) { { purge: described_class.new(turns: 2), identity: Lain::Context::Identity } }

    def compose(sequence)
      sequence.map { |symbol| pool.fetch(symbol) }.reduce(Lain::Context::Identity, :>>)
    end

    def observe(combinator)
      combinator.call(messages)
    end

    include_examples "a monoid",
                     operation: ->(a, b) { a >> b },
                     identity: Lain::Context::Identity,
                     generator: -> { compose(Array.new(rand(0..3)) { %i[purge identity].sample }) },
                     equal: ->(a, b) { observe(a) == observe(b) }
  end
end
