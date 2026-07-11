# frozen_string_literal: true

require "lain/agent"
require "lain/context"
require "lain/event"
require "lain/middleware/journal_requests"
require "lain/provider/mock"
require "lain/request"
require "lain/toolset"

RSpec.describe Lain::Middleware::JournalRequests do
  subject(:middleware) { described_class.new(journal: journal) }

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
      expect { described_class.new.call({ request: request }) }.not_to raise_error
    end

    it "passes the env through unchanged: downstream sees the same request, caller sees downstream's env" do
      env = { request: request }
      seen = nil
      result = middleware.call(env) do |inner|
        seen = inner
        inner.merge(response: :from_downstream)
      end
      expect(seen).to equal(env)
      expect(result).to eq(request: request, response: :from_downstream)
    end

    it "acts as the identity when there is no downstream" do
      env = { request: request }
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
      expect(event.digest).to eq(sent.digest)
      expect(event.payload).to eq(sent.cache_payload)
      expect(event.stream).to be(false)
      expect(event.extra).to eq("service_tier" => "flex")
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
      expect(journal.events.first.digest).to eq(sent.digest)
    end
  end

  describe "in an Agent's model phase" do
    let(:provider) do
      Lain::Provider::Mock.new(responses: [tool_response(["tu_1", "echo", { "text" => "x" }]),
                                           text_response("done")])
    end

    let(:agent) do
      Lain::Agent.new(
        provider: provider,
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
        expect(event.digest).to eq(sent.digest)
        expect(event.stream).to eq(sent.stream)
        expect(event.extra).to eq(sent.extra)
      end
      # The two calls carry different messages, so matching digests in zip order
      # is what proves the records landed in CALL order, not merely both landed.
      expect(journal.events.map(&:digest).uniq.size).to eq(2)
    end
  end
end
