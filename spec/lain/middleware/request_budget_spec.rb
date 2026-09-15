# frozen_string_literal: true

require "json"
require "stringio"

# The model phase's translator for a prompt its provider refused whole for not
# fitting the context. It guesses nothing: the provider measured the prompt with
# its own tokenizer against the context it actually loaded, and this turns that
# refusal into a record and one line a human can act on.
#
# Driven through the middleware alone, over a real Journal. The production
# composition -- outermost in a wired chat's model phase, under every journal
# setting -- belongs to `spec/lain/cli/wiring_spec.rb` and
# `spec/lain/seams/over_window_request_spec.rb`.
RSpec.describe Lain::Middleware::RequestBudget do
  let(:journal_io) { StringIO.new }
  let(:journal) { Lain::Journal.new(io: journal_io) }
  let(:droppable) { true }
  let(:compaction) { instance_double(Lain::Compaction::Source, droppable?: droppable) }
  let(:budget) { described_class.new(journal:, compaction:) }
  let(:model) { "qwen3:4b" }

  # A provider's typed refusal, as any provider raises one: the numbers ride the
  # {Lain::WindowExceeded} duck, never the provider's own class.
  let(:provider_refusal) do
    Class.new(Lain::Error) { include Lain::WindowExceeded }
  end

  def records
    journal_io.string.each_line.map { |line| JSON.parse(line) }.select { |record| record["type"] == "window_pressure" }
  end

  def request(system: "be terse", text: "hi")
    Lain::Request.new(model:, max_tokens: 64, system:,
                      messages: [{ "role" => "user", "content" => [{ "type" => "text", "text" => text }] }])
  end

  def refusing(prompt_tokens: 12_011, window_tokens: 8192)
    proc do
      raise provider_refusal.new("request (#{prompt_tokens} tokens) exceeds the available context size",
                                 prompt_tokens:, window_tokens:, source: "ollama")
    end
  end

  def refused(request, **numbers)
    budget.call({ request: }, &refusing(**numbers))
    raise "expected a refusal"
  rescue described_class::OverWindow => e
    e
  end

  it "is a model-phase middleware" do
    expect(budget).to be_a(Lain::Middleware::Base)
  end

  describe "an ordinary request" do
    it "hands the provider the env it was given and hands back what came back, recording nothing" do
      response = Lain::Response.new(content: [{ "type" => "text", "text" => "ok" }], stop_reason: :end_turn)
      seen = nil
      env = budget.call({ request: }) do |inner|
        seen = inner
        inner.merge(response:)
      end

      expect(seen.to_h.keys).to eq([:request])
      expect(env.fetch(:response)).to be(response)
      expect(records).to be_empty
    end

    it "lets any other failure through as it was" do
      expect { budget.call({ request: }) { raise Lain::Error, "provider down" } }
        .to raise_error(Lain::Error, "provider down")
      expect(records).to be_empty
    end
  end

  describe "a prompt the provider refused for not fitting its context" do
    let(:big) { request(text: "the quick brown fox. " * 2_000) }

    # A Lain::Error, because that is the vocabulary {Lain::CLI::Repl::Ask}
    # carries out of an ask as a value -- which is what lets the session answer
    # its next prompt rather than dying in its task.
    it "ends in the harness's own refusal, still carrying the provider's exact numbers" do
      error = refused(big)

      expect(error).to be_a(Lain::Error)
      expect(error).to be_a(Lain::WindowExceeded)
      expect(error).to have_attributes(prompt_tokens: 12_011, window_tokens: 8192, source: "ollama")
      expect(error.cause).to be_a(provider_refusal)
    end

    it "journals one over_window record with the exact count, the context size and the source" do
      refused(big)

      expect(records).to contain_exactly(
        include("kind" => "over_window", "source" => "ollama", "model" => model, "request_digest" => big.digest,
                "prompt_tokens" => 12_011, "window_tokens" => 8192)
      )
    end

    it "says so in one line naming both numbers and the moves that make room" do
      message = refused(big).message

      expect(message.lines.size).to eq(1)
      expect(message).to include("12011", "8192", "compaction", "/rewind", "/unpin", "narrower")
    end

    # When the render that was refused left nothing older for compaction to
    # drop, offering it first sends a human after the one move that cannot
    # happen -- with the default twenty kept messages that is easily the whole
    # of a 32k window, and every later prompt is refused the same way.
    context "when the refused render left nothing for compaction to drop" do
      let(:droppable) { false }

      it "leads with /rewind, says the prompt was withdrawn, and does not offer compaction" do
        message = refused(big).message

        expect(message).to include("12011", "8192", "withdrawn", "/unpin", "narrower")
        expect(message).not_to include("compaction")
        expect(message.index("/rewind")).to be < message.index("/unpin")
        expect(message.lines.size).to eq(1)
      end

      it "still names --num-ctx when the system prompt and tools alone outgrow the context" do
        fixed = request(system: "you are a careful assistant. " * 2_000, text: "hi")

        expect(refused(fixed, prompt_tokens: 12_011, window_tokens: 2048).message).to include("--num-ctx", "/rewind")
      end
    end

    it "offers compaction first when the render left something to drop" do
      message = refused(big).message

      expect(message.index("compaction")).to be < message.index("/rewind")
    end

    it "does not offer a larger context when the history is what overflowed" do
      expect(refused(big).message).not_to include("--num-ctx")
    end

    # A fresh session whose system prompt and tool schemas alone exceed the
    # context: no amount of compacting, rewinding or unpinning can help, and a
    # refusal that offered only those would be the whole message a human got.
    it "names --num-ctx when the system prompt and tools alone outgrow the context" do
      fixed = request(system: "you are a careful assistant. " * 2_000, text: "hi")

      expect(refused(fixed, prompt_tokens: 12_011, window_tokens: 2048).message).to include("--num-ctx")
    end
  end
end
