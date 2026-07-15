# frozen_string_literal: true

RSpec.describe Lain::Middleware::JournalRequests do
  subject(:middleware) { described_class.new(journal:) }

  let(:journal) { RecordingChannel.new }

  def request(text = "hi", **overrides)
    Lain::Request.new(
      model: "claude-opus-4-8",
      messages: [{ "role" => "user", "content" => [{ "type" => "text", "text" => text }] }],
      max_tokens: 64,
      **overrides
    )
  end

  describe "middleware citizenship" do
    it "is frozen -- stateless beyond its injected journal" do
      expect(middleware).to be_frozen
    end

    it "defaults its journal to the Null channel, so bare construction never needs a guard" do
      expect { described_class.new.call({ request: }) }.not_to raise_error
    end

    it "passes the env through unchanged: downstream sees the same request, caller sees downstream's env" do
      env = { request: }
      seen = nil
      result = middleware.call(env) do |inner|
        seen = inner
        inner.merge(response: :from_downstream)
      end
      expect(seen).to equal(env)
      expect(result).to eq(request:, response: :from_downstream)
    end

    it "acts as the identity when there is no downstream" do
      env = { request: }
      expect(middleware.call(env)).to eq(env)
    end
  end

  describe "what it journals" do
    it "records the request's digest, cache_payload, stream, and extra as one RequestSent" do
      sent = request("hello", stream: false, extra: { "service_tier" => "flex" })
      middleware.call({ request: sent }) { |env| env }

      expect(journal.events.size).to eq(1)
      event = journal.events.first
      expect(event).to be_a(Lain::Event::RequestSent)
      expect(event).to have_same_digest_as(sent)
      expect(event.payload).to eq(sent.cache_payload)
      expect(event.stream).to be(false)
      expect(event.extra).to eq("service_tier" => "flex")
    end

    it "carries the request's own digest chain as position/digest pairs" do
      sent = request("hello", system: [{ "type" => "text", "text" => "sys", "cache" => true }])
      middleware.call({ request: sent }) { |env| env }

      event = journal.events.first
      expect(event.prefix_digests).to eq(sent.prefix_digests)
      expect(event.prefix_digests).not_to be_empty
    end

    # Record-before-dispatch is a semantic, not an implementation accident: a
    # provider call that raises was still ATTEMPTED, and replay must see the
    # attempt. A request_sent with no following turn_usage is how a failed
    # call reads in the Journal.
    it "records BEFORE dispatch, so a downstream failure still leaves the attempt in the journal" do
      sent = request
      expect { middleware.call({ request: sent }) { raise "provider fell over" } }
        .to raise_error(RuntimeError, "provider fell over")
      expect(journal.events.size).to eq(1)
      expect(journal.events.first).to have_same_digest_as(sent)
    end
  end

  describe "in an Agent's model phase" do
    let(:provider) do
      Lain::Provider::Mock.new(responses: [tool_response(["tu_1", "echo", { "text" => "x" }]),
                                           text_response("done")])
    end

    let(:agent) do
      Lain::Agent.new(
        provider:,
        toolset: Lain::Toolset.new([EchoTool.new]),
        context: Lain::Context.new(model: "claude-opus-4-8", max_tokens: 1024),
        model_middleware: Lain::Middleware::Stack.new([middleware])
      )
    end

    it "journals one request_sent per model call, in call order, each matching its request" do
      agent.ask("hi")

      expect(provider.call_count).to eq(2)
      expect(journal.events.size).to eq(2)
      journal.events.zip(provider.requests).each do |event, sent|
        expect(event.payload).to eq(sent.cache_payload)
        expect(event).to have_same_digest_as(sent)
        expect(event.stream).to eq(sent.stream)
        expect(event.extra).to eq(sent.extra)
        expect(event.prefix_digests).to eq(sent.prefix_digests)
      end
      # The two calls carry different messages, so matching digests in zip order
      # is what proves the records landed in CALL order, not merely both landed.
      expect(journal.events.map(&:digest).uniq.size).to eq(2)
    end
  end
end
