# frozen_string_literal: true

RSpec.describe Lain::Context::Mailbox do
  # A :message event addressed to `to`, carrying renderable "text" -- the same
  # shape Tools::Subagent::Lineage#note writes into the shared log.
  def message(to:, text:, from: "actor")
    payload = Lain::Event::Payload.new(kind: :message, body: { "text" => text })
    Lain::Event.new(kind: :message, from:, to:, payload_digest: payload.digest, body: payload.body)
  end

  def user(text) = { "role" => "user", "content" => [{ "type" => "text", "text" => text }] }
  def assistant(text) = { "role" => "assistant", "content" => [{ "type" => "text", "text" => text }] }

  # Three pending messages to "parent", plus one to someone else (never folded).
  let(:pending) do
    [message(to: "parent", text: "first"),
     message(to: "parent", text: "second"),
     message(to: "parent", text: "third")]
  end
  let(:other) { message(to: "worker", text: "not for the parent") }
  let(:projection) { Lain::Event::Projection.new(pending + [other]) }
  let(:mailbox) { described_class.new(projection:, recipient: "parent") }

  let(:conversation) { [user("hello"), assistant("hi"), user("more please")] }

  describe "folding the recipient's pending messages" do
    it "appends exactly the recipient's messages as one <mailbox> block at the tail" do
      folded = mailbox.call(conversation)

      block = folded.last["content"].last
      expect(block["type"]).to eq("text")
      expect(block["text"]).to start_with("<mailbox>").and(end_with("</mailbox>"))
      expect(block["text"]).to include("first").and(include("second")).and(include("third"))
    end

    it "never folds a message addressed to someone else" do
      folded = mailbox.call(conversation)
      expect(folded.last["content"].last["text"]).not_to include("not for the parent")
    end

    it "leaves the conversation unchanged when nothing is pending for the recipient" do
      empty = described_class.new(projection: Lain::Event::Projection.new([other]), recipient: "parent")
      expect(empty.call(conversation)).to eq(conversation)
    end
  end

  # Scenario: the parent folds deliberately -- the fold rides AFTER the last
  # cache breakpoint, so the cached prefix is byte-identical to a render without
  # it (the Recall tail rule: strictly after the last neutral marker).
  describe "riding after the last cache breakpoint" do
    let(:marked) { Lain::Context::CacheBreakpoints.new.call(conversation) }
    let(:folded) { mailbox.call(marked) }

    it "leaves every message before the last untouched" do
      expect(folded[0..-2]).to eq(marked[0..-2])
    end

    it "leaves the cached prefix of the last message -- marker included -- intact" do
      cached_prefix = marked.last["content"]
      expect(folded.last["content"][0...cached_prefix.size]).to eq(cached_prefix)
      expect(cached_prefix.last["cache"]).to be(true)
    end

    it "places the fold strictly after the neutral marker, which is no longer last" do
      cached_prefix = marked.last["content"]
      expect(folded.last["content"][cached_prefix.size - 1]["cache"]).to be(true)
      expect(folded.last["content"].last).not_to have_key("cache")
    end
  end

  # Panel #3: "pending" means SINCE THE LAST FOLD. Without a high-water mark,
  # fold-all-pending re-renders every already-folded message on every turn --
  # they would never stop being "pending", and the re-prefill grows without
  # bound. The cursor is parent-side fold policy; the Store log underneath is
  # still never consumed (a view, not a queue).
  describe "the folded cursor" do
    it "folds nothing on the next turn when no new message arrived, leaving the render untouched" do
      first = mailbox.call(conversation)
      expect(first.last["content"].last["text"]).to include("first")

      expect(mailbox.call(conversation)).to eq(conversation)
    end

    it "folds only the messages that arrived since the last fold" do
      cursor = described_class::Cursor.new
      described_class.new(projection:, recipient: "parent", cursor:).call(conversation)

      grown = Lain::Event::Projection.new(pending + [other, message(to: "parent", text: "fourth")])
      refold = described_class.new(projection: grown, recipient: "parent", cursor:).call(conversation)

      block = refold.last["content"].last["text"]
      expect(block).to include("fourth")
      expect(block).not_to include("first")
    end

    it "does not advance when its guards block the fold, so nothing is silently skipped" do
      mailbox.call([user("hi"), assistant("working")])
      expect(mailbox.call(conversation).last["content"].last["text"]).to include("first")
    end

    it "leaves folded events queryable in the log -- the view is never consumed" do
      mailbox.call(conversation)
      expect(projection.mailbox("parent").to_a).to eq(pending)
    end

    it "does not mutate the message list it folds over" do
      frozen = conversation.map(&:freeze).freeze
      mailbox.call(frozen)
      expect(frozen).to be_frozen
    end
  end

  describe "the tail-placement guards Recall also honors" do
    it "returns an empty conversation unchanged" do
      expect(mailbox.call([])).to eq([])
    end

    it "does not fold when the last message is not the user's" do
      ending_assistant = [user("hi"), assistant("working")]
      expect(mailbox.call(ending_assistant)).to eq(ending_assistant)
    end
  end
end
