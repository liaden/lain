# frozen_string_literal: true

# The decorator that puts an ORACLE's model round trip into the Journal.
#
# The round trip a turn makes is already recorded by
# {Lain::Middleware::JournalRequests}, which a bench arm opts into. An oracle's
# is not: it goes through {Lain::Oracle::Model}, which calls `#complete`
# directly with no middleware stack anywhere near it. A QA round measured that
# gap as zero oracle records.
RSpec.describe Lain::Provider::Journaled do
  let(:journal) { RecordingChannel.new }

  let(:reply) do
    Lain::Response.new(content: [{ "type" => "text", "text" => "ok" }], stop_reason: :end_turn,
                       usage: Lain::Usage.new(input_tokens: 3, output_tokens: 1))
  end

  let(:inner) { Lain::Provider::Mock.new(responses: [reply]) }
  let(:provider) { described_class.new(provider: inner, journal:) }

  # Carries a cache marker so `prefix_digests` is a non-empty chain rather than
  # the `[]` an unmarked request yields -- an assertion against `[] == []` would
  # pass whether or not the field was carried at all.
  def request(text: "summarize this")
    Lain::Request.new(model: "qwen3:4b", max_tokens: 64,
                      system: [{ "type" => "text", "text" => "you summarize", "cache" => true }],
                      messages: [{ "role" => "user", "content" => [{ "type" => "text", "text" => text }] }])
  end

  def records = journal.events.grep(Lain::Telemetry::RequestSent)

  describe "the round trip it records" do
    it "journals a request_sent whose digest is the request's own" do
      sent = request

      provider.complete(sent)

      expect(records.map(&:digest)).to eq([sent.digest])
    end

    # The reason this rides ABOVE the wire rather than in a Faraday middleware:
    # none of these three survive serialization, so a byte-level observer could
    # not rebuild them.
    it "carries the cache_payload and the prefix chain the Request alone can supply" do
      sent = request

      provider.complete(sent)

      expect(records.last).to have_attributes(payload: sent.cache_payload, prefix_digests: sent.prefix_digests,
                                              stream: sent.stream, extra: sent.extra)
      expect(sent.prefix_digests).not_to be_empty
    end

    it "hands the inner provider's response straight back, untouched" do
      expect(provider.complete(request)).to equal(reply)
    end

    # The record lands BEFORE dispatch, exactly as JournalRequests documents:
    # an attempt that fails still leaves its attempt in the Journal.
    it "records the attempt even when the round trip raises" do
      failing = Lain::Provider::Mock.new(responses: [])

      expect { described_class.new(provider: failing, journal:).complete(request) }.to raise_error(StandardError)
      expect(records.size).to eq(1)
    end

    it "records once per call, not once per provider" do
      twice = described_class.new(provider: Lain::Provider::Mock.new(responses: [reply, reply]), journal:)

      twice.complete(request(text: "first"))
      twice.complete(request(text: "second"))

      expect(records.size).to eq(2)
    end
  end

  describe "the provider surface it forwards" do
    # {Oracle::Model} asks this before it builds a request, and answers a
    # DIFFERENT request depending on the answer -- so a decorator that swallowed
    # it would silently change the bytes an oracle sends.
    it "answers #supports? off the wrapped provider" do
      plain = described_class.new(journal:,
                                  provider: Lain::Provider::Mock.new(responses: [],
                                                                     capabilities: Lain::Provider::CAPABILITIES -
                                                                       [:structured_output]))

      expect(provider.supports?(:structured_output)).to be(true)
      expect(plain.supports?(:structured_output)).to be(false)
    end

    it "forwards the rest of the Provider duck rather than answering for it" do
      expect(provider.capabilities).to eq(inner.capabilities)
      expect(provider.cache_profile).to eq(inner.cache_profile)
      expect(provider.encode(request)).to eq(inner.encode(request))
      expect(provider.to_s).to eq(inner.to_s)
      expect(provider.context_window_tokens("qwen3:4b")).to eq(inner.context_window_tokens("qwen3:4b"))
      expect(provider.trained_context_tokens("qwen3:4b")).to eq(inner.trained_context_tokens("qwen3:4b"))
    end

    # Exposed so a security spec can assert on the provider that will actually
    # be asked, through however many decorators sit above it -- see
    # `oracle/secret_read_spec.rb`, where "the judge is a LOCAL ollama" is the
    # claim under test.
    it "names the provider it wraps" do
      expect(provider.inner).to equal(inner)
    end

    it "refuses a message the Provider duck does not declare, rather than silently forwarding it" do
      expect { provider.api_base }.to raise_error(NoMethodError)
    end
  end

  # The scoping decision, made mechanical. Wrapping every provider would hand
  # every bench arm records it never asked for and DOUBLE them for the arms that
  # already opt into Middleware::JournalRequests innermost
  # (`bench/cli/run_recorder.rb`, `bench/variance_fixtures.rb`). The agent turn
  # is already journaled by that middleware; the measured gap is the oracle.
  describe "what is deliberately NOT wrapped" do
    it "leaves the chat provider CLI::Backend builds undecorated" do
      backend = Lain::CLI::Backend.new(provider: "ollama", model: "qwen3:4b", max_tokens: 64)

      expect(backend.provider).not_to be_a(described_class)
    end
  end
end
