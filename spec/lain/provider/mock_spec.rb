# frozen_string_literal: true

# Lain::Provider::Mock is the reference implementation the shared parity group
# proves itself against: if a provider this trivial cannot pass all seven
# gates plus the Provider contract, the shared group itself is broken. Every
# other provider (Provider::Anthropic, and later Provider::AnthropicRaw on the
# `transport` branch) is judged against the SAME group.
RSpec.describe Lain::Provider::Mock do
  include_examples "a Lain::Provider",
                   provider_factory: ->(responses) { described_class.new(responses:) }

  # CE-5: Mock fires `on_stream_started` so a fan-out driven through it exercises
  # {Tools::Subagent::Stagger}'s stream-start release. The observer is a
  # caller-supplied ORCHESTRATION hook, not part of the round trip's own
  # contract, so a bug in it must not cost #complete a response it already has --
  # exactly the isolation the live {Provider::StreamStartedSignal} path gives.
  # Mock must match that semantics, not diverge from it.
  describe "the on_stream_started observer (CE-5)" do
    let(:request) do
      Lain::Request.new(model: "m", messages: [{ "role" => "user", "content" => "x" }], max_tokens: 8, stream: true)
    end
    let(:response) { Lain::Response.new(content: [{ "type" => "text", "text" => "hi" }], stop_reason: :end_turn) }

    it "isolates a raising observer: the completion still returns, the failure journaled like live" do
      channel = Lain::Channel.new
      mock = described_class.new(responses: [response], channel:)

      result = nil
      expect { result = mock.complete(request, on_stream_started: ->(_d) { raise "observer boom" }) }
        .not_to raise_error
      expect(result).to be(response)

      failures = channel.drain.grep(Lain::Telemetry::ObserverFailed)
      expect(failures.map(&:hook)).to eq([:stream_started])
      expect(failures.first.message).to eq("observer boom")
      expect(failures.first.digest).to eq(request.digest)
    end

    it "fires the observer with the request digest on the streaming path" do
      seen = []
      described_class.new(responses: [response]).complete(request, on_stream_started: seen.method(:push))

      expect(seen).to eq([request.digest])
    end

    it "does not fire on a non-streaming request" do
      non_streaming = Lain::Request.new(model: "m", messages: [{ "role" => "user", "content" => "x" }],
                                        max_tokens: 8, stream: false)
      seen = []
      described_class.new(responses: [response]).complete(non_streaming, on_stream_started: seen.method(:push))

      expect(seen).to be_empty
    end
  end
end
